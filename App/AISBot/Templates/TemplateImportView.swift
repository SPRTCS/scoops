import SwiftUI

/// „Scoop aus Vorlage“: Vorschau vor dem Anlegen. Eine Vorlage ist fremder Inhalt, darum stehen hier alle Texte, die
/// später im Prompt landen, vollständig da. Der Name ist änderbar, Routinen und Fähigkeiten einzeln abwählbar.
struct TemplateImportView: View {
    let source: TemplateSource
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var check: TemplateCheck?
    @State private var problem: TemplateProblem?
    @State private var name = ""
    @State private var skippedSkills: Set<Int> = []
    @State private var skippedRoutines: Set<Int> = []
    @State private var useModel = true
    @State private var usePhoto = true
    @State private var creating = false
    @State private var createError: String?

    private var canCreate: Bool { !creating && !name.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Scoop aus Vorlage", icon: "square.and.arrow.down") { dismiss() }
            Divider().overlay(theme.surfaceBorder)
            if let check {
                ScrollView {
                    preview(check)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                }
                Divider().overlay(theme.surfaceBorder)
                actions(check)
            } else if let problem {
                TemplateProblemView(problem: problem, retry: canRetry ? { Task { await load() } } : nil)
            } else {
                ProgressView("Vorlage wird geprüft …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 560, height: 720)
        #endif
        .task(id: source.id) { await load() }
        .interactiveDismissDisabled(creating)
    }

    /// Nur Fehler, die sich von selbst erledigen können (Server nicht erreichbar), nicht kaputte Dateien
    private var canRetry: Bool {
        if case .server = problem { return true }
        return false
    }

    private func load() async {
        problem = nil
        check = nil
        switch await store.checkTemplate(source) {
        case .success(let value):
            name = value.template.name
            skippedSkills = []
            skippedRoutines = []
            useModel = value.model?.available ?? false
            usePhoto = true
            check = value
        case .failure(let p):
            problem = p
        }
    }

    // MARK: Vorschau

    @ViewBuilder
    private func preview(_ check: TemplateCheck) -> some View {
        let t = check.template
        GroupedStack {
            VStack(spacing: 8) {
                TemplateFigure(appearance: t.appearance, showsPhoto: usePhoto, size: 104)
                if let label = t.label, !label.isEmpty {
                    Text(label).appFont(13.5).foregroundStyle(theme.textSecondary)
                }
                if let about = t.description, !about.isEmpty {
                    Text(about)
                        .appFont(14)
                        .foregroundStyle(theme.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)
                }
                if let file = source.fileName {
                    Text(file).appFont(12).foregroundStyle(theme.textTertiary).adaptiveLineLimit(1).truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity)

            GroupedSection("Name", footer: "So heißt der Scoop bei dir. Du kannst ihn später ändern.") {
                TextField("Name deines Scoops", text: $name)
                    .textFieldStyle(.plain)
                    .appFont(15)
                    .foregroundStyle(theme.textPrimary)
                    .groupedRow()
                    .accessibilityLabel("Name des Scoops")
            }

            TemplateNotice(icon: "hand.raised", title: String(localized: "Eine Vorlage ist fremder Inhalt"),
                           lines: [String(localized: "Lies die Anweisungen, bevor du den Scoop anlegst: Alles hier landet später in seinem Prompt.")]
                               + check.notes)

            GroupedSection("Charakter und Anweisungen") {
                if let character = t.character, !character.isEmpty {
                    TemplateItem(icon: "theatermasks", title: String(localized: "Das bekommt \(displayName) mit"), text: character)
                } else {
                    GroupedLabelRow(icon: "theatermasks", title: "Keine Anweisungen", titleColor: theme.textSecondary)
                }
            }

            if !t.skills.isEmpty {
                GroupedSection("Fähigkeiten", dividerInset: 50) {
                    ForEach(Array(t.skills.enumerated()), id: \.offset) { i, skill in
                        TemplateItem(icon: "wand.and.stars", title: skill.name, subtitle: skill.description, text: skill.steps,
                                     isOn: toggle($skippedSkills, i))
                    }
                }
            }

            if !t.routines.isEmpty {
                GroupedSection("Routinen",
                               footer: "Routinen werden pausiert angelegt. Du schaltest sie im Profil unter „Anstehend“ ein.",
                               dividerInset: 50) {
                    ForEach(Array(t.routines.enumerated()), id: \.offset) { i, routine in
                        TemplateItem(icon: "clock", title: routine.title, subtitle: routine.scheduleLine,
                                     warning: routine.frequencyWarning, text: routine.prompt,
                                     isOn: toggle($skippedRoutines, i))
                    }
                }
            }

            if !t.requires.isEmpty {
                GroupedSection("Benötigte Verbindungen",
                               footer: "Fehlendes richtest du später unter Einstellungen → Apps verbinden ein. Der Scoop funktioniert auch ohne, nur eingeschränkt.",
                               dividerInset: 50) {
                    ForEach(Array(t.requires.enumerated()), id: \.offset) { _, item in requirementRow(item) }
                }
            }

            modelSection(check)

            if t.appearance?.photo != nil {
                GroupedSection("Bild") {
                    TemplateItem(icon: "photo", title: String(localized: "Bild der Vorlage übernehmen"),
                                 subtitle: String(localized: "Sonst bekommt \(displayName) das Maskottchen der Vorlage."), isOn: $usePhoto)
                }
            }
        }
    }

    private var displayName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? String(localized: "der Scoop", comment: "Steht im Satz für den Namen, solange keiner eingegeben ist") : n
    }

    private func requirementRow(_ item: ScoopTemplate.Requirement) -> some View {
        let (text, symbol, color): (String, String, Color) = switch item.status {
        case "connected": (String(localized: "Verbunden", comment: "Status einer benötigten Verbindung"), "checkmark.circle.fill", theme.success)
        case "missing": (String(localized: "Fehlt noch", comment: "Status einer benötigten Verbindung"), "exclamationmark.circle.fill", theme.warning)
        default: (String(localized: "Unbekannt", comment: "Status einer benötigten Verbindung"), "questionmark.circle", theme.textTertiary)
        }
        return GroupedLabelRow(icon: item.symbol, title: item.name, subtitle: item.note) {
            Label(text, systemImage: symbol)
                .appFont(13, weight: .medium)
                .foregroundStyle(color)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(text)")
    }

    @ViewBuilder
    private func modelSection(_ check: TemplateCheck) -> some View {
        if let info = check.model, let wanted = info.id {
            let fallback = info.default.map(BotModel.displayName(for:)) ?? String(localized: "dein Standardmodell")
            if info.available {
                GroupedSection("Modell", footer: "Aus: \(displayName) nutzt \(fallback).") {
                    TemplateItem(icon: "cpu", title: String(localized: "Modell der Vorlage verwenden"), subtitle: BotModel.displayName(for: wanted),
                                 isOn: $useModel)
                }
            } else {
                GroupedSection("Modell") {
                    GroupedLabelRow(icon: "cpu", title: "Läuft mit \(fallback)",
                                    subtitle: "Die Vorlage wünscht sich \(BotModel.displayName(for: wanted)). Das ist auf deinem Server nicht eingerichtet.")
                }
            }
        }
    }

    private func toggle(_ skipped: Binding<Set<Int>>, _ index: Int) -> Binding<Bool> {
        Binding(get: { !skipped.wrappedValue.contains(index) },
                set: { on in if on { skipped.wrappedValue.remove(index) } else { skipped.wrappedValue.insert(index) } })
    }

    // MARK: Anlegen

    private func actions(_ check: TemplateCheck) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let createError {
                Text(createError).appFont(12.5).foregroundStyle(theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }
            AdaptiveButtonRow(spacing: 10, stretchWhenStacked: true) {
                Spacer(minLength: 0)
                if creating { ProgressView().controlSize(.small) }
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                    .disabled(creating)
                Button("Scoop anlegen") { create(check) }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            // Fußzeile eines Blatts: wächst bis zur größten normalen Stufe mit, bleibt so in einer Zeile
            .dynamicTypeSize(...AppFont.controlCap)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    private func create(_ check: TemplateCheck) {
        let t = check.template
        creating = true
        createError = nil
        let request = TemplateImportRequest(
            template: t, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            routines: t.routines.indices.filter { !skippedRoutines.contains($0) },
            skills: t.skills.indices.filter { !skippedSkills.contains($0) },
            useModel: useModel && (check.model?.available ?? false), usePhoto: usePhoto)
        Task {
            if let error = await store.importTemplate(request) {
                createError = error
                creating = false
            } else {
                dismiss()
            }
        }
    }
}
