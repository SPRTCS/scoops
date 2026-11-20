import SwiftUI
import PhotosUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// „Neuer Scoop“ bzw. „Scoop bearbeiten“: Live-Vorschau, Name, Label, Form, Farbe, Augen, Accessoire, Charakter.
struct CreateBotView: View {
    var editing: Bot?
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var label = ""
    @State private var section = ""
    @State private var character = ""
    @State private var mascot = Mascot.default
    @State private var saving = false
    @State private var previewSeed = UUID().uuidString
    @State private var model: String = ModelCatalogStore.shared.catalog.defaultModel
    @FocusState private var nameFocused: Bool
    // Eigenes Bild statt Maskottchen (v1.12)
    @State private var usesPhoto = false
    @State private var pendingPhoto: AvatarCropResult?
    @State private var lastPhotoSource: CGImage?
    @State private var cropSource: AvatarCropSource?
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showFileImporter = false
    @State private var dropTargeted = false
    @State private var photoError: String?

    private var isEditing: Bool { editing != nil }
    /// Bereits hochgeladenes Bild des bearbeiteten Scoops
    private var existingPhoto: MascotPhoto? { editing?.mascot.photo }
    private var hasPhoto: Bool { pendingPhoto != nil || existingPhoto != nil }
    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving && (!usesPhoto || hasPhoto)
    }
    /// Maskottchen ohne Bildverweis (zum Zeichnen und Speichern)
    private var plainMascot: Mascot {
        var m = mascot
        m.photo = nil
        return m
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(isEditing ? "Aussehen bearbeiten" : "Neuer Scoop", icon: isEditing ? "paintbrush" : "sparkles") {
                // Statt selbst zu gestalten: Scoop aus einer Vorlagen-Datei anlegen (docs/vorlagen.md)
                if !isEditing, store.supportsTemplates { TemplatePickerButton() }
            } onClose: { dismiss() }
            Divider().overlay(theme.surfaceBorder)

            ScrollView {
                VStack(spacing: 20) {
                    appearancePreview
                        .padding(.top, 8)

                    Picker("Aussehen", selection: $usesPhoto.animation(.snappy)) {
                        Text("Maskottchen").tag(false)
                        Text("Eigenes Bild").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 300)

                    VStack(spacing: 8) {
                        TextField("Name deines Scoops", text: $name)
                            .focused($nameFocused)
                            .multilineTextAlignment(.center)
                            .modifier(FieldStyle())
                        TextField("Label (optional), z. B. Assistenz", text: $label)
                            .multilineTextAlignment(.center)
                            .modifier(FieldStyle())
                    }

                    if usesPhoto {
                        pickerSection("Eigenes Bild") { photoControls }
                    } else {
                        pickerSection("Formen") { MascotShapeGrid(mascot: $mascot, shapes: Mascot.geometricShapes) }
                        pickerSection("Figuren") { MascotShapeGrid(mascot: $mascot, shapes: Mascot.organicShapes) }
                    }

                    pickerSection(usesPhoto ? "Akzentfarbe (Ring, wenn der Scoop arbeitet)" : "Farbe") {
                        MascotColorPalette(mascot: $mascot)
                    }

                    if !usesPhoto {
                    // Eine Gruppe: die fünf neuen Stile vorne, dahinter die verbliebenen klassischen
                    pickerSection("Augen") { MascotEyeGrid(mascot: $mascot) }

                    if mascot.hasGaze {
                        pickerSection("Blick") {
                            labeledRow(Mascot.gazes, selected: mascot.gaze ?? mascot.defaultGaze, name: Mascot.gazeName) { g in
                                variant { $0.gaze = g; $0.accessory = "none" }
                            } select: { mascot.gaze = $0 }
                        }
                    }

                    pickerSection("Mund") {
                        VStack(alignment: .leading, spacing: 10) {
                            labeledRow(Mascot.mouths, selected: mascot.mouthStyle, name: Mascot.mouthName) { m in
                                variant { $0.mouth = m; $0.accessory = "none" }
                            } select: { mascot.mouth = $0 }
                            HStack {
                                Text("Rote Wangen").appFont(13).foregroundStyle(theme.textPrimary)
                                Spacer()
                                Toggle("Rote Wangen", isOn: Binding(get: { mascot.showsCheeks }, set: { mascot.cheeks = $0 }))
                                    .labelsHidden()
                                    .toggleStyle(.switch)
                                    .controlSize(.small)
                                    .tint(theme.accent)
                            }
                        }
                    }

                    pickerSection("Accessoire") { accessoryPicker }
                    }

                    if !isEditing {
                        pickerSection("Modell") {
                            Picker("Modell", selection: $model) {
                                ForEach(ModelProvider.allCases) { provider in
                                    Section(provider.title) {
                                        ForEach(BotModel.choices(of: provider)) { m in
                                            Text(m.hint.map { "\(m.label) – \($0)" } ?? m.label).tag(m.id)
                                        }
                                    }
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .tint(theme.textPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.surfaceBorder))
                        }
                    }

                    pickerSection("Charakter (optional)") {
                        TextField("Wie soll dein Scoop sein? Etwa „locker, präzise, duzt“", text: $character, axis: .vertical)
                            .lineLimit(2...6)
                            .modifier(FieldStyle(alignment: .leading))
                    }

                    if isEditing {
                        pickerSection("Bereich (optional)") {
                            TextField("z. B. Arbeit", text: $section)
                                .modifier(FieldStyle(alignment: .leading))
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }

            Divider().overlay(theme.surfaceBorder)
            AdaptiveButtonRow(spacing: 10, stretchWhenStacked: true) {
                if !usesPhoto {
                    Button("Zufall") { randomize() }
                        .buttonStyle(PillButtonStyle(kind: .secondary))
                        .help("Zufälliges Aussehen")
                }
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button(isEditing ? "Sichern" : "Erstellen") { save() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            // Fußzeile eines Blatts: wächst bis zur größten normalen Stufe mit, bleibt so in einer Zeile
            .dynamicTypeSize(...AppFont.controlCap)
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 480, height: 740)
        #endif
        .onAppear {
            if let b = editing {
                name = b.name; label = b.label ?? ""; character = b.character ?? ""; mascot = b.mascot
                section = b.section ?? ""
                usesPhoto = b.mascot.photo != nil
                #if DEBUG
                // Screenshots/Tests: Zuschneiden mit dem erzeugten Demo-Bild öffnen
                if ProcessInfo.processInfo.arguments.contains("-cropdemo") { openCrop(MockService.demoPhotoData()) }
                #endif
            } else {
                randomize()
                nameFocused = true
            }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                let data = try? await item.loadTransferable(type: Data.self)
                photoItem = nil
                openCrop(data)
            }
        }
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.image]) { result in
            if case .success(let url) = result, let image = AvatarImport.image(from: url) {
                photoError = nil
                cropSource = AvatarCropSource(image: image)
            } else if case .success = result {
                photoError = String(localized: "Das Bild konnte nicht gelesen werden.")
            }
        }
        .sheet(item: $cropSource) { src in
            AvatarCropView(source: src.image) { result in
                pendingPhoto = result
                lastPhotoSource = src.image
                withAnimation(.snappy) { usesPhoto = true }
            }
            .environment(\.theme, theme)
            #if os(iOS)
            .presentationDetents([.large])
            #endif
        }
    }

    // MARK: Eigenes Bild (v1.12)

    /// Große Vorschau oben: Maskottchen, frisch zugeschnittenes Bild, vorhandenes Bild oder Platzhalter.
    /// Bilder lassen sich (vor allem auf dem Mac) direkt hierher ziehen.
    private var appearancePreview: some View {
        Group {
            if usesPhoto {
                if let pendingPhoto {
                    AvatarPendingPreview(image: pendingPhoto.image, size: 150)
                } else if let existingPhoto {
                    MascotView(mascot: variant { $0.photo = existingPhoto },
                               size: 150, seed: editing?.id, showsGround: true)
                } else {
                    Button { showPhotoPicker = true } label: {
                        AvatarEmptyPreview(size: 150, tint: Color(hex: mascot.color), targeted: dropTargeted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Foto wählen")
                }
            } else {
                MascotView(mascot: plainMascot, size: 150, seed: editing?.id ?? previewSeed, showsGround: true)
                    .animation(.spring(duration: 0.35, bounce: 0.4), value: plainMascot)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            AvatarImport.load(providers) { data in openCrop(data) }
        }
    }

    private var photoControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            AdaptiveButtonRow(spacing: 8) {
                Button { showPhotoPicker = true } label: {
                    Label(hasPhoto ? "Anderes Foto" : "Foto wählen", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(PillButtonStyle(kind: hasPhoto ? .secondary : .primary))
                #if os(macOS)
                Button { showFileImporter = true } label: {
                    Label("Datei …", systemImage: "folder")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .help("Bilddatei wählen (oder auf die Vorschau ziehen)")
                #endif
                if let lastPhotoSource {
                    Button { cropSource = AvatarCropSource(image: lastPhotoSource) } label: {
                        Label("Zuschneiden", systemImage: "crop")
                    }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                }
            }
            Text(photoHint)
                .appFont(12)
                .foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let photoError {
                Text(photoError).appFont(12).foregroundStyle(.red)
            }
            if hasPhoto {
                Button {
                    pendingPhoto = nil
                    lastPhotoSource = nil
                    withAnimation(.snappy) { usesPhoto = false }
                } label: {
                    Label("Zurück zum Maskottchen", systemImage: "arrow.uturn.backward")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
            }
        }
    }

    private var photoHint: String {
        #if os(macOS)
        String(localized: "Foto oder Grafik, wird rund angezeigt. Du kannst ein Bild auch direkt auf die Vorschau ziehen. Accessoires gibt es nur beim Maskottchen.")
        #else
        String(localized: "Foto oder Grafik, wird rund angezeigt. Accessoires gibt es nur beim Maskottchen.")
        #endif
    }

    private func openCrop(_ data: Data?) {
        guard let data, let image = ScoopPhotoCoding.image(from: data) else {
            photoError = String(localized: "Das Bild konnte nicht gelesen werden.")
            return
        }
        photoError = nil
        cropSource = AvatarCropSource(image: image)
    }

    /// Aktuelles Maskottchen mit einer Änderung (für Vorschauen, behält Blick, Mund und Wangen).
    private func variant(_ change: (inout Mascot) -> Void) -> Mascot { mascot.variant(change) }

    /// Drei bis sechs Varianten mit Vorschau und Namen (Blick, Mund)
    private func labeledRow(_ items: [String], selected: String, name: @escaping (String) -> String,
                            preview: @escaping (String) -> Mascot, select: @escaping (String) -> Void) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
            ForEach(items, id: \.self) { item in
                choice(selected: selected == item, label: name(item)) {
                    select(item)
                } content: {
                    VStack(spacing: 3) {
                        // Gesichtsausschnitt, damit Blick und Mund auch klein erkennbar sind
                        MascotView(mascot: preview(item), size: 104, seed: "face", animated: false)
                            .offset(y: -9)
                            .frame(width: 64, height: 42)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .padding(.top, 5)
                        Text(name(item))
                            .appFont(9.5)
                            .foregroundStyle(selected == item ? theme.textPrimary : theme.textSecondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
    }

    private func pickerSection<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).appFont(12.5, weight: .medium).foregroundStyle(theme.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func choice<Content: View>(selected: Bool, label: String, action: @escaping () -> Void,
                                       @ViewBuilder content: () -> Content) -> some View {
        MascotChoice(selected: selected, label: label, action: action, content: content)
    }

    private func randomize() { mascot = Mascot.random() }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let l = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let c = character.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !saving else { return }
        saving = true
        if let b = editing {
            Task {
                let sec = section.trimmingCharacters(in: .whitespaces)
                // Geteilter Scoop (Gast mit „Bearbeiten“): Bereiche gehören dem Admin, der Server erlaubt nur
                // Name, Label, Aussehen, Charakter und Stimme
                let guest = store.isGuestChat(b.id)
                await store.updateBot(b.id, BotPatch(name: n, label: l, mascot: plainMascot, character: c,
                                                     section: guest ? nil : .some(sec.isEmpty ? nil : sec)))
                // Eigenes Bild hochladen bzw. zurück zum Maskottchen
                if usesPhoto, let pendingPhoto {
                    await store.setAvatar(b.id, image: pendingPhoto.data)
                } else if !usesPhoto, b.mascot.photo != nil {
                    await store.setAvatar(b.id, image: nil)
                }
                saving = false
                dismiss()
            }
        } else {
            // Sofort schließen: Der neue Scoop „schlüpft“ als Platzhalter in der Seitenleiste.
            store.createBotInBackground(BotDraft(name: n, label: l.isEmpty ? nil : l, mascot: plainMascot,
                                                 character: c.isEmpty ? nil : c, model: model),
                                        photo: usesPhoto ? pendingPhoto?.data : nil)
            dismiss()
        }
    }

    /// Accessoires gruppiert (Kopf, Gesicht, Hals), Vorschau am gewählten Scoop (Form, Farbe, Augen), mit kurzem Namen.
    private var accessoryPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Mascot.accessoryGroups, id: \.title) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.title)
                        .appFont(11, weight: .medium)
                        .foregroundStyle(theme.textSecondary.opacity(0.8))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 60, maximum: 78), spacing: 4)], spacing: 4) {
                        ForEach(group.items, id: \.self) { acc in
                            choice(selected: mascot.accessory == acc, label: Mascot.accessoryName(acc)) {
                                mascot.accessory = acc
                            } content: {
                                VStack(spacing: 1) {
                                    MascotView(mascot: variant { $0.accessory = acc },
                                               size: 42, seed: "acc", animated: false)
                                        .padding(.top, 5)
                                    Text(Mascot.accessoryName(acc))
                                        .appFont(9.5)
                                        .foregroundStyle(mascot.accessory == acc ? theme.textPrimary : theme.textSecondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.7)
                                        .padding(.horizontal, 2)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

struct FieldStyle: ViewModifier {
    var alignment: Alignment = .center
    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .appFont(14.5)
            .foregroundStyle(theme.textPrimary)
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.surfaceBorder))
    }
}

/// Farbe → Hex (#RRGGBB) für das Maskottchen.
enum ColorHex {
    static func hex(from color: Color) -> String {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .gray
        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        #endif
        func c(_ v: CGFloat) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return String(format: "#%02X%02X%02X", c(r), c(g), c(b))
    }
}

#if os(iOS)
/// System-Farbwähler (UIColorPickerViewController) als SwiftUI-Blatt.
struct SystemColorPicker: UIViewControllerRepresentable {
    @Binding var color: Color

    func makeUIViewController(context: Context) -> UIColorPickerViewController {
        let vc = UIColorPickerViewController()
        vc.supportsAlpha = false
        vc.title = String(localized: "Eigene Farbe")
        vc.selectedColor = UIColor(color)
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIColorPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(color: $color) }

    final class Coordinator: NSObject, UIColorPickerViewControllerDelegate {
        var color: Binding<Color>
        init(color: Binding<Color>) { self.color = color }

        func colorPickerViewController(_ vc: UIColorPickerViewController, didSelect selected: UIColor, continuously: Bool) {
            color.wrappedValue = Color(uiColor: selected)
        }
    }
}
#endif
