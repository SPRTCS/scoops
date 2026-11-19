import Foundation
import Observation
#if os(iOS)
import UIKit
#endif

/// Fehler einer Apple-Brücke mit Text für den Scoop (landet als `{"success": false, "error": …}` beim Server).
nonisolated struct AppleBridgeError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Dieses iPhone/iPad als „Apple-Gerät“ für die Scoops (API v1.18): Home, Wecker und Standort.
///
/// - Anmeldung: `device.hello` über die Live-Verbindung `/api/ws` (bei jedem Verbinden und wenn sich Freigaben oder
///   das Push-Token ändern), im Hintergrund `POST /api/apple/device`.
/// - Befehle: `device.cmd` über `/api/ws` (App im Vordergrund) oder nach einer stillen Push (`apple_cmd`) per
///   `POST /api/apple/device/poll`. Antworten über den Socket, sonst per HTTP. Doppelt zugestellte Befehle werden
///   nur einmal ausgeführt.
/// - Orte: Betreten/Verlassen → `POST /api/apple/device/event`.
/// Der Mac meldet sich nicht an (HomeKit, AlarmKit und Geofences gibt es dort nicht).
@MainActor
@Observable
final class AppleDeviceAgent {
    static let shared = AppleDeviceAgent()

    @ObservationIgnored weak var store: AppStore?
    /// Freigaben auf diesem Gerät: home/alarms → granted, denied, not_determined …; location → always, when_in_use …
    private(set) var permissions: [String: String] = [:]
    /// Gerade läuft eine iOS-Abfrage für diesen Dienst
    var asking: Set<String> = []

    @ObservationIgnored private var results: [String: (Date, JSONValue)] = [:]
    @ObservationIgnored private var running: Set<String> = []
    @ObservationIgnored private var appActive = true
    @ObservationIgnored private var launched = false

    let deviceID: String

    #if os(iOS)
    static let isSupported = true
    #else
    static let isSupported = false
    #endif

    init() {
        let key = "appleDeviceID"
        if let id = UserDefaults.standard.string(forKey: key) {
            deviceID = id
        } else {
            deviceID = "ios-" + UUID().uuidString.lowercased()
            UserDefaults.standard.set(deviceID, forKey: key)
        }
    }

    var capabilities: [String] { Self.isSupported ? ["home", "alarms", "location"] : [] }

    var kind: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #else
        "mac"
        #endif
    }

    var label: String { kind == "ipad" ? "iPad" : "iPhone" }

    // MARK: Lebenszyklus

    /// App-Start (auch wenn iOS die App im Hintergrund für eine Push oder einen Ort startet).
    func launch() {
        guard !launched else { return }
        launched = true
        #if os(iOS)
        HomeBridge.shared.onChange = { [weak self] in self?.permissionsChanged() }
        LocationBridge.shared.onChange = { [weak self] in self?.permissionsChanged() }
        LocationBridge.shared.onPlaceEvent = { [weak self] id, kind, date in self?.reportPlace(id: id, kind: kind, date: date) }
        HomeBridge.shared.resumeIfAsked()
        LocationBridge.shared.resumeMonitoring()
        #endif
        refreshPermissions()
    }

    func refreshPermissions() {
        #if os(iOS)
        let now = ["home": HomeBridge.shared.permission, "alarms": AlarmBridge.shared.permission,
                   "location": LocationBridge.shared.permission]
        if now != permissions { permissions = now }
        #endif
    }

    func hello(active: Bool) -> AppleDeviceHello {
        refreshPermissions()
        #if os(iOS)
        let name = UIDevice.current.name
        let os = "iOS \(UIDevice.current.systemVersion)"
        #else
        let name = Host.current().localizedName ?? "Mac"
        let os = "macOS"
        #endif
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
        return AppleDeviceHello(deviceId: deviceID, name: name, kind: kind, model: Self.model, os: os, appVersion: version,
                                capabilities: capabilities, permissions: permissions,
                                pushToken: PushManager.shared.deviceToken, active: active)
    }

    /// Nur am eigenen Server (nicht Demo, nicht Testinstanz ohne Server) und nur auf iPhone/iPad.
    private var connectedService: BotService? {
        guard Self.isSupported, let store, !store.isMock, store.phase == .online else { return nil }
        return store.service
    }

    /// Live-Kanal steht: anmelden (Fähigkeiten, Freigaben, Push-Token).
    func socketConnected() { sendHello() }

    func appActiveChanged(_ active: Bool) {
        appActive = active
        guard let service = connectedService else { return }
        if active {
            sendHello()  // Freigaben können sich in den Einstellungen geändert haben
        } else {
            let msg: JSONValue = ["type": "device.state", "active": false]
            _ = service.sendDeviceMessage(msg.jsonString)
        }
    }

    /// Freigaben oder Push-Token geändert → neu anmelden.
    func permissionsChanged() {
        let before = permissions
        refreshPermissions()
        if before != permissions || before.isEmpty { sendHello() }
    }

    func sendHello() {
        guard let service = connectedService else { return }
        let hello = hello(active: appActive)
        guard let data = try? JSONCoding.makeEncoder().encode(hello) else { return }
        if !service.sendDeviceMessage(String(decoding: data, as: UTF8.self)) {
            Task {
                let pending = (try? await service.registerAppleDevice(hello)) ?? []
                for cmd in pending { handle(cmd) }
            }
        }
    }

    // MARK: Befehle

    /// Befehl aus dem Live-Kanal: ausführen und über den Socket (sonst HTTP) antworten.
    func handle(_ cmd: AppleDeviceCommand) {
        guard Self.isSupported, let service = store?.service ?? store?.appleDeviceService() else { return }
        Task {
            guard let result = await execute(cmd) else { return }
            await deliver(cmd, result, via: service)
        }
    }

    private func deliver(_ cmd: AppleDeviceCommand, _ result: JSONValue, via service: BotService) async {
        let msg: JSONValue = ["type": "device.result", "id": .string(cmd.id), "result": result]
        if service.sendDeviceMessage(msg.jsonString) { return }
        try? await service.sendAppleResult(deviceID: deviceID, commandID: cmd.id, result: result)
    }

    /// Führt einen Befehl einmal aus. Kommt er ein zweites Mal (Socket und Push), gilt das gemerkte Ergebnis;
    /// läuft er gerade noch, `nil` (die erste Ausführung antwortet).
    func execute(_ cmd: AppleDeviceCommand) async -> JSONValue? {
        results = results.filter { Date().timeIntervalSince($0.value.0) < 300 }
        if let done = results[cmd.id] { return done.1 }
        guard !running.contains(cmd.id) else { return nil }
        running.insert(cmd.id)
        defer { running.remove(cmd.id) }
        let result: JSONValue
        do {
            result = try await run(cmd.command, cmd.params)
        } catch {
            result = CmdResult.fail(error.localizedDescription)
        }
        results[cmd.id] = (Date(), result)
        return result
    }

    private func run(_ command: String, _ params: JSONValue) async throws -> JSONValue {
        #if os(iOS)
        if command.hasPrefix("apple.home.") { return try await HomeBridge.shared.run(command, params) }
        if command.hasPrefix("apple.alarms.") { return try await AlarmBridge.shared.run(command, params) }
        if command.hasPrefix("apple.location.") { return try await LocationBridge.shared.run(command, params) }
        #endif
        throw AppleBridgeError("Dieses Gerät kann „\(command)“ nicht ausführen.")
    }

    // MARK: Hintergrund

    /// Stille Push mit `apple_cmd`: kurz anmelden, offene Befehle abholen, ausführen, antworten (iOS gibt ~30 s).
    func handleWake(commandID: String?) async -> Bool {
        guard Self.isSupported, commandID != nil, let service = store?.appleDeviceService() else { return false }
        var commands = (try? await service.registerAppleDevice(hello(active: false))) ?? []
        if commands.isEmpty { commands = (try? await service.pollAppleDevice(deviceID: deviceID)) ?? [] }
        for cmd in commands {
            guard let result = await execute(cmd) else { continue }
            try? await service.sendAppleResult(deviceID: deviceID, commandID: cmd.id, result: result)
        }
        return !commands.isEmpty
    }

    /// Ort betreten/verlassen → Server (auch im Hintergrund, mit kurzer Hintergrund-Aufgabe).
    func reportPlace(id: String, kind: String, date: Date) {
        guard let service = store?.appleDeviceService() else { return }
        #if os(iOS)
        let task = UIApplication.shared.beginBackgroundTask(withName: "Ort melden")
        #endif
        let event: JSONValue = ["type": "geofence", "id": .string(id), "event": .string(kind),
                                "at": .string(AppleDeviceAgent.iso(date))]
        Task {
            try? await service.sendAppleEvent(deviceID: deviceID, event: event)
            #if os(iOS)
            UIApplication.shared.endBackgroundTask(task)
            #endif
        }
    }

    // MARK: Freigaben (Einstellungen → Apps verbinden → Apple)

    /// iOS-Abfrage für einen Dienst; danach neu anmelden. Gibt den neuen Zustand zurück.
    @discardableResult
    func requestPermission(_ service: String, always: Bool = false) async -> String {
        asking.insert(service)
        defer { asking.remove(service) }
        var state = "unknown"
        #if os(iOS)
        switch service {
        case "home": state = await HomeBridge.shared.requestAccess()
        case "alarms": state = await AlarmBridge.shared.requestAccess()
        case "location":
            state = always ? await LocationBridge.shared.requestAlways() : await LocationBridge.shared.requestWhenInUse()
        default: break
        }
        #endif
        permissionsChanged()
        sendHello()
        return state
    }

    nonisolated static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    private static var model: String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
