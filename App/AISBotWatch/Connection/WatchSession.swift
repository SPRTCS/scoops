import Foundation
import WatchConnectivity

/// WatchConnectivity auf der Uhr: empfängt Zugangsdaten vom iPhone (applicationContext), fragt bei Bedarf frische
/// an und reicht Server-Anfragen über das iPhone weiter, wenn die Uhr den Server nicht selbst erreicht.
final class WatchSession: NSObject, WCSessionDelegate {
    static let shared = WatchSession()

    /// Neue Zugangsdaten vom iPhone
    var onCredentials: ((WatchCredentials) -> Void)?

    private var session: WCSession? { WCSession.isSupported() ? WCSession.default : nil }

    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    /// iPhone gerade erreichbar (Bluetooth/WLAN, App kann im Hintergrund geweckt werden)
    var isPhoneReachable: Bool { session?.activationState == .activated && session?.isReachable == true }

    // MARK: Anfragen an das iPhone

    /// Bittet das iPhone um frische Zugangsdaten (z. B. erneuertes Konto-JWT). nil = iPhone nicht erreichbar.
    func requestCredentials() async -> WatchCredentials? {
        guard isPhoneReachable, let session else { return nil }
        let reply = await send(session, [WatchLink.kindKey: WatchLink.Kind.credentials.rawValue])
        guard let data = reply?[WatchLink.credentialsKey] as? Data, let creds = WatchCredentials.decode(data) else { return nil }
        onCredentials?(creds)
        return creds
    }

    /// Server-Anfrage über das iPhone. Antwort: Status und Daten; nil = iPhone nicht erreichbar.
    func relay(serverID: String, method: String, path: String, query: [URLQueryItem], body: Data?) async -> (Int, Data)? {
        guard isPhoneReachable, let session else { return nil }
        var message: [String: Any] = [
            WatchLink.kindKey: WatchLink.Kind.relay.rawValue,
            WatchLink.serverKey: serverID,
            WatchLink.methodKey: method,
            WatchLink.pathKey: path,
            WatchLink.queryKey: query.reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" },
        ]
        if let body { message[WatchLink.bodyKey] = body }
        guard let reply = await send(session, message), let status = reply[WatchLink.statusKey] as? Int else { return nil }
        return (status, reply[WatchLink.dataKey] as? Data ?? Data())
    }

    private func send(_ session: WCSession, _ message: [String: Any]) async -> [String: Any]? {
        await withCheckedContinuation { (cont: CheckedContinuation<[String: Any]?, Never>) in
            let box = ResumeOnce(cont)
            session.sendMessage(message, replyHandler: { reply in
                box.resume(nonisolatedCopy(reply))
            }, errorHandler: { _ in
                box.resume(nil)
            })
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        guard let data = context[WatchLink.credentialsKey] as? Data, let creds = WatchCredentials.decode(data) else { return }
        Task { @MainActor in WatchSession.shared.onCredentials?(creds) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let data = applicationContext[WatchLink.credentialsKey] as? Data,
              let creds = WatchCredentials.decode(data) else { return }
        Task { @MainActor in WatchSession.shared.onCredentials?(creds) }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard let data = userInfo[WatchLink.credentialsKey] as? Data, let creds = WatchCredentials.decode(data) else { return }
        Task { @MainActor in WatchSession.shared.onCredentials?(creds) }
    }
}

/// `[String: Any]` ist nicht Sendable; WatchConnectivity liefert nur Property-List-Werte, die wir sofort kopieren.
nonisolated private func nonisolatedCopy(_ dict: [String: Any]) -> [String: Any] { dict }

/// Fortsetzung genau einmal (Antwort- und Fehler-Handler können beide feuern)
nonisolated private final class ResumeOnce: @unchecked Sendable {
    private var cont: CheckedContinuation<[String: Any]?, Never>?
    private let lock = NSLock()

    init(_ cont: CheckedContinuation<[String: Any]?, Never>) { self.cont = cont }

    func resume(_ value: [String: Any]?) {
        lock.lock()
        let c = cont
        cont = nil
        lock.unlock()
        nonisolated(unsafe) let v = value
        c?.resume(returning: v)
    }
}
