import SwiftUI

/// Modus des Eingabefelds (wie die Werkzeug-/Skill-Wahl in ChatGPT oder Codex): Aus dem Plus-Menü gewählt, steht
/// er als farbiger Chip mit Symbol vor dem Text. Beim Senden wird daraus ein klarer Auftrag an den Scoop
/// (z. B. „Leg eine Routine an: …“, „/aufgabe …“). Der Verlauf zeigt denselben Chip wieder (`parse`).
enum ComposerMode: String, CaseIterable, Identifiable {
    case task, routine, reminder, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .task: String(localized: "Aufgabe", comment: "Modus des Eingabefelds")
        case .routine: String(localized: "Routine", comment: "Modus des Eingabefelds")
        case .reminder: String(localized: "Erinnerung", comment: "Modus des Eingabefelds")
        case .memory: String(localized: "Gedächtnis", comment: "Modus des Eingabefelds")
        }
    }

    /// Eintrag im Plus-Menü
    var menuTitle: String {
        switch self {
        case .task: String(localized: "Aufgabe starten")
        case .routine: String(localized: "Routine anlegen")
        case .reminder: String(localized: "Erinnerung", comment: "Modus des Eingabefelds")
        case .memory: String(localized: "Was weißt du über mich?")
        }
    }

    var icon: String {
        switch self {
        case .task: "checklist"
        case .routine: "clock.arrow.circlepath"
        case .reminder: "bell.fill"
        case .memory: "brain.head.profile.fill"
        }
    }

    /// Feste Modusfarbe (in hell und dunkel gut lesbar)
    var color: Color {
        switch self {
        case .task: Color(red: 0.20, green: 0.55, blue: 1.00)
        case .routine: Color(red: 0.62, green: 0.42, blue: 1.00)
        case .reminder: Color(red: 1.00, green: 0.58, blue: 0.18)
        case .memory: Color(red: 0.98, green: 0.36, blue: 0.62)
        }
    }

    var placeholder: String {
        switch self {
        case .task: String(localized: "Was soll im Hintergrund erledigt werden?")
        case .routine: String(localized: "Was soll wann regelmäßig passieren?")
        case .reminder: String(localized: "Woran und wann soll ich dich erinnern?")
        case .memory: String(localized: "Frag nach, was ich über dich weiß, oder sag mir etwas")
        }
    }

    /// Auch ohne Text sendbar (fragt dann nach dem Gedächtnis)
    var sendsEmpty: Bool { self == .memory }

    /// Vorspann der gesendeten Nachricht je Sprache (Deutsch, Englisch). Bewusst nicht im String Catalog: `parse`
    /// muss beide Sprachen erkennen (ältere deutsche Nachrichten auf einem englischen Gerät und umgekehrt).
    /// `/aufgabe` ist ein Befehl an den Server und bleibt in beiden Sprachen gleich.
    private static let prefixes: [(ComposerMode, de: String, en: String)] = [
        (.task, "/aufgabe ", "/aufgabe "),
        (.routine, "Leg eine Routine an: ", "Create a routine: "),  // nicht übersetzen: beide Sprachen stehen hier
        (.reminder, "Erinnere mich: ", "Remind me: "),
        (.memory, "Zu deinem Gedächtnis über mich: ", "Remember this about me: "),  // nicht übersetzen: beide Sprachen stehen hier
    ]
    /// Nachricht des Gedächtnis-Modus ohne eigenen Text (Deutsch, Englisch)
    private static let memoryQuestion = (de: "Was weißt du über mich?", en: "What do you know about me?")  // nicht übersetzen: beide Sprachen stehen hier

    /// Text, der an den Server geht (und als eigene Nachricht im Verlauf steht).
    func compose(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let german = AppLanguage.isGerman
        if self == .memory, t.isEmpty { return german ? Self.memoryQuestion.de : Self.memoryQuestion.en }
        guard let entry = Self.prefixes.first(where: { $0.0 == self }) else { return t }
        return (german ? entry.de : entry.en) + t
    }

    /// Gesendete Nachricht → Modus und Resttext (für den Chip im Verlauf). Alte Vorlagen-Texte werden mit erkannt,
    /// in beiden Sprachen.
    static func parse(_ text: String) -> (mode: ComposerMode, rest: String)? {
        for entry in prefixes {
            for prefix in [entry.de, entry.en] where text.hasPrefix(prefix) {
                return (entry.0, String(text.dropFirst(prefix.count)))
            }
        }
        if text == memoryQuestion.de || text == memoryQuestion.en { return (.memory, "") }
        return nil
    }
}

/// Farbiger Modus-Chip: Symbol und Name fett in der Modusfarbe, zarter Hintergrund. Mit `onRemove` ein kleines ✕.
struct ComposerModeChip: View {
    let mode: ComposerMode
    var compact = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: mode.icon)
                .appFont(compact ? 11 : 13, weight: .bold)
            Text(mode.title)
                .appFont(compact ? 13 : 15, weight: .bold)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .appFont(9, weight: .heavy)
                        .scaledFrame(16)
                        .background(mode.color.opacity(0.18), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Modus entfernen")
                .accessibilityLabel("Modus \(mode.title) entfernen")
            }
        }
        .foregroundStyle(mode.color)
        .padding(.leading, compact ? 7 : 8)
        .padding(.trailing, onRemove == nil ? (compact ? 8 : 10) : 4)
        .padding(.vertical, compact ? 3 : 4)
        .background(mode.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().strokeBorder(mode.color.opacity(0.28)))
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Modus: \(mode.title)")
    }
}
