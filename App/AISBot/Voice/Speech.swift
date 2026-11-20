import AVFoundation
import Foundation
import Speech
import Synchronization

/// Diktat auf dem Gerät (Speech-Framework, Sprache der App: `AppLanguage.speechIdentifier`, z. B. de-DE oder en-US). Liefert laufend den erkannten Text,
/// optional mit Ende-der-Rede-Erkennung nach einer Pause (Sprachmodus).
@Observable
final class Dictation {
    /// Gesamter erkannter Text: abgeschlossene Abschnitte + aktueller Teil.
    private(set) var transcript = ""
    private(set) var isRecording = false
    /// Pegel 0…1 für die Wellenanimation
    private(set) var level: Double = 0
    /// Wird nach `silenceTimeout` Sekunden Stille mit dem fertigen Text aufgerufen (nur Sprachmodus).
    @ObservationIgnored var onEndOfSpeech: ((String) -> Void)?
    @ObservationIgnored var silenceTimeout: Double = 1.2
    /// Aufnahme der letzten Sitzung (16 kHz mono AAC) für die genaue Erkennung auf dem Server.
    @ObservationIgnored private(set) var lastRecording: URL?

    /// Erst beim Start anlegen: SFSpeechRecognizer spricht beim Erzeugen mit einem Systemdienst (blockiert sonst
    /// den Hauptthread bei jedem Öffnen eines Chats).
    @ObservationIgnored private lazy var recognizer = SFSpeechRecognizer(locale: Locale(identifier: AppLanguage.speechIdentifier))
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private let requestBox = RequestBox()
    @ObservationIgnored private var task: SFSpeechRecognitionTask?
    @ObservationIgnored private var recorder: AudioRecorderSink?
    @ObservationIgnored private var silenceTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var continuous = true
    /// Bereits abgeschlossene Abschnitte (nach Pausen beginnt die Erkennung neu)
    @ObservationIgnored private var committed = ""
    @ObservationIgnored private var partial = ""

    /// Startet die Aufnahme. Gibt eine Fehlermeldung (in der Sprache der App) zurück oder nil.
    func start(continuous: Bool) async -> String? {
        stop()
        self.continuous = continuous
        guard await Self.requestSpeechPermission() else {
            return String(localized: "Bitte erlaube die Spracherkennung in den Einstellungen.")
        }
        guard await Self.requestMicPermission() else {
            return String(localized: "Bitte erlaube den Zugriff aufs Mikrofon in den Einstellungen.")
        }
        guard let recognizer, recognizer.isAvailable else {
            return String(localized: "Die Spracherkennung ist gerade nicht verfügbar.")
        }
        #if os(iOS)
        do {
            try AudioSessionConfig.activate()
        } catch {
            return String(localized: "Mikrofon konnte nicht gestartet werden.")
        }
        guard AVAudioSession.sharedInstance().isInputAvailable else { return String(localized: "Kein Mikrofon verfügbar.") }
        #else
        guard AVCaptureDevice.default(for: .audio) != nil else { return String(localized: "Kein Mikrofon verfügbar.") }
        #endif

        let engine = AVAudioEngine()
        generation += 1
        let gen = generation
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.channelCount > 0, format.sampleRate > 0 else { return String(localized: "Kein Mikrofon gefunden.") }
        let recorder = AudioRecorderSink(inputFormat: format)
        Self.installTap(on: input, format: format, box: requestBox, recorder: recorder) { [weak self] level in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                self.level = self.level * 0.6 + level * 0.4
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return String(localized: "Mikrofon konnte nicht gestartet werden.")
        }
        self.engine = engine
        self.recorder = recorder
        lastRecording = nil
        committed = ""
        partial = ""
        transcript = ""
        isRecording = true
        startRecognitionSegment(gen: gen)
        return nil
    }

    /// Neuer Erkennungsabschnitt mit frischer Anfrage; die Audioaufnahme läuft dabei weiter.
    private func startRecognitionSegment(gen: Int) {
        guard let recognizer else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        request.taskHint = continuous ? .dictation : .search
        requestBox.set(request)
        task = Self.recognize(recognizer: recognizer, request: request) { [weak self] text, isFinal, failed in
            Task { @MainActor in
                guard let self, self.generation == gen else { return }
                if let text { self.handle(text: text) }
                if isFinal || failed { self.segmentEnded(gen: gen) }
            }
        }
    }

    /// Stoppt die Aufnahme. Die Aufnahme-Datei steht danach in `lastRecording`.
    func stop() {
        generation += 1
        silenceTask?.cancel()
        silenceTask = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        requestBox.current?.endAudio()
        requestBox.set(nil)
        task?.cancel()
        if let recorder { lastRecording = recorder.finish() }
        engine = nil
        task = nil
        recorder = nil
        isRecording = false
        level = 0
    }

    /// Ergebnis eines Abschnitts. Nach einer Pause beginnt die Erkennung oft wieder bei null –
    /// dann wird der bisherige Teil übernommen und der neue angehängt, statt ihn zu ersetzen.
    private func handle(text: String) {
        if !partial.isEmpty, text.count < partial.count / 2, !partial.lowercased().hasPrefix(text.lowercased().prefix(8)) {
            commit(partial)
        }
        partial = text
        transcript = Self.join(committed, partial)
        guard onEndOfSpeech != nil else { return }
        silenceTask?.cancel()
        let gen = generation
        silenceTask = Task {
            try? await Task.sleep(for: .seconds(silenceTimeout))
            guard !Task.isCancelled, gen == generation, !transcript.isEmpty else { return }
            let final = transcript
            stop()
            onEndOfSpeech?(final)
        }
    }

    private func commit(_ text: String) {
        committed = Self.join(committed, text)
        partial = ""
    }

    private func segmentEnded(gen: Int) {
        commit(partial)
        transcript = committed
        if isRecording && continuous && onEndOfSpeech == nil {
            // Diktat läuft weiter: nächster Abschnitt
            startRecognitionSegment(gen: gen)
        } else if isRecording {
            let final = transcript
            let callback = onEndOfSpeech
            stop()
            if let callback, !final.isEmpty { callback(final) }
        }
    }

    private static func join(_ a: String, _ b: String) -> String {
        let a = a.trimmingCharacters(in: .whitespaces), b = b.trimmingCharacters(in: .whitespaces)
        if a.isEmpty { return b }
        if b.isEmpty { return a }
        return a + " " + b
    }

    // MARK: Nicht isolierte Helfer (Audio- und Erkennungs-Callbacks laufen auf fremden Threads)

    private nonisolated static func installTap(on node: AVAudioInputNode, format: AVAudioFormat, box: RequestBox,
                                               recorder: AudioRecorderSink?,
                                               level: @escaping @Sendable (Double) -> Void) {
        node.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            box.current?.append(buffer)
            recorder?.append(buffer)
            guard let data = buffer.floatChannelData?[0] else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += data[i] * data[i] }
            let rms = sqrt(sum / Float(n))
            level(Double(min(1, rms * 12)))
        }
    }

    private nonisolated static func recognize(recognizer: SFSpeechRecognizer, request: SFSpeechAudioBufferRecognitionRequest,
                                              handler: @escaping @Sendable (String?, Bool, Bool) -> Void) -> SFSpeechRecognitionTask {
        recognizer.recognitionTask(with: request) { result, error in
            let text = result?.bestTranscription.formattedString
            handler(text, result?.isFinal ?? false, error != nil)
        }
    }

    private nonisolated static func requestSpeechPermission() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status == .authorized) }
        }
    }

    private nonisolated static func requestMicPermission() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}

#if os(iOS)
enum AudioSessionConfig {
    /// Aufnahme und Wiedergabe über den Lautsprecher (Diktat und Sprachmodus).
    static func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default,
                                options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)
    }
}
#endif

/// Vorlesen mit AVSpeechSynthesizer.
@Observable
@MainActor
final class Speaker: NSObject, AVSpeechSynthesizerDelegate {
    private(set) var isSpeaking = false
    @ObservationIgnored var onFinish: (() -> Void)?
    /// Erst bei Bedarf anlegen (Systemdienst).
    @ObservationIgnored private lazy var synth: AVSpeechSynthesizer = {
        let s = AVSpeechSynthesizer()
        s.delegate = self
        return s
    }()

    func speak(_ text: String, voiceID: String?) {
        stop()
        #if os(iOS)
        try? AudioSessionConfig.activate()
        #endif
        let plain = MarkdownText.plain(text)
        let utterance = AVSpeechUtterance(string: plain)
        utterance.voice = VoiceCatalog.voice(for: voiceID)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 1.02
        utterance.prefersAssistiveTechnologySettings = false
        isSpeaking = true
        synth.speak(utterance)
    }

    func stop() {
        if isSpeaking, synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            self.isSpeaking = false
            self.onFinish?()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = false }
    }
}

/// Verfügbare Stimmen in der Sprache der App (Deutsch bzw. Englisch).
nonisolated enum VoiceCatalog {
    /// Stimmenliste einmalig laden (Systemabfrage ist langsam), danach aus dem Zwischenspeicher.
    private static let cache = Mutex<[AVSpeechSynthesisVoice]?>(nil)

    static func preload() {
        Task.detached(priority: .utility) { _ = voices() }
    }

    /// Stimmen der App-Sprache, Stimmen der Region des Geräts zuerst (z. B. en-US vor en-GB), dann nach Qualität.
    static func voices() -> [AVSpeechSynthesisVoice] {
        if let hit = cache.withLock({ $0 }) { return hit }
        let list = loadVoices()
        cache.withLock { $0 = list }
        return list
    }

    private static func loadVoices() -> [AVSpeechSynthesisVoice] {
        let preferred = AppLanguage.speechIdentifier
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix(AppLanguage.code) && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                // Deutsch wie bisher nur nach Qualität und Name; Englisch zusätzlich Region des Geräts zuerst
                if !AppLanguage.isGerman, (a.language == preferred) != (b.language == preferred) { return a.language == preferred }
                if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
                return a.name < b.name
            }
    }

    /// Gewählte Stimme, sonst die beste der App-Sprache (Premium vor Erweitert vor Standard).
    static func voice(for identifier: String?) -> AVSpeechSynthesisVoice? {
        // Feld `voice` des Scoops: „device:<id>“, alte Kennung oder „live:<name>“ (dann beste Gerätestimme)
        if let id = VoiceChoice(identifier).deviceID, let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return voices().first ?? AVSpeechSynthesisVoice(language: AppLanguage.speechIdentifier)
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: String(localized: "Premium", comment: "Qualität einer Gerätestimme")
        case .enhanced: String(localized: "Erweitert", comment: "Qualität einer Gerätestimme (Enhanced)")
        default: String(localized: "Standard", comment: "Qualität einer Gerätestimme")
        }
    }
}


/// Aktuelle Erkennungsanfrage, threadsicher für den Audio-Thread.
nonisolated final class RequestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    var current: SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        return request
    }

    func set(_ r: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = r; lock.unlock()
    }
}

/// Nimmt parallel zur Live-Erkennung auf: 16 kHz mono AAC (.m4a) für die genaue Erkennung auf dem Server.
nonisolated final class AudioRecorderSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private let converter: AVAudioConverter?
    private let outFormat: AVAudioFormat
    private let inputRate: Double
    let url: URL

    init?(inputFormat: AVAudioFormat) {
        guard let out = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
        else { return nil }
        outFormat = out
        inputRate = inputFormat.sampleRate
        url = FileManager.default.temporaryDirectory.appending(path: "diktat-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        do {
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            return nil
        }
        converter = AVAudioConverter(from: inputFormat, to: out)
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let file, let converter else { return }
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * outFormat.sampleRate / inputRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        if error == nil, out.frameLength > 0 { try? file.write(from: out) }
    }

    /// Schließt die Datei und gibt sie zurück (nil, wenn nichts aufgenommen wurde).
    func finish() -> URL? {
        lock.lock(); defer { lock.unlock() }
        let had = file != nil
        file = nil
        guard had, let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 1000 else { return nil }
        return url
    }
}
