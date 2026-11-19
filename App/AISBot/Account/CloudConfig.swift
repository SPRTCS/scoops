import Foundation

/// Adressen des zentralen Konto-Dienstes (Convex-Projekt `ais-scoops`, Ordner `Cloud/`, docs/accounts.md).
///
/// Convex trennt zwei Hosts: Queries/Mutations laufen über `https://<deployment>.convex.cloud/api/…`,
/// HTTP-Actions (Anmeldung, JWKS, Server-Kopplung) über `https://<deployment>.convex.site/…`.
/// Für Tests lässt sich die Adresse mit dem Startargument `-cloudurl <https://…convex.cloud>` oder dem
/// UserDefaults-Schlüssel `cloudURL` überschreiben.
nonisolated enum CloudConfig {
    /// Produktions-Deployment `ais-scoops` (EU/Irland), Ist-Stand aus docs/accounts.md.
    /// Dev (Tests): `https://merry-vole-238.eu-west-1.convex.cloud`.
    static let defaultCloudURL = "https://helpful-puma-445.eu-west-1.convex.cloud"

    static var cloudURL: URL {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-cloudurl"), i + 1 < args.count, let url = normalized(args[i + 1]) { return url }
        if let stored = UserDefaults.standard.string(forKey: "cloudURL"), let url = normalized(stored) { return url }
        return normalized(defaultCloudURL)!
    }

    /// Host für HTTP-Actions: `.convex.cloud` → `.convex.site` (eigene Domains bleiben unverändert).
    static var siteURL: URL {
        let cloud = cloudURL
        guard var comps = URLComponents(url: cloud, resolvingAgainstBaseURL: false), let host = comps.host,
              host.hasSuffix(".convex.cloud") else { return cloud }
        comps.host = String(host.dropLast(".convex.cloud".count)) + ".convex.site"
        return comps.url ?? cloud
    }

    private static func normalized(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasSuffix("/") { s.removeLast() }
        guard !s.isEmpty, let url = URL(string: s), url.scheme != nil, url.host() != nil else { return nil }
        return url
    }
}
