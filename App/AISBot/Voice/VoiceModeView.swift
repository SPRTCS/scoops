import SwiftUI

/// Sprechmodus. Standard ist **Live** (GPT-Live-1 über den Server): Sprache zu Sprache, natürliche Stimme,
/// Unterbrechen jederzeit, Live-Untertitel, Laufzeit und Kosten. Gesprochenes landet als Chat-Nachrichten im Verlauf.
///
/// Rückfall „Gerätestimme“ (offline): zuhören → senden (`voice: true`) → „denkt nach …“ → Antwort mit
/// Apples Systemstimme vorlesen → wieder zuhören. Greift, wenn im Profil die Gerätestimme gewählt ist, der Server
/// keinen OpenAI-Schlüssel hat oder die Live-Verbindung scheitert.
struct VoiceModeView: View {
    let chatID: String
    /// Nur für Screenshots/Vorschauen: zeigt einen festen Zustand, ohne Mikrofon.
    var demoPhase: Phase? = nil

    enum Phase: Equatable {
        case starting, listening, thinking, speaking, paused
        case failed(String)
        /// Live-Sprechmodus (Zustand steht in `LiveVoiceSession`)
        case live
    }

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var dictation = Dictation()
    @State private var speaker = Speaker()
    @State private var live = LiveVoiceSession()
    @State private var phase: Phase = .starting
    @State private var sentMessageID: String?
    @State private var spokenIDs: Set<String> = []
    @State private var lastReply = ""
    @State private var preciseText: String?
    /// Hinweis, warum die Gerätestimme spricht (Live gescheitert bzw. nicht verfügbar)
    @State private var fallbackNote: String?

    private var bot: Bot? { store.bot(chatID) }
    private var isLiveDemo: Bool { demoPhase == .live }
    private var usesLive: Bool { isLiveDemo || phase == .live }

    var body: some View {
        let current = demoPhase ?? phase
        ZStack {
            theme.background.ignoresSafeArea()
            VStack(spacing: 18) {
                header
                Spacer(minLength: 6)

                Button(action: tapMascot) {
                    ZStack {
                        Circle()
                            .fill(theme.accent.opacity(0.05 + ringLevel(current) * 0.25))
                            .frame(width: 280, height: 280)
                            .scaleEffect(1 + ringLevel(current) * 0.18)
                            .animation(.easeOut(duration: 0.12), value: ringLevel(current))
                        if let bot {
                            MascotView(mascot: bot.mascot, size: 220, mood: mood(for: current), seed: bot.id, showsGround: true)
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(accessibilityHint(current))

                VStack(spacing: 8) {
                    Text(statusText(current))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusIsActive(current) ? theme.accent : theme.textSecondary)
                        .contentTransition(.opacity)
                        .multilineTextAlignment(.center)
                    if usesLive {
                        liveCaptions
                    } else {
                        Text(captionText(current))
                            .font(.system(size: 17))
                            .foregroundStyle(theme.textPrimary)
                            .multilineTextAlignment(.center)
                            .lineLimit(5)
                            .frame(maxWidth: 420, minHeight: 70, alignment: .top)
                            .animation(.smooth, value: captionText(current))
                    }
                }

                Spacer(minLength: 6)
                controls(current)
                    .padding(.bottom, 6)
            }
            .padding(24)
        }
        #if os(macOS)
        .frame(width: 520, height: 700)
        #endif
        .task {
            guard demoPhase == nil else { return }
            dictation.onEndOfSpeech = { text in Task { await send(text) } }
            speaker.onFinish = { listen() }
            await start()
        }
        .onDisappear {
            live.stop()
            dictation.stop()
            speaker.stop()
        }
        .onChange(of: live.state) { _, state in
            // Live gescheitert → automatisch Gerätestimme
            if case .failed(let message) = state, phase == .live {
                fallbackNote = "\(message) Ich nutze die Gerätestimme."
                phase = .starting
                listen()
            }
        }
        .onChange(of: replyToSpeak?.id) { _, _ in
            guard let reply = replyToSpeak, demoPhase == nil, phase != .live else { return }
            spokenIDs.insert(reply.id)
            lastReply = MarkdownText.plain(reply.text)
            phase = .speaking
            speaker.speak(reply.text, voiceID: bot?.voice)
        }
    }

    // MARK: Kopfzeile

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(bot?.name ?? "Sprechmodus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.textPrimary)
                if usesLive {
                    liveBadge
                } else if let fallbackNote {
                    Label(fallbackNote, systemImage: "speaker.wave.2")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                } else if demoPhase == nil {
                    Label("Gerätestimme", systemImage: "speaker.wave.2")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                }
            }
            Spacer()
            CircleIconButton(systemName: "xmark", help: "Sprechmodus beenden", size: 32) { end() }
        }
    }

    /// „Live · Marin · 1:23 · ≈ 0,07 $“
    private var liveBadge: some View {
        let seconds = isLiveDemo ? 83 : live.seconds
        let cost = isLiveDemo ? 0.07 : live.costUsd
        let voice = (isLiveDemo ? "marin" : live.voice).map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return HStack(spacing: 6) {
            HStack(spacing: 4) {
                Circle().fill(theme.danger).frame(width: 6, height: 6)
                Text("Live").font(.system(size: 11.5, weight: .bold))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(theme.danger.opacity(0.12), in: Capsule())
            .foregroundStyle(theme.danger)
            Text([voice, Self.duration(seconds), "≈ " + Self.dollars(cost)].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(theme.textSecondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live-Gespräch, \(Self.duration(seconds)), etwa \(Self.dollars(cost))")
    }

    static func duration(_ s: Double) -> String {
        let t = Int(s.rounded(.down))
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    static func dollars(_ v: Double) -> String {
        v.formatted(.currency(code: "USD").precision(.fractionLength(v < 0.1 ? 3 : 2)).locale(Locale(identifier: "de-DE")))
    }

    // MARK: Untertitel (Live)

    private var liveCaptions: some View {
        let lines: [LiveVoiceSession.Caption] = isLiveDemo ? [
            .init(id: 1, role: "user", text: "Was steht morgen bei mir an?"),
            .init(id: 2, role: "assistant", text: "Um neun hast du Jonas, danach geht's nach Köln-Deutz. Soll ich dir die Bahn raussuchen?"),
        ] : Array(live.captions.suffix(3))
        return VStack(spacing: 8) {
            if let text = isLiveDemo ? nil : live.taskText, live.taskRunning {
                Label(text, systemImage: "gearshape.2")
                    .font(.system(size: 12.5))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(theme.surface, in: Capsule())
            }
            ForEach(lines) { line in
                Text(line.text)
                    .font(.system(size: line.id == lines.last?.id ? 17 : 15))
                    .foregroundStyle(line.role == "user" ? theme.textSecondary : theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .lineLimit(line.id == lines.last?.id ? 4 : 2)
                    .frame(maxWidth: 440)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if lines.isEmpty {
                Text(liveIdleCaption)
                    .font(.system(size: 17))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        .frame(minHeight: 110, alignment: .top)
        .animation(.smooth, value: lines.map(\.text))
    }

    private var liveIdleCaption: String {
        switch live.state {
        case .connecting:
            return live.awaitingPermission ? "Bitte erlaube den Zugriff aufs Mikrofon." : "Verbinde mit der Live-Stimme …"
        case .ended(let m): return m
        default: return "Sprich einfach los – du kannst jederzeit dazwischenreden."
        }
    }

    // MARK: Steuerung

    @ViewBuilder
    private func controls(_ current: Phase) -> some View {
        HStack(spacing: 18) {
            if usesLive, case .ended = live.state, !isLiveDemo {
                controlButton("arrow.clockwise", label: "Neu starten") { Task { await start() } }
            } else if usesLive {
                controlButton(live.muted ? "mic.fill" : "mic.slash.fill", label: live.muted ? "Weiter" : "Stumm") {
                    live.setMuted(!live.muted)
                }
                #if os(iOS)
                // Lautsprecher an/aus (aus = Hörmuschel, wie beim Telefonieren)
                Button { live.setSpeaker(!live.speakerOn) } label: {
                    Image(systemName: live.speakerOn ? "speaker.wave.3.fill" : "iphone.gen3")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(live.speakerOn ? theme.textOnAccent : theme.textPrimary)
                        .background(live.speakerOn ? theme.accent : theme.surface, in: Circle())
                        .overlay(Circle().strokeBorder(theme.surfaceBorder))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(live.speakerOn ? "Lautsprecher aus" : "Lautsprecher an")
                #endif
            } else {
                controlButton(current == .paused ? "mic.fill" : "pause.fill",
                              label: current == .paused ? "Weiter" : "Pause") { togglePause() }
            }
            Button(action: end) {
                Label("Beenden", systemImage: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 22).padding(.vertical, 13)
                    .foregroundStyle(theme.textOnAccent)
                    .background(theme.danger, in: Capsule())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
    }

    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: symbol)
                .font(.system(size: 15, weight: .semibold))
                .padding(.horizontal, 20).padding(.vertical, 13)
                .foregroundStyle(theme.textPrimary)
                .background(theme.surface, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.surfaceBorder))
        }
        .buttonStyle(.plain)
    }

    // MARK: Anzeige-Helfer

    private func ringLevel(_ phase: Phase) -> Double {
        if usesLive {
            if isLiveDemo { return 0.35 }
            return live.botSpeaking ? live.outLevel : (live.muted ? 0 : live.micLevel)
        }
        return phase == .listening ? dictation.level : 0
    }

    private func mood(for phase: Phase) -> MascotMood {
        if usesLive {
            if isLiveDemo { return .speaking }
            if live.taskRunning && !live.botSpeaking { return .working }
            switch live.state {
            case .live: return live.botSpeaking ? .speaking : .listening
            default: return .idle
            }
        }
        switch phase {
        case .listening: return .listening
        case .thinking: return .working
        case .speaking: return .speaking
        default: return .idle
        }
    }

    private func statusIsActive(_ phase: Phase) -> Bool {
        if usesLive { return isLiveDemo || (live.state == .live && !live.muted && !live.botSpeaking) }
        return phase == .listening
    }

    private func statusText(_ phase: Phase) -> String {
        let name = bot?.name ?? "Scoop"
        if usesLive {
            if isLiveDemo { return "\(name) spricht" }
            switch live.state {
            case .idle, .connecting: return "Einen Moment …"
            case .ended: return "Gespräch beendet"
            case .failed(let m): return m
            case .live:
                if live.muted { return "Stumm – \(name) hört nicht zu" }
                if live.botSpeaking { return "\(name) spricht" }
                if live.taskRunning { return "\(name) erledigt das gerade …" }
                return "Ich höre zu …"
            }
        }
        switch phase {
        case .starting, .live: return "Einen Moment …"
        case .listening: return "Ich höre zu …"
        case .thinking: return "\(name) denkt nach …"
        case .speaking: return "\(name) spricht"
        case .paused: return "Pausiert"
        case .failed(let message): return message
        }
    }

    private func captionText(_ phase: Phase) -> String {
        if demoPhase != nil {
            return phase == .speaking ? "Klar! Dein Termin mit Jonas ist um neun, danach geht's nach Köln-Deutz." : "Wie sieht mein Tag morgen aus?"
        }
        switch phase {
        case .listening: return dictation.transcript.isEmpty ? "Sprich einfach los." : dictation.transcript
        case .thinking: return preciseText ?? dictation.transcript
        case .speaking: return lastReply
        case .paused: return "Tippe auf „Weiter“, um wieder zu sprechen."
        default: return ""
        }
    }

    private func accessibilityHint(_ phase: Phase) -> String {
        if usesLive { return live.botSpeaking ? "Antwort unterbrechen" : "Maskottchen" }
        switch phase {
        case .speaking: return "Antwort unterbrechen"
        case .listening: return "Jetzt senden"
        default: return "Maskottchen"
        }
    }

    /// Erste Bot-Antwort nach der gesendeten Sprachnachricht, die noch nicht vorgelesen wurde (Gerätestimme).
    private var replyToSpeak: Message? {
        guard let sentMessageID, let list = store.messages[chatID],
              let idx = list.firstIndex(where: { $0.id == sentMessageID }) else { return nil }
        return list[(idx + 1)...].first { $0.role == .bot && !spokenIDs.contains($0.id) }
    }

    // MARK: Ablauf

    /// Live, wenn gewählt und verfügbar; sonst Gerätestimme.
    private func start() async {
        let choice = VoiceChoice(bot?.voice)
        guard choice.usesLive, !ChatGroup.isGroupID(chatID) else {
            listen()
            return
        }
        let info = await store.loadLiveVoice(refresh: true, chatID: chatID)
        guard info.available, let request = await store.liveVoiceRequest(chatID: chatID) else {
            fallbackNote = (info.reason ?? "Live ist nicht verfügbar.") + " Ich nutze die Gerätestimme."
            listen()
            return
        }
        dictation.stop()
        speaker.stop()
        fallbackNote = nil
        phase = .live
        await live.start(request: request)
    }

    private func listen() {
        guard demoPhase == nil, phase != .paused else { return }
        preciseText = nil
        phase = .starting
        Task {
            if let error = await dictation.start(continuous: false) {
                phase = .failed(error)
            } else {
                phase = .listening
            }
        }
    }

    private func send(_ text: String) async {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { listen(); return }
        phase = .thinking
        // Genaue Erkennung auf dem Server (höchstens 6 s), sonst der Text vom Gerät
        if let recording = dictation.lastRecording, let precise = await store.transcribe(recording, timeout: 6) {
            t = precise
            preciseText = precise
        }
        if let m = await store.send(t, to: chatID, voice: true) {
            sentMessageID = m.id
        } else {
            phase = .failed("Senden hat nicht geklappt.")
        }
    }

    /// Antippen: beim Sprechen unterbrechen, beim Zuhören sofort senden (Gerätestimme).
    private func tapMascot() {
        if usesLive {
            if live.botSpeaking { live.interrupt() }
            return
        }
        switch phase {
        case .speaking:
            speaker.stop()
            listen()
        case .listening where !dictation.transcript.isEmpty:
            let text = dictation.transcript
            dictation.stop()
            Task { await send(text) }
        case .failed:
            listen()
        default:
            break
        }
    }

    private func togglePause() {
        if phase == .paused {
            phase = .starting
            listen()
        } else {
            dictation.stop()
            speaker.stop()
            phase = .paused
        }
    }

    private func end() {
        live.stop()
        dictation.stop()
        speaker.stop()
        store.voiceChatID = nil
        dismiss()
    }
}
