import CryptoKit
import Foundation
import IOKit

/// Kopplung über `POST /api/nodes/claim` (ohne Auth), siehe docs/scoops-connect.md.
nonisolated enum Pairing {
    struct Claim: Sendable {
        let nodeID: String
        let token: String
        let serverURL: String?
    }

    enum Failure: LocalizedError {
        case invalidURL
        case invalidCode
        case rateLimited
        case server(Int)
        case badResponse
        case network(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: String(localized: "Die Server-Adresse ist ungültig.")
            case .invalidCode: String(localized: "Der Code ist ungültig oder abgelaufen. Erzeuge in AIS Scoops einen neuen.")
            case .rateLimited: String(localized: "Zu viele Versuche. Bitte eine Minute warten.")
            case .server(let code): String(localized: "Der Server hat mit Fehler \(String(code)) geantwortet.")
            case .badResponse: String(localized: "Die Antwort des Servers war unvollständig.")
            case .network(let msg): String(localized: "Server nicht erreichbar: \(msg)")
            }
        }
    }

    /// Bereinigt Eingaben wie „mein-server.de:8787/“ zu `https://mein-server.de:8787`.
    static func normalizeServer(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") {
            let local = s.hasPrefix("127.") || s.hasPrefix("localhost") || s.hasPrefix("192.168.") || s.hasPrefix("10.")
            s = (local ? "http://" : "https://") + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host() != nil else { return nil }
        return url
    }

    /// Normalisiert Eingaben wie „k7qx 29pl“ auf das angezeigte Format „K7QX-29PL“.
    static func normalizeCode(_ raw: String) -> String {
        let cleaned = raw.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleaned.count == 8 else { return raw.trimmingCharacters(in: .whitespaces).uppercased() }
        return String(cleaned.prefix(4)) + "-" + String(cleaned.suffix(4))
    }

    /// Stabile, anonymisierte Geräte-ID dieses Macs (SHA-256 der Hardware-UUID). Der Server erkennt daran eine
    /// Neukopplung desselben Macs und ersetzt den alten Eintrag, statt einen weiteren „Rechner“ anzulegen.
    static let deviceID: String = {
        var raw = ""
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        if service != 0 {
            if let v = IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? String { raw = v }
            IOObjectRelease(service)
        }
        if raw.isEmpty {
            let key = "deviceFallbackID"
            raw = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
            UserDefaults.standard.set(raw, forKey: key)
        }
        let digest = SHA256.hash(data: Data(("ais-scoops-node:" + raw).utf8))
        return "mac-" + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }()

    static func claim(server: URL, code: String, name: String, mode: String, os: String, appVersion: String) async throws -> Claim {
        let url = server.appending(path: "api/nodes/claim")
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(AppLanguage.acceptLanguage, forHTTPHeaderField: "Accept-Language")
        let body: JSONValue = .object([
            "code": .string(normalizeCode(code)), "name": .string(name), "mode": .string(mode),
            "os": .string(os), "app_version": .string(appVersion), "device_id": .string(deviceID),
        ])
        req.httpBody = body.encoded()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200, 201: break
        case 404, 400, 410: throw Failure.invalidCode
        case 429: throw Failure.rateLimited
        default: throw Failure.server(status)
        }
        guard let json = JSONValue.decode(data), let id = json["node_id"]?.string, let token = json["node_token"]?.string,
              !token.isEmpty else { throw Failure.badResponse }
        return Claim(nodeID: id, token: token, serverURL: json["server_url"]?.string)
    }
}
