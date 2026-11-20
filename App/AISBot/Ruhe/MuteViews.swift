import SwiftUI

// MARK: - Stummschalten (App 1.3, docs/ruhe.md)

/// Einträge „Stummschalten“ bzw. „Stummschaltung aufheben“ für Kontextmenüs (Seitenleiste, angeheftete Scoops,
/// „Mit mir geteilt“). Fehlt bei Servern, die noch nicht stummschalten können.
struct MuteMenu: View {
    let chatID: String
    /// Ausdrücklich übergeben: Kontextmenüs erben die Umgebung nicht zuverlässig
    let store: AppStore

    var body: some View {
        if store.canMute(chatID) {
            if store.isMuted(chatID) {
                Button { Task { await store.setMute(chatID, nil) } } label: {
                    Label("Stummschaltung aufheben", systemImage: "bell")
                }
            } else {
                Menu {
                    // Kurzer Hinweis als Überschrift des Untermenüs
                    Section("Freigaben kommen trotzdem durch") {
                        ForEach(MutePreset.allCases) { preset in
                            Button(preset.title) { Task { await store.setMute(chatID, preset) } }
                        }
                    }
                } label: {
                    Label("Stummschalten", systemImage: "bell.slash")
                }
            }
        }
    }
}

/// Kleines durchgestrichenes Glockensymbol neben dem Namen eines stummen Chats.
struct MutedBadge: View {
    var size: CGFloat = 11
    @Environment(\.theme) private var theme

    var body: some View {
        Image(systemName: "bell.slash.fill")
            .appFont(size)
            .foregroundStyle(theme.textTertiary)
            .accessibilityLabel("stumm")
    }
}

/// Abschnitt „Mitteilungen“ im Profil eines Scoops bzw. einer Gruppe: Stand und Stummschalten.
struct MuteProfileSection: View {
    let chatID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    private var muted: Bool { store.isMuted(chatID) }

    private var footer: String {
        store.isGuestChat(chatID)
            ? String(localized: "Freigabe-Anfragen und Erinnerungen kommen trotzdem durch, damit nichts hängen bleibt. Gilt nur für dich, nicht für andere im Chat.")
            : String(localized: "Freigabe-Anfragen und Erinnerungen kommen trotzdem durch, damit nichts hängen bleibt.")
    }

    var body: some View {
        if store.canMute(chatID) {
            GroupedSection(String(localized: "Mitteilungen"), footer: footer) {
                // Große Schrift: Menü unter dem Stand statt daneben (schmale Profilspalte)
                AdaptiveRow(spacing: 12, trailingIndent: 34) {
                    HStack(spacing: 12) {
                        Image(systemName: muted ? "bell.slash" : "bell")
                            .appFont(15, weight: .medium)
                            .foregroundStyle(theme.textSecondary)
                            .scaledFrame(width: 22)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(muted ? "Stummgeschaltet" : "Mitteilungen an")
                                .appFont(15)
                                .foregroundStyle(theme.textPrimary)
                            if let summary = store.muteSummary(chatID) {
                                Text(summary).appFont(12.5).foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                } trailing: {
                    Menu {
                        if muted {
                            Button { Task { await store.setMute(chatID, nil) } } label: {
                                Label("Stummschaltung aufheben", systemImage: "bell")
                            }
                        }
                        Section(muted ? "Neu stummschalten" : "Stummschalten") {
                            ForEach(MutePreset.allCases) { preset in
                                Button(preset.title) { Task { await store.setMute(chatID, preset) } }
                            }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(muted ? "Ändern" : "Stummschalten")
                            Image(systemName: "chevron.up.chevron.down").appFont(10, weight: .semibold)
                        }
                        .appFont(14.5)
                        .foregroundStyle(theme.textSecondary)
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(muted ? "Stummschaltung ändern" : "Stummschalten")
                }
                .groupedRow(vertical: 8)
            }
        }
    }
}

extension AppStore {
    /// Stand der Stummschaltung in Worten für das Profil: „Bis morgen 07:00“ bzw. „Dauerhaft“
    func muteSummary(_ chatID: String?) -> String? {
        guard let mute = mute(of: chatID), mute.isActive() else { return nil }
        guard let until = mute.until else { return String(localized: "Dauerhaft, bis du es aufhebst") }
        let time = Formatting.time(until)
        let calendar = Calendar.current
        if calendar.isDateInToday(until) { return String(localized: "Bis \(time) Uhr", comment: "Stummschaltung endet heute") }
        if calendar.isDateInTomorrow(until) { return String(localized: "Bis morgen \(time) Uhr") }
        let day = until.formatted(.dateTime.day().month(.wide).locale(.app))
        return String(localized: "Bis \(day), \(time) Uhr", comment: "Stummschaltung endet an einem Datum, z. B. „Bis 9. Dezember, 10:05 Uhr“")
    }
}
