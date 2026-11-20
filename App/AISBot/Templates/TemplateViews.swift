import SwiftUI

// MARK: - Bausteine der Vorlagen-Vorschauen (Export und Import)

/// Figur einer Vorlage: Bild (falls gewählt) oder Maskottchen.
struct TemplateFigure: View {
    var appearance: ScoopTemplate.Appearance?
    var showsPhoto: Bool
    var size: CGFloat = 96

    var body: some View {
        if showsPhoto, let data = appearance?.photoData, let cg = ScoopPhotoCoding.image(from: data) {
            Image(decorative: cg, scale: 1)
                .resizable()
                .scaledToFill()
                .frame(width: size * 0.86, height: size * 0.86)
                .clipShape(Circle())
                .frame(width: size, height: size)
        } else {
            MascotView(mascot: appearance?.mascot ?? .default, size: size, seed: "vorlage", animated: false, showsGround: true)
        }
    }
}

/// Zeile mit Schalter „kommt in die Datei“ bzw. „wird angelegt“, darunter der vollständige Text.
/// Lange Texte sind (nur beim Export) eingeklappt; beim Import steht immer alles da, weil es im Prompt landet.
struct TemplateItem: View {
    var icon: String
    var title: String
    var subtitle: String?
    /// Farbiger Hinweis unter dem Untertitel (z. B. „Läuft sehr oft“)
    var warning: String?
    var text: String?
    /// `nil` = kein Schalter (immer dabei)
    var isOn: Binding<Bool>?
    var collapsible = false
    @Environment(\.theme) private var theme
    @State private var expanded = false

    private var included: Bool { isOn?.wrappedValue ?? true }
    private var long: Bool { (text?.count ?? 0) > 320 || (text?.filter { $0 == "\n" }.count ?? 0) > 6 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: icon)
                    .appFont(15, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .scaledFrame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).appFont(15).foregroundStyle(theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle).appFont(12.5).foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let warning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .appFont(12.5, weight: .medium)
                            .foregroundStyle(theme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                if let isOn {
                    Toggle(title, isOn: isOn)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .tint(theme.accent)
                        #if os(macOS)
                        .controlSize(.small)
                        #endif
                }
            }
            if let text, !text.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(text)
                        .appFont(13.5)
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(collapsible && long && !expanded ? 6 : nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if collapsible, long {
                        Button(expanded ? "Weniger zeigen" : "Alles zeigen") {
                            withAnimation(.snappy(duration: 0.2)) { expanded.toggle() }
                        }
                        .buttonStyle(.plain)
                        .appFont(12.5, weight: .medium)
                        .foregroundStyle(theme.accent)
                    }
                }
                .padding(10)
                .background(theme.groupedBackground.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(.leading, 34)
            }
        }
        .opacity(included ? 1 : 0.45)
        .groupedRow(vertical: 10)
        .animation(.snappy(duration: 0.15), value: included)
    }
}

/// Hinweiskasten (Warnfarbe): „Prüf die Texte auf Persönliches“ bzw. „Eine Vorlage ist fremder Inhalt“.
struct TemplateNotice: View {
    var icon: String
    var title: String
    var lines: [String]
    var tint: Color?
    @Environment(\.theme) private var theme

    var body: some View {
        let color = tint ?? theme.warning
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .appFont(17, weight: .semibold)
                .foregroundStyle(color)
                .scaledFrame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).appFont(14.5, weight: .semibold).foregroundStyle(theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(lines, id: \.self) { line in
                    Text(line).appFont(13).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.1), in: RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous)
            .strokeBorder(color.opacity(0.35), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// Fehleransicht eines Vorlagen-Blatts (keine Vorlage, neueres Format, Server nicht erreichbar …).
struct TemplateProblemView: View {
    var problem: TemplateProblem
    var retry: (() -> Void)?
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .appFont(38, weight: .medium)
                .foregroundStyle(theme.warning)
                .accessibilityHidden(true)
            Text(problem.title).appFont(18, weight: .semibold).foregroundStyle(theme.textPrimary)
            Text(problem.message)
                .appFont(14.5)
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let retry {
                Button("Erneut versuchen", action: retry)
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .padding(.top, 4)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var icon: String {
        switch problem {
        case .newerFormat: "arrow.up.circle"
        case .server: "exclamationmark.triangle"
        default: "doc.questionmark"
        }
    }
}

extension ScoopTemplate.RoutineItem {
    /// Zeitplan in Worten (vom Server berechnet), sonst der Cron-Ausdruck
    var scheduleLine: String { scheduleText.flatMap { $0.isEmpty ? nil : $0 } ?? schedule }

    /// Hinweis für Routinen, die öfter als stündlich laufen (kostet bei jedem Lauf)
    var frequencyWarning: String? {
        guard let runs = runsPerDay, runs > 24 else { return nil }
        return String(localized: "Läuft sehr oft: rund \(Int(runs.rounded()))-mal pro Tag")
    }
}

/// Abschnitt „Vorlage“ auf der Profilseite „Verwalten“: öffnet die Export-Vorschau.
struct TemplateExportSection: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        GroupedSection(footer: "Gibt Aussehen, Rolle, Anweisungen, Fähigkeiten und Routinen als Datei weiter, damit andere \(bot.name) bei sich anlegen können. Gedächtnis, Verlauf und Konten bleiben bei dir.") {
            Button { store.exportTemplate(bot.id) } label: {
                GroupedLabelRow(icon: "square.and.arrow.up", title: "Als Vorlage exportieren") { DisclosureChevron() }
            }
            .buttonStyle(.plain)
            .accessibilityHint("Zeigt vorher genau, was in der Datei landet")
        }
    }
}
