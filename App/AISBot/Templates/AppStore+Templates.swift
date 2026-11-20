import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Scoop-Vorlagen (App 1.3, docs/vorlagen.md)

/// Offene Blätter rund um Vorlagen (liegt im `AppStore`, damit Seitenleiste, Profil, Menü und geöffnete Dateien
/// dasselbe Blatt ansteuern).
@Observable
final class TemplateStore {
    /// Datei, deren Vorschau vor dem Import gezeigt wird
    var importSource: TemplateSource?
    /// Scoop, dessen Export-Vorschau gezeigt wird
    var exportBotID: String?
    /// Dateiauswahl „Aus Vorlage …“ (Menü)
    var showPicker = false
}

extension AppStore {
    /// Der eigene Server liest Vorlagen (auch der Demo-Server, außer mit `-oldserver`). Ältere Server: Menüpunkte bleiben ausgeblendet.
    var supportsTemplates: Bool { (serverHealth?.templates ?? 0) >= 1 }

    /// Exportieren darf nur, wem der Scoop gehört. Gäste geteilter Scoops können ihn nicht exportieren.
    func canExportTemplate(_ botID: String) -> Bool {
        supportsTemplates && ownBot(botID) != nil && !isGuestChat(botID)
    }

    /// Export-Vorschau öffnen (Profil, Kontextmenü)
    func exportTemplate(_ botID: String) {
        guard canExportTemplate(botID) else { return }
        templates.exportBotID = botID
    }

    /// Datei als Vorlage öffnen („Öffnen mit“, AirDrop, Doppelklick, Dateiauswahl, Drag-and-drop).
    /// `false`, wenn es keine `.scoop`-Datei ist (dann ist die URL für jemand anderen).
    @discardableResult
    func openTemplateFile(_ url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == ScoopTemplate.fileExtension else { return false }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data = Data()
        // Nicht mehr lesen als nötig: zu große Dateien lehnt die Vorschau mit einer klaren Meldung ab
        if let handle = try? FileHandle(forReadingFrom: url) {
            data = (try? handle.read(upToCount: ScoopTemplate.maxBytes + 1)) ?? Data()
            try? handle.close()
        }
        // iOS legt Dateien aus „Öffnen mit“ und AirDrop als Kopie im Eingang der App ab; dort nicht liegen lassen
        if url.path.contains("/Documents/Inbox/") { try? FileManager.default.removeItem(at: url) }
        presentTemplate(TemplateSource(data: data, fileName: url.lastPathComponent))
        return true
    }

    /// Vorschau vor dem Import zeigen. Offene Blätter (Neuer Scoop, Einstellungen) schließen sich vorher.
    func presentTemplate(_ source: TemplateSource) {
        let busy = showCreateBot || showSettings || templates.exportBotID != nil
        showCreateBot = false
        showSettings = false
        templates.exportBotID = nil
        guard busy else {
            templates.importSource = source
            return
        }
        Task {
            try? await Task.sleep(for: .milliseconds(450))  // erst, wenn das andere Blatt weg ist
            templates.importSource = source
        }
    }

    /// Lädt, was in eine Vorlage dieses Scoops käme (für die Export-Vorschau).
    func loadTemplateExport(botID: String) async -> Result<TemplateExport, TemplateProblem> {
        guard let svc = service as? TemplateService else { return .failure(.server(String(localized: "Keine Verbindung zum Server."))) }
        do {
            return .success(try await svc.exportTemplate(botID: botID))
        } catch let error as APIError where error.status == 404 {
            return .failure(.server(String(localized: "Dein Server kennt Vorlagen noch nicht. Aktualisiere AIS Scoops Server.")))
        } catch {
            return .failure(.server(message(error)))
        }
    }

    /// Prüft eine Datei, ohne etwas anzulegen: erst in der App (Größe, Typ, Format), dann streng auf dem Server.
    func checkTemplate(_ source: TemplateSource) async -> Result<TemplateCheck, TemplateProblem> {
        if source.data.isEmpty { return .failure(.unreadable) }
        if let problem = ScoopTemplate.precheck(source.data) { return .failure(problem) }
        guard phase == .online || isMock, let svc = service as? TemplateService else {
            return .failure(.server(isConfigured
                ? String(localized: "Dein Server ist gerade nicht erreichbar. Versuch es gleich noch einmal.")
                : String(localized: "Verbinde dich zuerst mit deinem Server. Dann kannst du Scoops aus Vorlagen anlegen.")))
        }
        do {
            return .success(try await svc.checkTemplate(source.data))
        } catch let error as APIError where error.status == 404 {
            return .failure(.server(String(localized: "Dein Server kennt Vorlagen noch nicht. Aktualisiere AIS Scoops Server.")))
        } catch let error as DecodingError {
            #if DEBUG
            print("[Vorlage] Antwort nicht lesbar: \(error)")
            #endif
            return .failure(.notATemplate)
        } catch {
            return .failure(.server(message(error)))
        }
    }

    /// Legt den Scoop an und öffnet seinen Chat. Rückgabe: Fehlertext.
    func importTemplate(_ request: TemplateImportRequest) async -> String? {
        guard let svc = service as? TemplateService else { return String(localized: "Keine Verbindung zum Server.") }
        do {
            let result = try await svc.importTemplate(request)
            apply(.botCreated(result.bot))
            openChat(result.bot.id)
            let paused = result.routines ?? 0
            showToast(paused > 0 ? String(localized: "\(result.bot.name) ist da. Routinen sind pausiert.")
                              : String(localized: "\(result.bot.name) ist da"))
            return nil
        } catch {
            return message(error)
        }
    }
}

/// Vorlagen-Datei für „Sichern unter“ (`fileExporter`).
struct TemplateDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.scoopTemplate, .json] }
    static var writableContentTypes: [UTType] { [.scoopTemplate] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// Hängt alles, was Vorlagen an der Wurzel der App brauchen, an `RootView`: Vorschau vor dem Import, Export-Vorschau,
/// Dateiauswahl aus dem Menü und Drag-and-drop einer `.scoop`-Datei ins Fenster (Mac, iPad).
struct TemplateHost: ViewModifier {
    @Environment(AppStore.self) private var store
    @State private var dropTargeted = false

    /// Wie in `RootView`: Das Theme kommt aus dem Store (die Umgebung setzt `RootView` erst für seine Kinder).
    private var theme: Theme { store.currentTheme }

    func body(content: Content) -> some View {
        @Bindable var templates = store.templates
        content
            .sheet(item: $templates.importSource) { source in
                TemplateImportView(source: source)
                    .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }
            .sheet(item: Binding(get: { templates.exportBotID.map(IdentifiedString.init) },
                                 set: { templates.exportBotID = $0?.id })) { item in
                TemplateExportView(botID: item.id)
                    .environment(\.theme, theme).environment(store).preferredColorScheme(theme.preferredScheme)
                    #if os(iOS)
                    .presentationDetents([.large])
                    #endif
            }
            .fileImporter(isPresented: $templates.showPicker, allowedContentTypes: [.scoopTemplate, .json]) { result in
                if case .success(let url) = result { TemplatePicker.open(url, store: store) }
            }
            .onDrop(of: [.scoopTemplate], isTargeted: $dropTargeted) { providers in
                TemplatePicker.load(providers, store: store)
            }
            .overlay {
                if dropTargeted {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(theme.accent, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
                        .background(theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            Label("Vorlage hier ablegen", systemImage: "square.and.arrow.down")
                                .appFont(17, weight: .semibold)
                                .foregroundStyle(theme.textPrimary)
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(theme.surfaceRaised, in: Capsule())
                        }
                        .padding(10)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.snappy(duration: 0.15), value: dropTargeted)
            .task {
                // Nur Screenshots/Tests: `-templatedemo` zeigt die Import-Vorschau einer Beispielvorlage,
                // `-templateexport` die Export-Vorschau des gewählten Scoops (bzw. von Mila)
                let args = ProcessInfo.processInfo.arguments
                guard store.isMock, args.contains("-templatedemo") || args.contains("-templateexport") else { return }
                try? await Task.sleep(for: .milliseconds(900))
                if args.contains("-templatedemo") {
                    store.presentTemplate(TemplateSource(data: MockTemplates.sampleFile, fileName: demoText("Morgenbriefing.scoop", en: "Morning-Briefing.scoop")))
                } else {
                    store.exportTemplate(store.selectedChatID.flatMap { store.ownBot($0)?.id } ?? "b_mila")
                }
            }
    }
}

/// Dateien aus Dateiauswahl und Drag-and-drop einlesen.
enum TemplatePicker {
    /// Gewählte Datei öffnen. Auch `.json`-Dateien sind erlaubt (umbenannte Vorlagen); die Prüfung entscheidet.
    @MainActor
    static func open(_ url: URL, store: AppStore) {
        if store.openTemplateFile(url) { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var data = Data()
        if let handle = try? FileHandle(forReadingFrom: url) {
            data = (try? handle.read(upToCount: ScoopTemplate.maxBytes + 1)) ?? Data()
            try? handle.close()
        }
        store.presentTemplate(TemplateSource(data: data, fileName: url.lastPathComponent))
    }

    /// Abgelegte Datei (Finder, Dateien-App) laden und die Vorschau zeigen.
    @MainActor
    static func load(_ providers: [NSItemProvider], store: AppStore) -> Bool {
        guard let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.scoopTemplate.identifier) })
        else { return false }
        let name = provider.suggestedName.map { $0.hasSuffix(".scoop") ? $0 : "\($0).scoop" }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.scoopTemplate.identifier) { data, _ in
            guard let data else { return }
            Task { @MainActor in
                store.presentTemplate(TemplateSource(data: Data(data.prefix(ScoopTemplate.maxBytes + 1)), fileName: name))
            }
        }
        return true
    }
}

/// Knopf „Aus Vorlage …“ im Blatt „Neuer Scoop“ mit eigener Dateiauswahl (das Blatt hat schon eine für Bilder; zwei
/// `fileImporter` an derselben Ansicht vertragen sich nicht).
struct TemplatePickerButton: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Label("Aus Vorlage …", systemImage: "square.and.arrow.down").lineLimit(1).fixedSize()
        }
        .buttonStyle(PillButtonStyle(kind: .secondary))
        .help("Scoop aus einer Vorlagen-Datei (.scoop) anlegen")
        .accessibilityHint("Öffnet die Dateiauswahl für eine Scoop-Vorlage")
        .fileImporter(isPresented: $picking, allowedContentTypes: [.scoopTemplate, .json]) { result in
            if case .success(let url) = result { TemplatePicker.open(url, store: store) }
        }
    }
}
