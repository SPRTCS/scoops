import AVFoundation
import Foundation

/// Audio für den Live-Sprechmodus: Mikrofon → PCM16 mono (24 kHz) in kleinen Paketen, und die vom
/// Server gelieferten PCM16-Pakete gleichmäßig abspielen. Läuft mit Sprachverarbeitung des Systems
/// (Echo-Unterdrückung, Rauschminderung), damit der Scoop sich nicht selbst hört und man ihn jederzeit
/// unterbrechen kann (Barge-in). Callbacks kommen auf dem Audio-Thread.
nonisolated final class LiveAudioIO: @unchecked Sendable {
    /// Abtastrate des Live-Protokolls (siehe docs/API.md, Abschnitt „Live-Sprechmodus“)
    static let sampleRate: Double = 24_000
    /// Paketgröße zum Server: 40 ms
    static let chunkFrames: AVAudioFrameCount = 960

    /// Mikrofon-Paket (PCM16 LE, mono, 24 kHz)
    var onMicChunk: (@Sendable (Data) -> Void)?
    /// Pegel 0…1 (Mikrofon, Wiedergabe) für die Animation
    var onLevels: (@Sendable (Double, Double) -> Void)?

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var converter: AVAudioConverter?
    private var pending = Data()
    private var muted = false
    private let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: sampleRate, channels: 1, interleaved: true)!
    private let floatFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!

    private var configObserver: NSObjectProtocol?
    private var restarts: [Date] = []
    /// Sprachverarbeitung (Echo-Unterdrückung). Im Simulator aus: Dort löst jeder Start sofort die nächste
    /// Umkonfiguration aus. Auf Geräten an; schaukelt sich der Neustart trotzdem auf, wird sie abgeschaltet.
    #if targetEnvironment(simulator)
    private var voiceProcessing = false
    #else
    private var voiceProcessing = true
    #endif

    /// Lautsprecher statt Hörmuschel (Standard). Gemerkt pro Gerät. Bei Kopfhörern/AirPods ohne Wirkung.
    static var prefersSpeaker: Bool {
        get { UserDefaults.standard.object(forKey: "liveVoiceSpeaker") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "liveVoiceSpeaker") }
    }

    func setSpeaker(_ on: Bool) {
        Self.prefersSpeaker = on
        applyOutputRoute()
    }

    /// `voiceChat` schickt den Ton sonst gern an die Hörmuschel (sehr leise, als hielte man das Telefon ans Ohr).
    private func applyOutputRoute() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        let external = session.currentRoute.outputs.contains { [.headphones, .bluetoothA2DP, .bluetoothHFP, .bluetoothLE,
                                                               .airPlay, .carAudio, .usbAudio].contains($0.portType) }
        try? session.overrideOutputAudioPort(!external && Self.prefersSpeaker ? .speaker : .none)
        #endif
    }

    /// Startet Aufnahme und Wiedergabe. Gibt eine deutsche Fehlermeldung zurück oder nil.
    func start() -> String? {
        stop()
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // voiceChat: Echo-Unterdrückung und automatische Pegelanpassung des Systems; AirPods per HFP
            try session.setCategory(.playAndRecord, mode: .voiceChat,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP, .duckOthers])
            try session.setPreferredIOBufferDuration(0.02)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            guard session.isInputAvailable else { return "Kein Mikrofon verfügbar." }
        } catch {
            return "Audio konnte nicht gestartet werden."
        }
        #endif
        lock.lock(); restarts = []; lock.unlock()
        let error = startEngine()
        applyOutputRoute()
        return error
    }

    /// Baut die Audio-Engine (neu) auf. Wird auch nach einer Konfigurationsänderung aufgerufen
    /// (Sprachverarbeitung aktiviert, AirPods verbunden/getrennt, Route gewechselt): Dann stoppt AVAudioEngine
    /// sich selbst und muss mit dem neuen Eingabeformat neu gestartet werden.
    private func startEngine() -> String? {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        // Echo-Unterdrückung (iOS und macOS). Ohne sie würde der Scoop sich selbst unterbrechen.
        lock.lock(); let vp = voiceProcessing; lock.unlock()
        if vp {
            try? input.setVoiceProcessingEnabled(true)
            #if os(iOS)
            input.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            #endif
        }
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.channelCount > 0, inFormat.sampleRate > 0 else { return "Kein Mikrofon gefunden." }
        guard let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: inFormat.sampleRate,
                                       channels: 1, interleaved: false),
              let conv = AVAudioConverter(from: mono, to: pcmFormat) else { return "Audioformat wird nicht unterstützt." }

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: floatFormat)

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
            self?.capture(buffer, monoFormat: mono)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return "Mikrofon konnte nicht gestartet werden."
        }
        player.play()
        let observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                              queue: nil) { [weak self] _ in self?.configurationChanged() }
        lock.lock()
        self.engine = engine
        self.player = player
        self.converter = conv
        self.configObserver = observer
        pending = Data()
        lock.unlock()
        return nil
    }

    private func configurationChanged() {
        lock.lock()
        let now = Date()
        restarts = restarts.filter { now.timeIntervalSince($0) < 10 } + [now]
        if restarts.filter({ now.timeIntervalSince($0) < 3 }).count >= 3 { voiceProcessing = false }
        let tooMany = restarts.count > 8
        let running = engine != nil
        lock.unlock()
        guard running, !tooMany else { return }
        // Kurz warten, bis das System mit der Umkonfiguration fertig ist, dann neu aufbauen
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let stillRunning = self.engine != nil
            self.lock.unlock()
            guard stillRunning else { return }
            self.tearDownEngine()
            _ = self.startEngine()
            self.applyOutputRoute()
        }
    }

    private func tearDownEngine() {
        lock.lock()
        let engine = self.engine, player = self.player, observer = configObserver
        self.engine = nil
        self.player = nil
        converter = nil
        configObserver = nil
        pending = Data()
        lock.unlock()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        player?.stop()
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    func stop() {
        tearDownEngine()
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Mikrofon stummschalten (Pause): es gehen nur noch leise Pakete an den Server.
    func setMuted(_ value: Bool) {
        lock.lock(); muted = value; lock.unlock()
    }

    /// Antwort-Audio (PCM16 LE mono 24 kHz) zur Wiedergabe einreihen. Live liefert einen durchgehenden Strom
    /// (auch Stille, etwa in Echtzeit), daher bleibt die Warteschlange kurz; der Pegel zeigt, ob gesprochen wird.
    func play(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: floatFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        var sum: Float = 0
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames {
                let v = Float(Int16(littleEndian: src[i])) / 32768
                out[i] = v
                sum += v * v
            }
        }
        lock.lock()
        let player = self.player
        lock.unlock()
        player?.scheduleBuffer(buffer, completionHandler: nil)
        onLevels?(-1, Double(min(1, sqrt(sum / Float(frames)) * 6)))
    }

    /// Barge-in: alles noch nicht Gespielte sofort verwerfen.
    func flushPlayback() {
        lock.lock()
        let player = self.player
        lock.unlock()
        guard let player else { return }
        player.stop()
        player.play()
    }

    // MARK: Aufnahme (Audio-Thread)

    private func capture(_ buffer: AVAudioPCMBuffer, monoFormat: AVAudioFormat) {
        lock.lock()
        let conv = converter, isMuted = muted
        lock.unlock()
        guard let conv, let src = buffer.floatChannelData, buffer.frameLength > 0 else { return }
        let n = Int(buffer.frameLength)
        // Auf mono mischen (Sprachverarbeitung liefert teils mehrere Kanäle)
        guard let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength) else { return }
        mono.frameLength = buffer.frameLength
        let dst = mono.floatChannelData![0]
        let channels = Int(buffer.format.channelCount)
        var sum: Float = 0
        for i in 0..<n {
            var v: Float = 0
            for c in 0..<channels { v += src[c][i] }
            v /= Float(channels)
            if isMuted { v = 0 }
            dst[i] = v
            sum += v * v
        }
        onLevels?(Double(min(1, sqrt(sum / Float(n)) * 12)), -1)
        let capacity = AVAudioFrameCount(Double(n) * Self.sampleRate / monoFormat.sampleRate + 64)
        guard let out = AVAudioPCMBuffer(pcmFormat: pcmFormat, frameCapacity: capacity) else { return }
        var supplied = false
        var error: NSError?
        conv.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return mono
        }
        guard error == nil, out.frameLength > 0, let ptr = out.int16ChannelData else { return }
        let bytes = Data(bytes: ptr[0], count: Int(out.frameLength) * 2)
        lock.lock()
        pending.append(bytes)
        var chunks: [Data] = []
        let size = Int(Self.chunkFrames) * 2
        while pending.count >= size {
            chunks.append(pending.prefix(size))
            pending.removeFirst(size)
        }
        lock.unlock()
        for c in chunks { onMicChunk?(Data(c)) }
    }
}
