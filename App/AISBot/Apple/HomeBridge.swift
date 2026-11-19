#if os(iOS)
import Foundation
import HomeKit

/// Apple Home für die Scoops (`apple.home.*`, API v1.18) über HomeKit.
///
/// Der `HMHomeManager` wird erst angelegt, wenn der Nutzer in AIS Scoops „Erlauben“ tippt (das löst die
/// iOS-Abfrage aus) bzw. wenn er das früher schon getan hat. Schlösser, Garagentore, Türen und Alarmanlagen schaltet
/// die App nur mit `confirmed: true`: Den setzt der Server erst nach „Freigeben“ auf der Freigabe-Karte.
/// Home-Daten werden nicht protokolliert.
@MainActor
final class HomeBridge: NSObject, HMHomeManagerDelegate {
    static let shared = HomeBridge()

    private var manager: HMHomeManager?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var loaded = false
    private static let askedKey = "homeKitAsked"
    var onChange: (() -> Void)?

    /// Einmal „Erlauben“ getippt (danach darf der Manager beim Start angelegt werden)
    var wasAsked: Bool { UserDefaults.standard.bool(forKey: Self.askedKey) }

    /// granted | denied | restricted | not_determined
    var permission: String {
        guard let manager else { return wasAsked ? "unknown" : "not_determined" }
        let s = manager.authorizationStatus
        if s.contains(.authorized) { return "granted" }
        if s.contains(.restricted) { return "restricted" }
        return s.contains(.determined) ? "denied" : "not_determined"
    }

    /// Beim Start: Manager nur anlegen, wenn schon einmal erlaubt wurde (sonst keine ungefragte iOS-Abfrage).
    func resumeIfAsked() {
        if wasAsked { makeManager() }
    }

    /// „Erlauben“: legt den Manager an (iOS fragt) und wartet, bis HomeKit die Zuhause geladen hat.
    func requestAccess() async -> String {
        UserDefaults.standard.set(true, forKey: Self.askedKey)
        makeManager()
        await waitUntilLoaded(timeout: 30)
        return permission
    }

    private func makeManager() {
        guard manager == nil else { return }
        let m = HMHomeManager()
        m.delegate = self
        manager = m
    }

    private func waitUntilLoaded(timeout: Double) async {
        if loaded { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                self?.finishWaiting()
            }
        }
    }

    private func finishWaiting() {
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }

    nonisolated func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        Task { @MainActor in
            self.loaded = true
            self.finishWaiting()
            self.onChange?()
        }
    }

    nonisolated func homeManager(_ manager: HMHomeManager, didUpdate status: HMHomeManagerAuthorizationStatus) {
        Task { @MainActor in
            if !status.contains(.authorized), status.contains(.determined) {
                self.loaded = true
                self.finishWaiting()
            }
            self.onChange?()
        }
    }

    // MARK: Befehle

    func run(_ command: String, _ p: JSONValue) async throws -> JSONValue {
        if manager == nil, wasAsked { makeManager() }
        guard permission == "granted" || (permission == "unknown" && wasAsked) else {
            throw AppleBridgeError("AIS Scoops hat auf diesem iPhone keinen Zugriff auf Apple Home. In AIS Scoops unter Apps verbinden → Apple → Home erlauben.")
        }
        await waitUntilLoaded(timeout: 8)
        guard let manager, permission == "granted" else {
            throw AppleBridgeError("Apple Home ist auf diesem iPhone nicht freigegeben.")
        }
        switch command {
        case "apple.home.overview": return overview(manager.homes, home: p["home"]?.string, room: p["room"]?.string)
        case "apple.home.get": return try await get(p["id"]?.string ?? "", in: manager.homes)
        case "apple.home.set": return try await set(p, in: manager.homes)
        case "apple.home.scene": return try await scene(p, in: manager.homes)
        default: throw AppleBridgeError("Unbekannter Befehl \(command)")
        }
    }

    private func overview(_ homes: [HMHome], home: String?, room: String?) -> JSONValue {
        let wantHome = home?.lowercased()
        let wantRoom = room?.lowercased()
        let list = homes.filter { h in
            wantHome.map { h.name.lowercased().contains($0) || h.uniqueIdentifier.uuidString == home } ?? true
        }
        return CmdResult.ok(["homes": .array(list.map { h in
            let accessories = h.accessories.filter { a in
                wantRoom.map { (a.room?.name.lowercased().contains($0) ?? false) || a.room?.uniqueIdentifier.uuidString == room } ?? true
            }
            return .object([
                "id": .string(h.uniqueIdentifier.uuidString), "name": .string(h.name), "primary": .bool(h.isPrimary),
                "rooms": .array(h.rooms.map { ["id": .string($0.uniqueIdentifier.uuidString), "name": .string($0.name)] }),
                "accessories": .array(accessories.map { accessoryJSON($0, fresh: false) }),
                "scenes": .array(h.actionSets.map { s in
                    ["id": .string(s.uniqueIdentifier.uuidString), "name": .string(s.name),
                     "sensitive": .bool(Self.isSensitive(s))]
                }),
            ])
        })])
    }

    private func get(_ id: String, in homes: [HMHome]) async throws -> JSONValue {
        guard let acc = Self.accessory(id, in: homes) else { throw AppleBridgeError("Gerät nicht gefunden (ID aus 'uebersicht' nehmen).") }
        // Werte frisch lesen (je Wert höchstens 5 s, nicht erreichbare Geräte blockieren sonst lange)
        let started = Date()
        for c in acc.services.flatMap(\.characteristics) where Self.stateKeys[c.characteristicType] != nil
            && c.properties.contains(HMCharacteristicPropertyReadable) {
            guard Date().timeIntervalSince(started) < 12 else { break }
            _ = try? await AppStore.withDeadline(5, onTimeout: AppleBridgeError("Zeitüberschreitung")) {
                try await c.readValue()
            }
        }
        return CmdResult.ok(["accessory": accessoryJSON(acc, fresh: true)])
    }

    private func set(_ p: JSONValue, in homes: [HMHome]) async throws -> JSONValue {
        let id = p["id"]?.string ?? ""
        let confirmed = p["confirmed"]?.bool == true
        let services: [HMService]
        if let acc = Self.accessory(id, in: homes) {
            services = acc.services
        } else if let svc = homes.flatMap(\.accessories).flatMap(\.services).first(where: { $0.uniqueIdentifier.uuidString == id }) {
            services = [svc]
        } else {
            throw AppleBridgeError("Gerät nicht gefunden (ID aus 'uebersicht' nehmen).")
        }
        guard confirmed || !services.contains(where: { Self.sensitiveTypes.contains($0.serviceType) }) else {
            throw AppleBridgeError("Schlösser, Türen, Garagentore und Alarmanlagen gehen nur mit Freigabe in AIS Scoops.")
        }
        var writes: [(String, Any)] = []
        if let on = p["on"]?.bool {
            let hasPower = services.contains { $0.characteristics.contains { $0.characteristicType == HMCharacteristicTypePowerState } }
            writes.append(hasPower ? (HMCharacteristicTypePowerState, on) : (HMCharacteristicTypeActive, on ? 1 : 0))
        }
        if let b = p["brightness"]?.int { writes.append((HMCharacteristicTypeBrightness, max(0, min(100, b)))) }
        if let t = p["target_temperature"]?.double { writes.append((HMCharacteristicTypeTargetTemperature, t)) }
        if let pos = p["position"]?.int { writes.append((HMCharacteristicTypeTargetPosition, max(0, min(100, pos)))) }
        if let lock = p["lock"]?.string {
            writes.append((HMCharacteristicTypeTargetLockMechanismState, lock == "secured" ? 1 : 0))
        }
        if let door = p["door"]?.string { writes.append((HMCharacteristicTypeTargetDoorState, door == "open" ? 0 : 1)) }
        if let mode = p["security"]?.string {
            let v = ["stay": 0, "away": 1, "night": 2, "off": 3][mode] ?? 3
            writes.append((HMCharacteristicTypeTargetSecuritySystemState, v))
        }
        guard !writes.isEmpty else { throw AppleBridgeError("Nichts zu schalten.") }
        var done: [String] = []
        for (type, value) in writes {
            guard let c = services.flatMap(\.characteristics).first(where: {
                $0.characteristicType == type && $0.properties.contains(HMCharacteristicPropertyWritable)
            }) else {
                throw AppleBridgeError("Das Gerät kann „\(Self.stateKeys[type] ?? type)“ nicht schalten.")
            }
            try await AppStore.withDeadline(10, onTimeout: AppleBridgeError("Das Gerät antwortet nicht (nicht erreichbar?).")) {
                try await c.writeValue(value)
            }
            done.append(Self.stateKeys[type] ?? type)
        }
        let acc = services.first?.accessory
        return CmdResult.ok(["changed": .array(done.map { .string($0) }),
                             "accessory": acc.map { accessoryJSON($0, fresh: false) } ?? .null])
    }

    private func scene(_ p: JSONValue, in homes: [HMHome]) async throws -> JSONValue {
        let id = p["id"]?.string ?? ""
        for h in homes {
            guard let s = h.actionSets.first(where: { $0.uniqueIdentifier.uuidString == id || $0.name == id }) else { continue }
            guard p["confirmed"]?.bool == true || !Self.isSensitive(s) else {
                throw AppleBridgeError("Diese Szene schaltet Schlösser, Türen oder die Alarmanlage und braucht eine Freigabe.")
            }
            try await AppStore.withDeadline(15, onTimeout: AppleBridgeError("Die Szene antwortet nicht.")) {
                try await h.executeActionSet(s)
            }
            return CmdResult.ok(["scene": ["id": .string(s.uniqueIdentifier.uuidString), "name": .string(s.name), "executed": true]])
        }
        throw AppleBridgeError("Szene nicht gefunden.")
    }

    // MARK: JSON

    private func accessoryJSON(_ a: HMAccessory, fresh: Bool) -> JSONValue {
        let services = a.services.compactMap { s -> JSONValue? in
            guard let type = Self.serviceTypes[s.serviceType] else { return nil }
            var o: [String: JSONValue] = ["id": .string(s.uniqueIdentifier.uuidString), "name": .string(s.name),
                                          "type": .string(type)]
            if Self.sensitiveTypes.contains(s.serviceType) { o["sensitive"] = true }
            for c in s.characteristics {
                guard let key = Self.stateKeys[c.characteristicType], let v = Self.value(c) else { continue }
                o[key] = v
            }
            return .object(o)
        }
        return .object([
            "id": .string(a.uniqueIdentifier.uuidString), "name": .string(a.name), "room": .text(a.room?.name),
            "category": .string(a.category.localizedDescription), "reachable": .bool(a.isReachable),
            "sensitive": .bool(a.services.contains { Self.sensitiveTypes.contains($0.serviceType) }),
            "services": .array(services),
        ])
    }

    private static func value(_ c: HMCharacteristic) -> JSONValue? {
        switch c.value {
        case let b as Bool: return .bool(b)
        case let n as NSNumber:
            switch c.characteristicType {
            case HMCharacteristicTypePowerState, HMCharacteristicTypeMotionDetected: return .bool(n.boolValue)
            case HMCharacteristicTypeCurrentLockMechanismState, HMCharacteristicTypeTargetLockMechanismState:
                return .string(["unsecured", "secured", "jammed", "unknown"][safe: n.intValue] ?? "unknown")
            case HMCharacteristicTypeCurrentDoorState, HMCharacteristicTypeTargetDoorState:
                return .string(["open", "closed", "opening", "closing", "stopped"][safe: n.intValue] ?? "unknown")
            case HMCharacteristicTypeCurrentSecuritySystemState, HMCharacteristicTypeTargetSecuritySystemState:
                return .string(["stay", "away", "night", "off", "triggered"][safe: n.intValue] ?? "unknown")
            case HMCharacteristicTypeContactState: return .string(n.intValue == 0 ? "closed" : "open")
            default: return .number((n.doubleValue * 10).rounded() / 10)
            }
        default: return nil
        }
    }

    private static func accessory(_ id: String, in homes: [HMHome]) -> HMAccessory? {
        let all = homes.flatMap(\.accessories)
        return all.first { $0.uniqueIdentifier.uuidString == id }
            ?? all.first { a in a.services.contains { $0.uniqueIdentifier.uuidString == id } }
            ?? all.first { $0.name.caseInsensitiveCompare(id) == .orderedSame }
    }

    private static func isSensitive(_ set: HMActionSet) -> Bool {
        set.actions.contains { action in
            guard let w = action as? HMCharacteristicWriteAction<NSCopying>, let type = w.characteristic.service?.serviceType
            else { return false }
            return sensitiveTypes.contains(type)
        }
    }

    /// Schlösser, Garagentore, Alarmanlagen und Türen: nur mit Freigabe
    static let sensitiveTypes: Set<String> = [HMServiceTypeLockMechanism, HMServiceTypeGarageDoorOpener,
                                              HMServiceTypeSecuritySystem, HMServiceTypeDoor]

    private static let serviceTypes: [String: String] = [
        HMServiceTypeLightbulb: "lightbulb", HMServiceTypeSwitch: "switch", HMServiceTypeOutlet: "outlet",
        HMServiceTypeThermostat: "thermostat", HMServiceTypeHeaterCooler: "heater_cooler", HMServiceTypeFan: "fan",
        HMServiceTypeLockMechanism: "lock", HMServiceTypeGarageDoorOpener: "garage_door",
        HMServiceTypeSecuritySystem: "security_system", HMServiceTypeDoor: "door", HMServiceTypeWindow: "window",
        HMServiceTypeWindowCovering: "window_covering", HMServiceTypeTemperatureSensor: "temperature_sensor",
        HMServiceTypeHumiditySensor: "humidity_sensor", HMServiceTypeContactSensor: "contact_sensor",
        HMServiceTypeMotionSensor: "motion_sensor", HMServiceTypeAirPurifier: "air_purifier",
    ]

    private static let stateKeys: [String: String] = [
        HMCharacteristicTypePowerState: "on", HMCharacteristicTypeActive: "active", HMCharacteristicTypeBrightness: "brightness",
        HMCharacteristicTypeCurrentTemperature: "current_temperature", HMCharacteristicTypeTargetTemperature: "target_temperature",
        HMCharacteristicTypeCurrentRelativeHumidity: "humidity", HMCharacteristicTypeCurrentPosition: "position",
        HMCharacteristicTypeTargetPosition: "target_position",
        HMCharacteristicTypeCurrentLockMechanismState: "lock_state", HMCharacteristicTypeTargetLockMechanismState: "lock_target",
        HMCharacteristicTypeCurrentDoorState: "door_state", HMCharacteristicTypeTargetDoorState: "door_target",
        HMCharacteristicTypeCurrentSecuritySystemState: "security_state",
        HMCharacteristicTypeTargetSecuritySystemState: "security_target",
        HMCharacteristicTypeContactState: "contact", HMCharacteristicTypeMotionDetected: "motion",
    ]
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
#endif
