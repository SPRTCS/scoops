import SwiftUI

/// Schritt 5: erste Nachricht an den neuen Scoop. Vorgeschlagene Startnachrichten, echter Verlauf (gleiche Zeilen
/// wie im Chat), die erste Antwort wird gefeiert.
struct OnboardingMessageStep: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var text = ""
    @State private var sending = false
    @FocusState private var focused: Bool

    private var bot: Bot? { store.onboarding.firstBotID.flatMap { store.bot($0) } }

    var body: some View {
        Group {
            if let bot {
                chat(bot)
            } else {
                missingBot
            }
        }
    }

    private func chat(_ bot: Bot) -> some View {
        let messages = (store.messages[bot.id] ?? []).filter { [.user, .bot, .status].contains($0.role) }
        let reply = OnboardingLogic.firstReply(in: messages)
        let hasSent = messages.contains { $0.role == .user }
        return VStack(spacing: 0) {
            header(bot)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(messages) { message in
                            MessageRow(message: message, chatID: bot.id, speaker: bot.speaker,
                                       run: message.isRunning ? .current : .finished)
                                .id(message.id)
                        }
                        if store.isTyping(bot.id), !messages.contains(where: { $0.role == .status && $0.isRunning }) {
                            TypingBubble(bot: bot)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id) { _, _ in
                    withAnimation(.smooth) { proxy.scrollTo("end", anchor: .bottom) }
                }
                .onChange(of: messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .top) {
                if reply != nil { ConfettiBurst().allowsHitTesting(false) }
            }
            bottom(bot, purpose: purpose(for: bot), hasSent: hasSent, replied: reply != nil)
        }
        .task(id: bot.id) {
            await store.loadLatestMessages(chatID: bot.id)
            if store.onboarding.demoReply, !hasSent {
                // `-onboarding message:reply`: erste Nachricht automatisch senden (Screenshots)
                store.onboarding.demoReply = false
                await send(purpose(for: bot).starters[0], to: bot)
            }
        }
        .onChange(of: reply?.id) { _, id in
            if id != nil, !store.onboarding.celebrated { store.onboarding.celebrated = true }
        }
        #if os(iOS)
        .sensoryFeedback(.success, trigger: reply?.id) { old, new in old == nil && new != nil }
        #endif
    }

    private func purpose(for bot: Bot) -> OnboardingPurpose {
        OnboardingPurpose.all.first { $0.label != nil && $0.label == bot.label } ?? OnboardingPurpose.find("frei")!
    }

    private func header(_ bot: Bot) -> some View {
        HStack(spacing: 14) {
            MascotView(mascot: bot.mascot, size: 52, mood: store.isBusy(bot.id) ? .working : .idle, seed: bot.id)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Sag Hallo zu \(bot.name)")
                    .font(.system(.title3, design: .rounded, weight: .bold))
                    .foregroundStyle(theme.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Schreib deine erste Nachricht oder tippe auf einen Vorschlag.")
                    .font(.subheadline)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .bottom) { Divider().overlay(theme.surfaceBorder) }
    }

    @ViewBuilder
    private func bottom(_ bot: Bot, purpose: OnboardingPurpose, hasSent: Bool, replied: Bool) -> some View {
        VStack(spacing: 12) {
            if replied {
                celebration(bot)
            } else {
                if !hasSent {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Vorschläge")
                            .font(.system(.footnote, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                        ForEach(purpose.starters, id: \.self) { starter in
                            Button { Task { await send(starter, to: bot) } } label: {
                                HStack {
                                    Text(starter)
                                        .font(.subheadline)
                                        .foregroundStyle(theme.textPrimary)
                                        .multilineTextAlignment(.leading)
                                    Spacer(minLength: 8)
                                    Image(systemName: "arrow.up.circle.fill")
                                        .foregroundStyle(theme.accent)
                                        .accessibilityHidden(true)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.surfaceBorder))
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .disabled(sending)
                            .accessibilityHint("Als Nachricht senden")
                        }
                    }
                } else {
                    Label("\(bot.name) denkt nach …", systemImage: "sparkles")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .frame(maxWidth: .infinity)
                }
                composer(bot)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 16)
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .background(theme.background)
    }

    private func composer(_ bot: Bot) -> some View {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .bottom, spacing: 10) {
            TextField("Nachricht an \(bot.name)", text: $text, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .font(.body)
                .foregroundStyle(theme.textPrimary)
                .focused($focused)
                .onSubmit { Task { await send(text, to: bot) } }
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.surfaceBorder))
            Button { Task { await send(text, to: bot) } } label: {
                Image(systemName: "arrow.up")
                    .font(.system(.body, weight: .bold))
                    .foregroundStyle(trimmed.isEmpty ? theme.textTertiary : theme.sendButtonIcon)
                    .frame(width: 44, height: 44)
                    .background(trimmed.isEmpty ? theme.sendButtonDisabled : theme.sendButton, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(trimmed.isEmpty || sending)
            .accessibilityLabel("Senden")
            .keyboardShortcut(.defaultAction)
        }
    }

    private func celebration(_ bot: Bot) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Text("🎉").font(.largeTitle).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Deine erste Antwort!")
                        .font(.system(.headline, design: .rounded))
                        .foregroundStyle(theme.textPrimary)
                    Text("\(bot.name) ist startklar. Schreib ihm einfach, wann immer du etwas brauchst.")
                        .font(.subheadline)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .themedCard(theme, radius: 20)
            .accessibilityElement(children: .combine)
            Button("Weiter") { store.onboarding.advance() }
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func send(_ message: String, to bot: Bot) async {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !sending else { return }
        sending = true
        text = ""
        focused = false
        await store.send(trimmed, to: bot.id)
        sending = false
    }

    /// Scoop fehlt (gelöscht oder anderer Server): zurück zum Gestalten
    private var missingBot: some View {
        OnboardingPage {
            WelcomeCrew(scale: 0.7).padding(.top, 40)
            OnboardingTitle(title: "Dein Scoop ist nicht mehr da", text: "Vielleicht wurde er gelöscht. Gestalte einfach einen neuen.")
        } actions: {
            Button("Neuen Scoop gestalten") {
                store.onboarding.firstBotID = nil
                store.onboarding.go(to: .scoop)
            }
            .buttonStyle(OnboardingButtonStyle())
        }
    }
}

/// Kleines Konfetti, einmal beim Erscheinen (ohne Bewegung bei „Bewegung reduzieren“)
struct ConfettiBurst: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var start = Date()

    private static let colors: [Color] = ["#FF5FA8", "#FFC83D", "#22BFAE", "#3D84F5", "#8B5CF6", "#FF8A3D"].map { Color(hex: $0) }

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSince(start)
                Canvas { ctx, size in
                    guard t < 2.6 else { return }
                    var rng = SeededRandom(string: "confetti")
                    for i in 0..<46 {
                        let x0 = size.width * (0.15 + 0.7 * rng.unit())
                        let vx = (rng.unit() - 0.5) * 220
                        let vy = -180 - rng.unit() * 160
                        let spin = (rng.unit() - 0.5) * 12
                        let x = x0 + vx * t
                        let y = size.height * 0.7 + vy * t + 260 * t * t
                        let alpha = max(0, 1 - t / 2.6)
                        var piece = ctx
                        piece.opacity = alpha
                        piece.translateBy(x: x, y: y)
                        piece.rotate(by: .radians(spin * t))
                        let rect = CGRect(x: -4, y: -2.5, width: 8, height: 5)
                        piece.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(Self.colors[i % Self.colors.count]))
                    }
                }
            }
            .frame(height: 320)
            .accessibilityHidden(true)
        }
    }
}
