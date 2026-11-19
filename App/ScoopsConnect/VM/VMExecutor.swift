import CoreGraphics
import Foundation

/// Modus „Abgeschirmte VM“: leitet Befehle 1:1 an den Cua-Computer-Server der VM weiter (`POST /cmd`).
final class VMExecutor: CommandExecutor {
    private let lume: LumeManager
    private let session: URLSession

    init(lume: LumeManager) {
        self.lume = lume
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 120
        session = URLSession(configuration: cfg)
    }

    func reset() {}

    func screenSize() async -> CGSize? {
        let r = await execute("get_screen_size", params: .object([:]))
        if let w = r["size"]?["width"]?.double, let h = r["size"]?["height"]?.double { return CGSize(width: w, height: h) }
        return nil
    }

    func execute(_ command: String, params: JSONValue) async -> JSONValue {
        guard let base = lume.baseURL else { return CmdResult.fail("Die VM ist noch nicht bereit.") }
        return await Self.forward(base: base, session: session, command: command, params: params)
    }

    nonisolated static func forward(base: URL, session: URLSession, command: String, params: JSONValue) async -> JSONValue {
        var req = URLRequest(url: base.appending(path: "cmd"), timeoutInterval: command == "screenshot" ? 30 : 60)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = JSONValue.object(["command": .string(command), "params": params]).encoded()
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code == 200 else {
                // FastAPI liefert Fehler als {"detail": …}; Text möglichst durchreichen.
                let detail = JSONValue.decode(data)?["detail"]?.string ?? JSONValue.decode(data)?["error"]?.string
                return CmdResult.fail("Computer-Server der VM: HTTP \(code)" + (detail.map { " – \($0)" } ?? ""))
            }
            return SSE.lastJSON(in: data) ?? CmdResult.fail("Leere Antwort vom Computer-Server der VM")
        } catch {
            return CmdResult.fail("VM nicht erreichbar: \(error.localizedDescription)")
        }
    }
}
