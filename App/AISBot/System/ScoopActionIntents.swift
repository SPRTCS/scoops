import AppIntents
import Foundation

// MARK: - Kurzbefehle, die ohne Öffnen der App arbeiten (docs/system.md)
//
// „Scoop fragen“, „Nachricht an Scoop senden“ und „Aufgabe anlegen“ laufen im Hintergrund. Läuft die App,
// nehmen sie deren Verbindung; sonst sprechen sie selbst mit dem Server des gewählten Scoops (`SystemAccess`).
// Sie verlangen ein entsperrtes Gerät, weil sie in private Chats schreiben und daraus vorlesen.

/// Fehler mit einem Satz, den Siri und Kurzbefehle anzeigen bzw. vorlesen.
nonisolated struct ScoopIntentError: Error, CustomLocalizedStringResourceConvertible {
    var message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }

    init(_ message: String) { self.message = message }
    init(_ error: Error) { message = SystemError.from(error).message }
}

/// Ergebnis von „Scoop fragen“
nonisolated enum ScoopAnswer: Sendable {
    case answer(String)
    /// Der Scoop wartet auf eine Freigabe in der App
    case needsApproval(String)
    /// Zeitlimit erreicht, der Scoop arbeitet noch
    case stillWorking
}

nonisolated enum ScoopConversation {
    /// Sendet die Frage und wartet bis zu `timeout` Sekunden auf die Antwort des Scoops.
    static func ask(_ chat: SystemChat, text: String, timeout: TimeInterval) async throws -> ScoopAnswer {
        let service = try await SystemAccess.service(for: chat)
        let sent = try await service.send(chatID: chat.id, text: text, fileIDs: [])
        SystemDirectory.noteUsed(chatID: chat.id)
        let deadline = Date().addingTimeInterval(timeout)
        var answerSeenAt: Date?
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(1200))
            // Ein einzelner Fehler beim Nachfragen ist kein Abbruch: Die Frage ist schon angekommen
            guard let recent = try? await service.recentMessages(chatID: chat.id, limit: 20) else { continue }
            let after: [Message]
            if let index = recent.firstIndex(where: { $0.id == sent.id }) {
                after = Array(recent[(index + 1)...])
            } else {
                after = recent.filter { $0.createdAt >= sent.createdAt && $0.role != .user }
            }
            if let approval = after.last(where: \.isPendingApproval) {
                return .needsApproval(approval.meta.title ?? approval.text)
            }
            guard let reply = after.last(where: { $0.role == .bot && !$0.text.isEmpty }) else { continue }
            // Antwort ist da. Läuft der Lauf noch (weitere Schritte), kurz auf die endgültige Antwort warten.
            let running = after.contains(where: \.isRunning)
            if !running || Date().timeIntervalSince(answerSeenAt ?? Date()) > 4 {
                return .answer(MarkdownText.plain(reply.text))
            }
            if answerSeenAt == nil { answerSeenAt = Date() }
        }
        return .stillWorking
    }
}

/// „Scoop fragen“: Frage senden, auf die Antwort warten und sie als Text zurückgeben.
struct AskScoopIntent: AppIntent {
    static let title: LocalizedStringResource = "Scoop fragen"
    static let description = IntentDescription(
        "Stellt einem Scoop eine Frage und gibt seine Antwort als Text zurück. Braucht der Scoop länger als die Wartezeit oder eine Freigabe, steht stattdessen ein Hinweis im Ergebnis; die Antwort kommt dann im Chat.",
        categoryName: "Scoops", resultValueName: "Antwort")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Scoop", optionsProvider: WritableChatOptions())
    var scoop: ChatEntity

    @Parameter(title: "Frage", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "Was möchtest du fragen?")
    var text: String

    @Parameter(title: "Wartezeit", description: "So lange wartet der Kurzbefehl höchstens auf die Antwort (Sekunden). Siri wartet höchstens rund 30 Sekunden.",
               default: 25, inclusiveRange: (5, 120))
    var timeout: Int

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$scoop) fragen: \(\.$text)") {
            \.$timeout
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let question = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw ScoopIntentError(String(localized: "Die Frage ist leer.")) }
        do {
            let chat = try SystemAccess.chat(scoop.id)
            guard chat.canWrite else { throw ScoopIntentError(String(localized: "Bei \(chat.name) darfst du nur mitlesen.")) }
            switch try await ScoopConversation.ask(chat, text: question, timeout: TimeInterval(timeout)) {
            case .answer(let answer):
                return .result(value: answer, dialog: IntentDialog(stringLiteral: answer))
            case .needsApproval(let title):
                let hint = String(localized: "\(chat.name) braucht deine Freigabe: \(title). Öffne AIS Scoops, um sie zu erteilen.")
                return .result(value: hint, dialog: IntentDialog(stringLiteral: hint))
            case .stillWorking:
                let hint = String(localized: "\(chat.name) arbeitet noch daran. Die Antwort findest du gleich im Chat.")
                return .result(value: hint, dialog: IntentDialog(stringLiteral: hint))
            }
        } catch let error as ScoopIntentError {
            throw error
        } catch {
            throw ScoopIntentError(error)
        }
    }
}

/// „Nachricht an Scoop senden“: senden, ohne auf die Antwort zu warten.
struct SendScoopMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Nachricht an Scoop senden"
    static let description = IntentDescription(
        "Sendet eine Nachricht an einen Scoop oder eine Gruppe, ohne auf die Antwort zu warten. Ist der Server nicht erreichbar, sendet AIS Scoops sie beim nächsten Öffnen.",
        categoryName: "Scoops")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Chat", description: "Scoop oder Gruppe", optionsProvider: WritableChatOptions())
    var chat: ChatEntity

    @Parameter(title: "Nachricht", inputOptions: String.IntentInputOptions(multiline: true),
               requestValueDialog: "Was möchtest du schreiben?")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$text) an \(\.$chat) senden")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { throw ScoopIntentError(String(localized: "Die Nachricht ist leer.")) }
        let target: SystemChat
        do { target = try SystemAccess.chat(chat.id) } catch { throw ScoopIntentError(error) }
        guard target.canWrite else { throw ScoopIntentError(String(localized: "Bei \(target.name) darfst du nur mitlesen.")) }
        let directory = SystemDirectory.current()
        do {
            let service = try await SystemAccess.service(for: target, directory: directory)
            _ = try await service.send(chatID: target.id, text: message, fileIDs: [])
            SystemDirectory.noteUsed(chatID: target.id)
            return .result(dialog: "Gesendet an \(target.name).")
        } catch {
            let failure = SystemError.from(error)
            // Nicht erreichbar: ablegen, die App sendet beim nächsten Öffnen nach
            guard failure.isTransient, var item = ShareOutbox.begin() else { throw ScoopIntentError(failure) }
            item.chatID = target.id
            item.serverID = target.serverID
            item.chatName = target.name
            item.text = message
            item.state = .queued
            item.lastError = failure.message
            item.demo = directory.demo
            ShareOutbox.save(item)
            return .result(dialog: "Der Server ist gerade nicht erreichbar. AIS Scoops sendet die Nachricht an \(target.name), sobald du die App öffnest.")
        }
    }
}

/// „Aufgabe anlegen“: landet im Aufgaben-Board und startet sofort.
struct CreateScoopTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Aufgabe anlegen"
    static let description = IntentDescription(
        "Legt eine Aufgabe für einen deiner Scoops an. Sie erscheint im Aufgaben-Board und der Scoop beginnt sofort.",
        categoryName: "Scoops", resultValueName: "Titel der Aufgabe")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Scoop", optionsProvider: OwnScoopOptions())
    var scoop: ChatEntity

    @Parameter(title: "Titel", requestValueDialog: "Wie heißt die Aufgabe?")
    var taskTitle: String

    @Parameter(title: "Beschreibung", description: "Was genau zu tun ist. Ohne Beschreibung gilt der Titel als Auftrag.",
               inputOptions: String.IntentInputOptions(multiline: true))
    var details: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Aufgabe \(\.$taskTitle) für \(\.$scoop) anlegen") {
            \.$details
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let title = taskTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw ScoopIntentError(String(localized: "Der Titel ist leer.")) }
        let description = details?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            let chat = try SystemAccess.chat(scoop.id)
            guard !chat.shared else { throw ScoopIntentError(String(localized: "Aufgaben gehen nur bei deinen eigenen Scoops.")) }
            guard !chat.isGroup else { throw ScoopIntentError(String(localized: "Aufgaben für eine Gruppe legst du in AIS Scoops an. Wähle hier einen einzelnen Scoop.")) }
            let service = try await SystemAccess.service(for: chat)
            let task = try await service.createTask(chatID: chat.id, actorID: nil, title: title,
                                                    prompt: description.isEmpty ? title : description)
            SystemDirectory.noteUsed(chatID: chat.id)
            return .result(value: task.title, dialog: "Aufgabe „\(task.title)“ für \(chat.name) angelegt.")
        } catch let error as ScoopIntentError {
            throw error
        } catch {
            throw ScoopIntentError(error)
        }
    }
}

// MARK: - Kurzbefehle für Siri, Spotlight und die Kurzbefehle-App

nonisolated struct ScoopShortcuts: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .yellow

    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AskScoopIntent(),
                    phrases: ["Frag \(\.$scoop) in \(.applicationName)",
                              "Frage \(\.$scoop) in \(.applicationName)",
                              "Frag einen Scoop in \(.applicationName)",
                              "Scoop fragen mit \(.applicationName)"],
                    shortTitle: "Scoop fragen", systemImageName: "questionmark.bubble.fill")
        AppShortcut(intent: SendScoopMessageIntent(),
                    phrases: ["Schreib \(\.$chat) in \(.applicationName)",
                              "Sende eine Nachricht an \(\.$chat) in \(.applicationName)",
                              "Nachricht senden mit \(.applicationName)"],
                    shortTitle: "Nachricht senden", systemImageName: "paperplane.fill")
        AppShortcut(intent: CreateScoopTaskIntent(),
                    phrases: ["Leg eine Aufgabe für \(\.$scoop) in \(.applicationName) an",
                              "Neue Aufgabe für \(\.$scoop) in \(.applicationName)",
                              "Aufgabe anlegen in \(.applicationName)"],
                    shortTitle: "Aufgabe anlegen", systemImageName: "checklist")
        AppShortcut(intent: StartVoiceModeIntent(),
                    phrases: ["Sprich mit \(\.$scoop) in \(.applicationName)",
                              "Starte den Sprechmodus mit \(\.$scoop) in \(.applicationName)",
                              "Starte den Sprechmodus in \(.applicationName)",
                              "\(.applicationName) Sprechmodus"],
                    shortTitle: "Sprechmodus", systemImageName: "waveform")
        AppShortcut(intent: OpenChatIntent(),
                    phrases: ["Öffne \(\.$chat) in \(.applicationName)",
                              "Öffne den Chat mit \(\.$chat) in \(.applicationName)",
                              "Öffne einen Chat in \(.applicationName)"],
                    shortTitle: "Chat öffnen", systemImageName: "bubble.left.fill")
    }
}
