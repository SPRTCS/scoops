import SwiftUI

/// Modus des Eingabefelds (wie die Werkzeug-/Skill-Wahl in ChatGPT oder Codex): Aus dem Plus-Menü gewählt, steht
/// er als farbiger Chip mit Symbol vor dem Text. Beim Senden wird daraus ein klarer Auftrag an den Scoop
/// (z. B. „Leg eine Routine an: …“, „/aufgabe …“). Der Verlauf zeigt denselben Chip wieder (`parse`).
enum ComposerMode: String, CaseIterable, Identifiable {
    case task, routine, reminder, memory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .task: "Aufgabe"
        case .routine: "Routine"
        case .reminder: "Erinnerung"
        case .memory: "Gedächtnis"
        }
    }

    /// Eintrag im Plus-Menü
    var menuTitle: String {
        switch self {
        case .task: "Aufgabe starten"
        case .routine: "Routine anlegen"
        case .reminder: "Erinnerung"
        case .memory: "Was weißt du über mich?"
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
        case .task: "Was soll im Hintergrund erledigt werden?"
        case .routine: "Was soll wann regelmäßig passieren?"
        case .reminder: "Woran und wann soll ich dich erinnern?"
        case .memory: "Frag nach, was ich über dich weiß, oder sag mir etwas"
        }
    }

    /// Auch ohne Text sendbar (fragt dann nach dem Gedächtnis)
    var sendsEmpty: Bool { self == .memory }

    /// Text, der an den Server geht.
    func compose(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .task: return "/aufgabe \(t)"
        case .routine: return "Leg eine Routine an: \(t)"
        case .reminder: return "Erinnere mich: \(t)"
        case .memory: return t.isEmpty ? "Was weißt du über mich?" : "Zu deinem Gedächtnis über mich: \(t)"
        }
    }

    /// Gesendete Nachricht → Modus und Resttext (für den Chip im Verlauf). Alte Vorlagen-Texte werden mit erkannt.
    static func parse(_ text: String) -> (mode: ComposerMode, rest: String)? {
        let pairs: [(String, ComposerMode)] = [
            ("/aufgabe ", .task), ("Leg eine Routine an: ", .routine), ("Erinnere mich: ", .reminder),
            ("Zu deinem Gedächtnis über mich: ", .memory),
        ]
        for (prefix, mode) in pairs where text.hasPrefix(prefix) {
            return (mode, String(text.dropFirst(prefix.count)))
        }
        if text == "Was weißt du über mich?" { return (.memory, "") }
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
                .font(.system(size: compact ? 11 : 13, weight: .bold))
            Text(mode.title)
                .font(.system(size: compact ? 13 : 15, weight: .bold))
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .heavy))
                        .frame(width: 16, height: 16)
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
