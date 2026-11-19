import Foundation

/// Apple-Dienste (API v1.17, `GET/PATCH /api/apple`): Erinnerungen, Kalender und Kontakte über den „Apple-Rechner“
/// (ein Mac mit AIS Scoops Server und erteilten macOS-Freigaben). Ab v1.18 zusätzlich Home, Wecker und Standort über
/// das iPhone (`device`, `devices`, `deviceServices`; fehlen bei älteren Servern).
struct AppleStatus: Codable, Equatable, Sendable {
    var nodeId: String?
    var nodeName: String?
    var nodeOnline: Bool
    /// config | local | default | none
    var nodeSource: String
    /// „auto“ oder die ausdrücklich gewählte Rechner-ID
    var nodeChoice: String
    var nodes: [AppleNode]
    var services: [AppleServiceStatus]
    /// v1.18: gewähltes Apple-Gerät (iPhone/iPad) mit Quelle `config` | `auto`
    var device: AppleDevice?
    /// „auto“ oder die ausdrücklich gewählte Geräte-ID
    var deviceChoice: String?
    var devices: [AppleDevice]?
    /// home, alarms, location
    var deviceServices: [AppleServiceStatus]?

    func service(_ id: String) -> AppleServiceStatus? {
        services.first { $0.id == id } ?? deviceServices?.first { $0.id == id }
    }
}

/// iPhone/iPad mit AIS Scoops als Apple-Gerät (v1.18).
struct AppleDevice: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    /// iphone | ipad
    var kind: String
    var model: String?
    var online: Bool
    var active: Bool?
    var lastSeen: Date?
    var lastActive: String?
    var capabilities: [String]
    /// home/alarms → granted, denied, not_determined …; location → always, when_in_use, denied …
    var permissions: [String: String]
    var push: Bool?
    var source: String?

    var label: String { kind == "ipad" ? "iPad" : "iPhone" }
}

struct AppleNode: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var online: Bool
    /// Freigaben auf diesem Mac: reminders/calendar/contacts → granted, denied, not_determined, disabled, unknown …
    var apple: [String: String]?

    /// Mindestens eine Apple-Freigabe erteilt.
    var hasGrants: Bool { apple?.values.contains("granted") ?? false }
}

struct AppleServiceStatus: Codable, Equatable, Identifiable, Sendable {
    var id: String  // reminders | calendar | contacts
    var name: String
    var tool: String?
    var enabled: Bool
    var permission: String
    var available: Bool
    /// ready | off | needs_permission | needs_update | offline | no_node
    var status: String
    var hint: String?
    var nodeId: String?
    /// v1.18 (Dienste auf dem iPhone)
    var deviceId: String?
    /// Standort: „Immer“ erteilt (Orte im Hintergrund möglich)
    var background: Bool?
}

/// `PATCH /api/apple`: nur gesetzte Felder werden geschickt; `node` = Rechner-ID oder "" (automatisch).
struct ApplePatch: Encodable, Sendable {
    var reminders: Bool?
    var calendar: Bool?
    var contacts: Bool?
    var node: String?
    // v1.18
    var home: Bool?
    var alarms: Bool?
    var location: Bool?
    /// Geräte-ID oder "" (automatisch: zuletzt aktives iPhone)
    var device: String?

    static func service(_ id: String, _ on: Bool) -> ApplePatch {
        switch id {
        case "reminders": ApplePatch(reminders: on)
        case "calendar": ApplePatch(calendar: on)
        case "home": ApplePatch(home: on)
        case "alarms": ApplePatch(alarms: on)
        case "location": ApplePatch(location: on)
        default: ApplePatch(contacts: on)
        }
    }
}

/// Anmeldung der App als Apple-Gerät (`device.hello` über `/api/ws` bzw. `POST /api/apple/device`).
nonisolated struct AppleDeviceHello: Codable, Equatable, Sendable {
    var type: String = "device.hello"
    var deviceId: String
    var name: String
    var kind: String
    var model: String
    var os: String
    var appVersion: String
    var capabilities: [String]
    var permissions: [String: String]
    var pushToken: String?
    var active: Bool
}

/// Befehl vom Server an das Gerät (`device.cmd` bzw. `POST /api/apple/device/poll`).
nonisolated struct AppleDeviceCommand: Decodable, Sendable, Identifiable {
    var id: String
    var deviceId: String?
    var command: String
    var params: JSONValue

    private enum CodingKeys: String, CodingKey { case id, deviceId = "device_id", command, params }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        command = try c.decode(String.self, forKey: .command)
        params = (try? c.decode(JSONValue.self, forKey: .params)) ?? .object([:])
    }

    /// Mit einfachem Decoder (Schlüssel der Parameter bleiben snake_case).
    static func decodeEnvelope(_ data: Data) -> AppleDeviceCommand? {
        struct Envelope: Decodable { var type: String; var data: AppleDeviceCommand }
        guard let env = try? JSONDecoder().decode(Envelope.self, from: data), env.type == "device.cmd" else { return nil }
        return env.data
    }
}

nonisolated struct AppleDeviceCommands: Decodable, Sendable {
    var commands: [AppleDeviceCommand]
}
