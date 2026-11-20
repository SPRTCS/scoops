import SwiftUI
import UniformTypeIdentifiers

/// „Als Vorlage exportieren“: Vorschau genau dessen, was in der Datei landet, einzelne Teile abwählbar.
/// Danach teilen (Teilen-Menü) oder „Sichern unter“ (Mac) bzw. „In Dateien sichern“ (iPhone, iPad).
struct TemplateExportView: View {
    let botID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var export: TemplateExport?
    @State private var problem: TemplateProblem?
    @State private var description = ""
    @State private var includeAppearance = true
    @State private var includePhoto = false
    @State private var includeCharacter = true
    @State private var includeModel = true
    /// Abgewählte eigene Fähigkeiten, Routinen und Verbindungen (Positionen)
    @State private var skippedSkills: Set<Int> = []
    @State private var skippedRoutines: Set<Int> = []
    @State private var skippedRequires: Set<Int> = []
    /// Dazugewählte Fähigkeiten, die für alle Scoops gelten
    @State private var sharedSkills: Set<Int> = []
    @State private var fileURL: URL?
    @State private var showSave = false
    @State private var saveError: String?

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Als Vorlage exportieren", icon: "square.and.arrow.up") { dismiss() }
            Divider().overlay(theme.surfaceBorder)
            if let export {
                ScrollView {
                    preview(export)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .frame(maxWidth: 640)
                        .frame(maxWidth: .infinity)
                }
                Divider().overlay(theme.surfaceBorder)
                actions(export)
            } else if let problem {
                TemplateProblemView(problem: problem) { Task { await load() } }
            } else {
                ProgressView("Vorlage wird vorbereitet …")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 560, height: 720)
        #endif
        .task { await load() }
        .onChange(of: output) { _, _ in writeFile() }
        .fileExporter(isPresented: $showSave, document: TemplateDocument(data: (try? output?.fileData()) ?? Data()),
                      contentType: .scoopTemplate, defaultFilename: fileName) { result in
            switch result {
            case .success:
                store.showToast(String(localized: "Vorlage gesichert"))
                dismiss()
            case .failure(let error):
                saveError = error.localizedDescription
            }
        }
    }

    private func load() async {
        problem = nil
        switch await store.loadTemplateExport(botID: botID) {
        case .success(let value):
            export = value
            writeFile()
        case .failure(let p):
            problem = p
        }
    }

    // MARK: Inhalt der Datei

    /// Genau das, was in die Datei kommt (alle Schalter berücksichtigt)
    private var output: ScoopTemplate? {
        guard let export else { return nil }
        var t = export.template
        t.description = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if includeAppearance {
            t.appearance?.photo = includePhoto ? export.optional.photo : nil
        } else {
            t.appearance = nil
        }
        if !includeCharacter { t.character = nil }
        t.skills = export.template.skills.enumerated().filter { !skippedSkills.contains($0.offset) }.map(\.element)
            + export.optional.skills.enumerated().filter { sharedSkills.contains($0.offset) }.map(\.element)
        t.routines = export.template.routines.enumerated().filter { !skippedRoutines.contains($0.offset) }.map { item in
            var r = item.element
            if !includeModel { r.model = nil }
            return r
        }
        if !includeModel { t.model = nil }
        t.requires = export.template.requires.enumerated().filter { !skippedRequires.contains($0.offset) }.map(\.element)
        return t
    }

    private var fileName: String {
        ScoopTemplate.fileName(for: export?.template.name ?? "Scoop")
    }

    /// Datei für das Teilen-Menü in einen eigenen temporären Ordner schreiben (bei jeder Änderung neu).
    private func writeFile() {
        guard let data = try? output?.fileData() else { return }
        let dir = FileManager.default.temporaryDirectory.appending(path: "Vorlagen/\(botID)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: fileName)
        do {
            try data.write(to: url, options: .atomic)
            fileURL = url
        } catch {
            fileURL = nil
        }
    }

    // MARK: Vorschau

    @ViewBuilder
    private func preview(_ export: TemplateExport) -> some View {
        let t = export.template
        GroupedStack {
            VStack(spacing: 6) {
                TemplateFigure(appearance: includeAppearance ? previewAppearance(export) : nil,
                               showsPhoto: includeAppearance && includePhoto, size: 96)
                Text(t.name).appFont(20, weight: .semibold).foregroundStyle(theme.textPrimary)
                if let label = t.label, !label.isEmpty {
                    Text(label).appFont(13.5).foregroundStyle(theme.textSecondary)
                }
                Text(fileName).appFont(12).foregroundStyle(theme.textTertiary).adaptiveLineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)

            TemplateNotice(icon: "eye", title: String(localized: "Prüf die Texte auf Persönliches"),
                           lines: [String(localized: "In der Datei steht genau das, was hier eingeschaltet ist. Namen, Adressen oder Internes in den Anweisungen gibst du sonst mit weiter.")]
                               + export.warnings.map(\.text))

            GroupedSection("Beschreibung", footer: "Für andere: Wofür ist \(t.name) gut? (optional)") {
                TextField("z. B. Fasst jeden Morgen Termine und Mails zusammen", text: $description, axis: .vertical)
                    .textFieldStyle(.plain)
                    .appFont(15)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(2...5)
                    .groupedRow(vertical: 12)
            }

            GroupedSection("Aussehen", dividerInset: 50) {
                TemplateItem(icon: "paintpalette", title: String(localized: "Form, Farbe und Accessoire"), isOn: $includeAppearance)
                if export.optional.photo != nil {
                    TemplateItem(icon: "photo", title: String(localized: "Eigenes Bild"),
                                 subtitle: String(localized: "Nur auf Wunsch. Prüf, ob du es weitergeben darfst."),
                                 isOn: Binding(get: { includePhoto && includeAppearance }, set: { includePhoto = $0 }))
                        .disabled(!includeAppearance)
                }
            }

            GroupedSection("Rolle, Charakter und Anweisungen", dividerInset: 50) {
                TemplateItem(icon: "person.text.rectangle", title: t.name,
                             subtitle: t.label.flatMap { label in label.isEmpty ? nil : String(localized: "Rolle: \(label)") }
                                 ?? String(localized: "Ohne Rolle"))
                if let character = t.character, !character.isEmpty {
                    TemplateItem(icon: "theatermasks", title: String(localized: "Charakter und Anweisungen"), text: character,
                                 isOn: $includeCharacter, collapsible: true)
                }
            }

            if !t.skills.isEmpty || !export.optional.skills.isEmpty {
                GroupedSection("Fähigkeiten",
                               footer: export.optional.skills.isEmpty ? nil
                                   : "Fähigkeiten für alle Scoops gehören nicht nur zu \(t.name). Schalte sie ein, wenn die Vorlage sie braucht.",
                               dividerInset: 50) {
                    ForEach(Array(t.skills.enumerated()), id: \.offset) { i, skill in
                        TemplateItem(icon: "wand.and.stars", title: skill.name, subtitle: skill.description, text: skill.steps,
                                     isOn: toggle($skippedSkills, i, inverted: true), collapsible: true)
                    }
                    ForEach(Array(export.optional.skills.enumerated()), id: \.offset) { i, skill in
                        TemplateItem(icon: "person.3", title: skill.name,
                                     subtitle: [String(localized: "für alle Scoops"), skill.description].compactMap { $0?.isEmpty == false ? $0 : nil }
                                         .joined(separator: " · "),
                                     text: skill.steps, isOn: toggle($sharedSkills, i, inverted: false), collapsible: true)
                    }
                }
            }

            if !t.routines.isEmpty {
                GroupedSection("Routinen", footer: "Beim Import werden Routinen pausiert angelegt. Erinnerungen kommen nicht in die Vorlage.",
                               dividerInset: 50) {
                    ForEach(Array(t.routines.enumerated()), id: \.offset) { i, routine in
                        TemplateItem(icon: "clock", title: routine.title, subtitle: routine.scheduleLine, text: routine.prompt,
                                     isOn: toggle($skippedRoutines, i, inverted: true), collapsible: true)
                    }
                }
            }

            if let model = t.model {
                GroupedSection("Modell", footer: "Wer die Vorlage importiert, kann stattdessen sein Standardmodell nehmen.") {
                    TemplateItem(icon: "cpu", title: String(localized: "Bevorzugtes Modell"), subtitle: BotModel.displayName(for: model),
                                 isOn: $includeModel)
                }
            }

            if !t.requires.isEmpty {
                GroupedSection("Benötigte Verbindungen",
                               footer: "Nur ein Hinweis für andere. Deine Konten und Zugänge kommen nie in die Datei.",
                               dividerInset: 50) {
                    ForEach(Array(t.requires.enumerated()), id: \.offset) { i, item in
                        TemplateItem(icon: item.symbol, title: String(localized: "Braucht \(item.name)"), subtitle: item.note,
                                     isOn: toggle($skippedRequires, i, inverted: true))
                    }
                }
            }

            GroupedSection(footer: "Diese Dinge bleiben bei dir, egal was du oben wählst.") {
                GroupedLabelRow(icon: "lock", iconColor: theme.success, title: "Nie in der Datei",
                                subtitle: "Gedächtnis, Chatverlauf, Dateien, Tresor, Konten und Tokens von Verbindungen, dauerhafte Freigaben, Rechte, Kosten.")
            }
        }
    }

    /// Aussehen für die Vorschau oben (mit Bild, falls eingeschaltet)
    private func previewAppearance(_ export: TemplateExport) -> ScoopTemplate.Appearance? {
        var a = export.template.appearance
        if includePhoto { a?.photo = export.optional.photo }
        return a
    }

    /// Schalter für einen Eintrag einer Liste. `inverted`: Die Menge enthält die abgewählten Positionen.
    private func toggle(_ set: Binding<Set<Int>>, _ index: Int, inverted: Bool) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(index) != inverted },
                set: { on in
                    if on != inverted { set.wrappedValue.insert(index) } else { set.wrappedValue.remove(index) }
                })
    }

    // MARK: Knöpfe

    private func actions(_ export: TemplateExport) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let saveError {
                Text(saveError).appFont(12.5).foregroundStyle(theme.danger)
            }
            AdaptiveButtonRow(spacing: 10, stretchWhenStacked: true) {
                Spacer(minLength: 0)
                #if os(macOS)
                if let fileURL {
                    ShareLink(item: fileURL) { Label("Teilen …", systemImage: "square.and.arrow.up") }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                }
                Button { showSave = true } label: { Text("Sichern unter …") }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
                #else
                Button { showSave = true } label: { Label("In Dateien sichern", systemImage: "folder").adaptiveLineLimit(1) }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                if let fileURL {
                    ShareLink(item: fileURL) { Label("Teilen", systemImage: "square.and.arrow.up") }
                        .buttonStyle(PillButtonStyle(kind: .primary))
                }
                #endif
            }
            // Fußzeile eines Blatts: wächst bis zur größten normalen Stufe mit, bleibt so in einer Zeile
            .dynamicTypeSize(...AppFont.controlCap)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }
}
