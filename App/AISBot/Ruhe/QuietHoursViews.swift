import SwiftUI

// MARK: - Ruhezeiten (App 1.3, docs/ruhe.md)

/// Abschnitt „Mitteilungen“ in den Einstellungen: führt zu den Ruhezeiten.
struct NotificationSettingsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    /// `-quiethours` öffnet das Blatt direkt (Screenshots)
    @State private var showQuiet = ProcessInfo.processInfo.arguments.contains("-quiethours")

    private var available: Bool { store.quietHoursAvailable }

    private var subtitle: String {
        guard available else { return String(localized: "Server aktualisieren, dann hier einstellbar") }
        return store.ruhe.quietHours?.summary ?? String(localized: "Aus", comment: "Ruhezeiten ausgeschaltet")
    }

    var body: some View {
        GroupedSection("Mitteilungen",
                       footer: "In der Ruhezeit kommen Mitteilungen still an. Einzelne Chats schaltest du in der Seitenleiste stumm: gedrückt halten oder Rechtsklick.") {
            Button { showQuiet = true } label: {
                GroupedLabelRow(icon: "moon", iconColor: available ? theme.accent : theme.textTertiary, title: String(localized: "Ruhezeiten"),
                                subtitle: subtitle, titleColor: available ? nil : theme.textSecondary) {
                    if available { DisclosureChevron() }
                }
            }
            .buttonStyle(.plain)
            .disabled(!available)
            .accessibilityHint(available ? "Öffnet die Einstellungen der Ruhezeit" : "Braucht einen neueren Server")
        }
        .task { await store.loadQuietHours() }
        .sheet(isPresented: $showQuiet) {
            QuietHoursSheet().environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
        }
    }
}

/// Blatt „Ruhezeiten“: an/aus, Von und Bis, Wochentage, „Freigaben trotzdem melden“. Speichert jede Änderung sofort.
struct QuietHoursSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var draft = QuietHours.standard
    @State private var loaded = false
    @State private var error: String?
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Ruhezeiten", icon: "moon") { dismiss() }
            ScrollView {
                content
                    .padding(.horizontal, 20)
                    .padding(.top, 6)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity)
            }
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 480, height: 640)
        #endif
        .task {
            await store.loadQuietHours()
            draft = store.ruhe.quietHours ?? .standard
            loaded = true
        }
        .onChange(of: draft) { _, value in
            guard loaded, value != store.ruhe.quietHours else { return }
            // Kurz warten: Die Zeitwähler melden beim Drehen viele Zwischenwerte
            saveTask?.cancel()
            saveTask = Task {
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                error = await store.saveQuietHours(value)
            }
        }
    }

    private var content: some View {
        GroupedStack {
            GroupedSection(footer: "In der Ruhezeit kommen Mitteilungen still an: ohne Ton und Banner. Du findest sie in der Mitteilungszentrale.") {
                GroupedLabelRow(icon: "moon", iconColor: theme.accent, title: String(localized: "Ruhezeit"),
                                subtitle: draft.enabled ? (draft.contains() ? String(localized: "Gerade aktiv") : String(localized: "Gerade nicht aktiv")) : nil) {
                    Toggle("Ruhezeit", isOn: $draft.enabled.animation(.snappy(duration: 0.2)))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(theme.accent)
                }
            }
            if draft.enabled {
                GroupedSection("Zeitraum", footer: "Gilt an den gewählten Tagen ab der Von-Zeit, auch über Mitternacht. Zeitzone dieses Geräts: \(zoneName).") {
                    timeRow("Von", minutes: Binding(get: { QuietHours.minutes(draft.start) ?? 22 * 60 },
                                                    set: { draft.start = QuietHours.hhmm($0) }))
                    timeRow("Bis", minutes: Binding(get: { QuietHours.minutes(draft.end) ?? 7 * 60 },
                                                    set: { draft.end = QuietHours.hhmm($0) }))
                    weekdayRow
                }
                GroupedSection("Ausnahmen",
                               footer: "Wartet ein Scoop auf deine Freigabe, meldet er sich wie gewohnt, sonst bliebe er unbemerkt hängen. Erinnerungen, die du auf eine Uhrzeit gelegt hast, melden sich immer.") {
                    GroupedLabelRow(icon: "checkmark.seal", title: "Freigaben trotzdem melden") {
                        Toggle("Freigaben trotzdem melden", isOn: $draft.approvals)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .tint(theme.accent)
                    }
                }
                if let primary = store.primaryBot {
                    GroupedSection {
                        GroupedLabelRow(icon: "crown", title: "\(primary.name) wartet",
                                        subtitle: "Der Haupt-Scoop meldet sich in der Ruhezeit nicht von selbst. Fällt ein Check hinein, holt er ihn danach einmal nach.")
                    }
                }
                if !store.sharedBots.isEmpty {
                    GroupedSection {
                        GroupedLabelRow(icon: "person.2", title: "Auch für geteilte Scoops",
                                        subtitle: "Die Ruhezeit gilt auch für Scoops, die andere mit dir teilen.")
                    }
                }
            }
            if let error {
                Text(error).appFont(12.5).foregroundStyle(theme.danger)
                    .padding(.horizontal, GroupedMetrics.rowInset)
            }
        }
    }

    private var zoneName: String {
        let zone = TimeZone.current
        return zone.localizedName(for: .generic, locale: AppLanguage.isGerman ? Locale(identifier: "de_DE") : .app) ?? zone.identifier
    }

    private func timeRow(_ title: LocalizedStringKey, minutes: Binding<Int>) -> some View {
        let date = Binding<Date>(
            get: { Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60,
                                         second: 0, of: Date()) ?? Date() },
            set: { value in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: value)
                minutes.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
        return HStack(spacing: 12) {
            Text(title).appFont(15).foregroundStyle(theme.textPrimary)
            Spacer()
            DatePicker(title, selection: date, displayedComponents: .hourAndMinute)
                .labelsHidden()
                .environment(\.locale, AppLanguage.isGerman ? Locale(identifier: "de_DE") : .app)
        }
        .groupedRow(vertical: 6)
    }

    private var weekdayRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Wochentage").appFont(15).foregroundStyle(theme.textPrimary)
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { day in
                    let on = draft.days.contains(day)
                    Button {
                        if on { draft.days.removeAll { $0 == day } } else { draft.days = (draft.days + [day]).sorted() }
                    } label: {
                        Text(QuietHours.dayNames[day - 1])
                            .appFont(13.5, weight: .semibold)
                            .foregroundStyle(on ? theme.textOnAccent : theme.textSecondary)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(on ? theme.accent : theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(on ? .clear : theme.surfaceBorder))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Self.dayLong[day - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
        .groupedRow(vertical: 10)
    }

    private static var dayLong: [String] {
        [String(localized: "Montag"), String(localized: "Dienstag"), String(localized: "Mittwoch"),
         String(localized: "Donnerstag"), String(localized: "Freitag"), String(localized: "Samstag"),
         String(localized: "Sonntag")]
    }
}
