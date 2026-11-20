import AVFoundation
import Foundation
import Observation

/// Live-Sprechmodus (GPT-Live-1 über den eigenen Server): WebSocket `/api/voice/live?chat=<id>`.
/// Mikrofon-Audio geht als Binärpaket (PCM16, 24 kHz, mono) zum Server, Antwort-Audio kommt genauso zurück.
/// Steuerung und Untertitel als JSON (Protokoll: docs/API.md, Abschnitt „Live-Sprechmodus“).
@Observable
@MainActor
final class LiveVoiceSession {
    enum State: Equatable {
        case idle, connecting, live
        /// Sitzung beendet (Grund für den Nutzer, z. B. „2 Minuten Stille“)
        case ended(String)
        /// Live nicht möglich → Rückfall auf Gerätestimme
        case failed(String)
    }

    struct Caption: Identifiable, Equatable {
        let id: Int
        let role: String  // "user" | "assistant"
        var text: String
    }

    private(set) var state: State = .idle
    private(set) var captions: [Caption] = []
    /// Laufzeit und geschätzte Kosten laut Server
    private(set) var seconds: Double = 0
    private(set) var costUsd: Double = 0
    private(set) var maxSeconds: Double = 900
    private(set) var voice: String?
    /// Scoop erledigt gerade eine Aufgabe im normalen Lauf (Mails, Kalender, Recherche …)
    private(set) var taskRunning = false
    private(set) var taskText: String?
    private(set) var micLevel: Double = 0
    private(set) var outLevel: Double = 0
    private(set) var muted = false
    /// Spricht der Scoop gerade hörbar (Audio in der Wiedergabe)?
    private(set) var botSpeaking = false
    /// Wartet auf die Mikrofon-Freigabe des Systems
    private(set) var awaitingPermission = false

    @ObservationIgnored private let audio = LiveAudioIO()
    @ObservationIgnored private var task: URLSessionWebSocketTask?
    @ObservationIgnored private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpAdditionalHeaders = ["Accept-Language": AppLanguage.acceptLanguage]
        return URLSession(configuration: config)
    }()
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var captionID = 0
    @ObservationIgnored private var lastRole: String?
    @ObservationIgnored private var gotReady = false

    /// Verbindet und startet Mikrofon/Wiedergabe. `request` kommt vom APIClient (inkl. Anmeldung).
    func start(request: URLRequest) async {
        stop(sendBye: false)
        state = .connecting
        gotReady = false
        captions = []
        seconds = 0; costUsd = 0; taskRunning = false; taskText = nil
        awaitingPermission = true
        let allowed = await Self.micPermission()
        awaitingPermission = false
        guard allowed else {
            state = .failed(String(localized: "Bitte erlaube den Zugriff aufs Mikrofon in den Einstellungen."))
            return
        }
        let t = urlSession.webSocketTask(with: request)
        t.maximumMessageSize = 4 * 1024 * 1024
        task = t
        t.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(t) }
        // Kommt nach 15 s kein „ready“, Rückfall auf die Gerätestimme
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard let self, self.task === t, !self.gotReady, self.state == .connecting else { return }
            self.fail(String(localized: "Live-Verbindung kommt nicht zustande."))
        }
    }

    func stop(sendBye: Bool = true) {
        if sendBye, let task { task.send(.string(#"{"type":"stop"}"#)) { _ in } }
        receiveTask?.cancel(); receiveTask = nil
        meterTask?.cancel(); meterTask = nil
        let t = task
        task = nil
        audio.onMicChunk = nil
        audio.onLevels = nil
        audio.stop()
        if let t {
            // Kurz Zeit lassen, damit „stop“ ankommt und der Server die Sitzung sauber beendet
            Task {
                try? await Task.sleep(for: .milliseconds(400))
                t.cancel(with: .normalClosure, reason: nil)
            }
        }
        botSpeaking = false
        micLevel = 0; outLevel = 0
        if state == .live || state == .connecting { state = .idle }
    }

    /// Lautsprecher (true) oder Hörmuschel (false)
    var speakerOn: Bool = LiveAudioIO.prefersSpeaker

    func setSpeaker(_ on: Bool) {
        speakerOn = on
        audio.setSpeaker(on)
    }

    func setMuted(_ value: Bool) {
        muted = value
        audio.setMuted(value)
        send(json: ["type": "mute", "muted": value])
    }

    /// Antippen während der Scoop spricht: Wiedergabe sofort abbrechen (Server bricht die Antwort ab).
    func interrupt() {
        audio.flushPlayback()
        send(json: ["type": "interrupt"])
    }

    // MARK: Empfang

    private func receiveLoop(_ t: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let message = try await t.receive()
                guard task === t else { return }
                switch message {
                case .data(let d): audio.play(d)
                case .string(let s): handle(s)
                @unknown default: break
                }
            } catch {
                guard task === t else { return }
                if case .live = state {
                    finish(.ended(String(localized: "Verbindung unterbrochen.")))
                } else if !gotReady {
                    fail(String(localized: "Live ist gerade nicht erreichbar."))
                }
                return
            }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "ready":
            gotReady = true
            voice = obj["voice"] as? String
            if let m = obj["max_seconds"] as? Double { maxSeconds = m }
            startAudio()
        case "transcript":
            guard let role = obj["role"] as? String, let delta = obj["text"] as? String, !delta.isEmpty else { return }
            appendCaption(role: role, delta: delta)
        case "turn":
            // Abgeschlossener Beitrag (liegt jetzt als Chat-Nachricht vor): nächster Beitrag beginnt neu
            lastRole = nil
        case "interrupt":
            audio.flushPlayback()
        case "task":
            let st = obj["state"] as? String
            taskRunning = st == "running"
            taskText = obj["text"] as? String
        case "usage":
            if let s = obj["seconds"] as? Double { seconds = s }
            if let c = obj["cost_usd"] as? Double { costUsd = c }
        case "end":
            finish(.ended((obj["message"] as? String) ?? String(localized: "Gespräch beendet.")))
        case "error":
            let message = (obj["message"] as? String) ?? String(localized: "Live ist gerade nicht verfügbar.")
            if !gotReady || (obj["fallback"] as? Bool) == true { fail(message) } else { finish(.ended(message)) }
        default:
            break
        }
    }

    private func appendCaption(role: String, delta: String) {
        if lastRole == role, let i = captions.indices.last, captions[i].role == role {
            captions[i].text += delta
        } else {
            captionID += 1
            captions.append(Caption(id: captionID, role: role, text: String(delta.drop(while: { $0 == " " }))))
            if captions.count > 30 { captions.removeFirst(captions.count - 30) }
        }
        lastRole = role
    }

    private func startAudio() {
        audio.onMicChunk = { [weak self] chunk in
            Task { @MainActor in self?.task?.send(.data(chunk)) { _ in } }
        }
        audio.onLevels = { [weak self] mic, out in
            Task { @MainActor in
                guard let self else { return }
                if mic >= 0 { self.micLevel = self.micLevel * 0.6 + mic * 0.4 }
                if out >= 0 { self.outLevel = max(out, self.outLevel * 0.7) }
            }
        }
        if let error = audio.start() {
            fail(error)
            return
        }
        state = .live
        meterTask = Task { [weak self] in
            // „Spricht“ = hörbarer Pegel im Antwortstrom (Live sendet auch Stille), mit kurzer Haltezeit
            var quietTicks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self else { return }
                quietTicks = self.outLevel > 0.04 ? 0 : quietTicks + 1
                let speaking = quietTicks < 4
                if speaking != self.botSpeaking { self.botSpeaking = speaking }
                self.outLevel *= 0.75
            }
        }
    }

    private func send(json: [String: Any]) {
        guard let task, let data = try? JSONSerialization.data(withJSONObject: json),
              let s = String(data: data, encoding: .utf8) else { return }
        task.send(.string(s)) { _ in }
    }

    private func fail(_ message: String) {
        stop(sendBye: true)
        state = .failed(message)
    }

    private func finish(_ newState: State) {
        stop(sendBye: false)
        state = newState
    }

    private nonisolated static func micPermission() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}
