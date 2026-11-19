import Foundation

/// WebSocket `/api/ws` mit Ping alle 25 s und automatischem Neuverbinden (Rückfall 2 s, 3 s, 5 s, 8 s, dann alle 10 s).
/// Die Anfrage wird bei jedem Aufbau neu erzeugt, damit ein erneuertes Sitzungs-JWT gilt.
final class EventSocket {
    private let makeRequest: () -> URLRequest?
    private let decoder: JSONDecoder
    private let session = URLSession(configuration: .default)
    private var task: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var attempt = 0
    private var wantsConnection = false
    /// Erhöht sich bei jedem Verbindungsaufbau, damit alte Tasks sich still beenden.
    private var generation = 0

    var onEvent: ((ServerEvent) -> Void)?
    var onState: ((SocketState) -> Void)?
    /// Verbunden (erste Antwort erhalten) – erst dann sind Nachrichten an den Server sinnvoll.
    private(set) var isConnected = false

    /// Nachricht an den Server (v1.18: `device.hello`, `device.state`, `device.result`). `false` = nicht verbunden.
    @discardableResult
    func send(_ text: String) -> Bool {
        guard isConnected, let task else { return false }
        task.send(.string(text)) { _ in }
        return true
    }

    init(decoder: JSONDecoder, request: @escaping () -> URLRequest?) {
        self.decoder = decoder
        self.makeRequest = request
    }

    func connect() {
        wantsConnection = true
        guard task == nil else { return }
        open()
    }

    /// Sofort neu verbinden („Neu versuchen“, App wieder aktiv): laufende Verbindung bzw. Wartezeit abbrechen.
    func reconnectNow() {
        wantsConnection = true
        reconnectTask?.cancel(); reconnectTask = nil
        tearDown()
        attempt = 0
        open()
    }

    func disconnect() {
        wantsConnection = false
        generation += 1
        reconnectTask?.cancel(); reconnectTask = nil
        tearDown()
        onState?(.disconnected)
    }

    private func open() {
        generation += 1
        let gen = generation
        onState?(attempt == 0 ? .connecting : .reconnecting(attempt: attempt))
        guard let request = makeRequest() else { return }
        let t = session.webSocketTask(with: request)
        t.maximumMessageSize = 8 * 1024 * 1024
        task = t
        t.resume()

        receiveTask = Task { [weak self] in
            var announced = false
            while !Task.isCancelled {
                guard let self, gen == self.generation, let task = self.task else { return }
                do {
                    let message = try await task.receive()
                    guard gen == self.generation else { return }
                    if !announced {
                        announced = true
                        self.attempt = 0
                        self.isConnected = true
                        self.onState?(.connected)
                    }
                    self.handle(message)
                } catch {
                    guard gen == self.generation else { return }
                    self.scheduleReconnect()
                    return
                }
            }
        }

        // Erste erfolgreiche Antwort (Pong) bestätigt die Verbindung, auch wenn der Server still ist.
        pingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            while !Task.isCancelled {
                guard let self, gen == self.generation else { return }
                self.sendPing()
                try? await Task.sleep(for: .seconds(25))
            }
        }
    }

    private func sendPing() {
        let gen = generation
        // Schlägt der Ping fehl (z. B. Server neu gestartet, Verbindung halb offen), sofort neu verbinden,
        // statt auf ein `receive` zu warten, das nie zurückkommt.
        task?.send(.string(#"{"type":"ping"}"#)) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor [weak self] in
                guard let self, gen == self.generation else { return }
                self.scheduleReconnect()
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let s): data = Data(s.utf8)
        case .data(let d): data = d
        @unknown default: return
        }
        // Gerätebefehle (v1.18) mit einfachem Decoder: Parameter-Schlüssel bleiben snake_case
        if let cmd = AppleDeviceCommand.decodeEnvelope(data) {
            onEvent?(.deviceCommand(cmd))
            return
        }
        do {
            let envelope = try decoder.decode(ServerEventEnvelope.self, from: data)
            onEvent?(envelope.event)
        } catch {
            #if DEBUG
            print("[EventSocket] Ereignis nicht lesbar: \(error)")
            #endif
        }
    }

    private func tearDown() {
        isConnected = false
        receiveTask?.cancel(); receiveTask = nil
        pingTask?.cancel(); pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func scheduleReconnect() {
        tearDown()
        guard wantsConnection else { return }
        attempt += 1
        onState?(.reconnecting(attempt: attempt))
        let delay = ScreenFeed.backoff(after: attempt)
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled, self.wantsConnection else { return }
            self.open()
        }
    }
}
