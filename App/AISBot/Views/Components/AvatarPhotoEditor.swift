import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Eigenes Scoop-Bild: Auswahl und Zuschneiden (v1.12)
//
// Ablauf im Editor („Aussehen bearbeiten“ / „Neuer Scoop“): Foto aus der Mediathek (PhotosPicker),
// auf dem Mac zusätzlich Datei wählen oder per Drag & Drop auf die Vorschau ziehen → Zuschneiden
// (runde Vorschau, Verschieben, Zoom) → quadratisches JPEG/PNG (max. 512 px), das beim Sichern hochgeladen wird.

/// Ausgangsbild für das Zuschneiden.
struct AvatarCropSource: Identifiable {
    let id = UUID()
    let image: CGImage
}

/// Ergebnis des Zuschneidens: Daten für den Upload und Bild für die Vorschau.
struct AvatarCropResult {
    var data: Data
    var image: CGImage
}

/// Bilder aus Mediathek, Datei oder Drag & Drop laden.
nonisolated enum AvatarImport {
    static func image(from url: URL) -> CGImage? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ScoopPhotoCoding.image(from: data)
    }

    /// Nimmt das erste Bild bzw. die erste Bilddatei aus einem Drop entgegen (Daten werden im Hintergrund geladen).
    static func load(_ providers: [NSItemProvider], completion: @escaping @MainActor @Sendable (Data?) -> Void) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                let data = url.flatMap { u -> Data? in
                    let access = u.startAccessingSecurityScopedResource()
                    defer { if access { u.stopAccessingSecurityScopedResource() } }
                    return try? Data(contentsOf: u)
                }
                Task { @MainActor in completion(data) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                Task { @MainActor in completion(data) }
            }
            return true
        }
        return false
    }
}

/// Zuschneiden mit runder Vorschau: Bild ziehen zum Verschieben, Zoom per Regler, Zwei-Finger-Geste
/// oder Trackpad. Der Kreis zeigt, was später in Seitenleiste und Chat zu sehen ist.
struct AvatarCropView: View {
    let source: CGImage
    var onDone: (AvatarCropResult) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var dragStart: CGSize?
    @State private var pinchStart: CGFloat?

    private let side: CGFloat = 300
    private let maxZoom: CGFloat = 5

    private var imageSize: CGSize { CGSize(width: source.width, height: source.height) }
    /// Punkte pro Bildpixel (Zoom 1 = Bild füllt den Ausschnitt).
    private var scale: CGFloat { side / min(imageSize.width, imageSize.height) * zoom }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader("Bild zuschneiden", icon: "crop") { dismiss() }
            Divider().overlay(theme.surfaceBorder)

            VStack(spacing: 18) {
                cropArea
                HStack(spacing: 10) {
                    Image(systemName: "minus.magnifyingglass").foregroundStyle(theme.textSecondary)
                    Slider(value: Binding(get: { zoom }, set: { setZoom($0) }), in: 1...maxZoom)
                        .accessibilityLabel("Zoom")
                    Image(systemName: "plus.magnifyingglass").foregroundStyle(theme.textSecondary)
                }
                .frame(width: side)
                Text("Ziehen zum Verschieben, zoomen mit dem Regler oder zwei Fingern.")
                    .appFont(12.5)
                    .foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)

            Spacer(minLength: 0)
            Divider().overlay(theme.surfaceBorder)
            AdaptiveButtonRow(spacing: 10, stretchWhenStacked: true) {
                Button("Zurücksetzen") { withAnimation(.snappy) { zoom = 1; offset = .zero } }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Übernehmen") { finish() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .keyboardShortcut(.defaultAction)
            }
            // Fußzeile eines Blatts: wächst bis zur größten normalen Stufe mit, bleibt so in einer Zeile
            .dynamicTypeSize(...AppFont.controlCap)
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(theme.groupedBackground)
        #if os(macOS)
        .frame(width: 420, height: 560)
        #endif
    }

    private var cropArea: some View {
        let k = scale
        return ZStack {
            Color.black
            Image(decorative: source, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: imageSize.width * k, height: imageSize.height * k)
                .offset(offset)
            // Außerhalb des Kreises abdunkeln
            Rectangle()
                .fill(.black.opacity(0.55))
                .reverseMask { Circle().padding(2) }
                .allowsHitTesting(false)
            Circle()
                .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                .padding(2)
                .allowsHitTesting(false)
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .contentShape(Rectangle())
        .gesture(dragGesture.simultaneously(with: pinchGesture))
        .accessibilityElement()
        .accessibilityLabel("Bildausschnitt")
        .accessibilityHint("Ziehen zum Verschieben")
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let start = dragStart ?? offset
                if dragStart == nil { dragStart = offset }
                offset = clamped(CGSize(width: start.width + value.translation.width,
                                        height: start.height + value.translation.height))
            }
            .onEnded { _ in dragStart = nil }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = pinchStart ?? zoom
                if pinchStart == nil { pinchStart = zoom }
                setZoom(start * value.magnification)
            }
            .onEnded { _ in pinchStart = nil }
    }

    private func setZoom(_ value: CGFloat) {
        zoom = min(maxZoom, max(1, value))
        offset = clamped(offset)
    }

    /// Das Bild muss den Ausschnitt immer ganz füllen.
    private func clamped(_ o: CGSize) -> CGSize {
        let maxX = max(0, (imageSize.width * scale - side) / 2)
        let maxY = max(0, (imageSize.height * scale - side) / 2)
        return CGSize(width: min(maxX, max(-maxX, o.width)), height: min(maxY, max(-maxY, o.height)))
    }

    private func finish() {
        let k = scale
        // Linke obere Ecke des Bilds in Ausschnitt-Koordinaten → sichtbarer Ausschnitt in Bildpixeln
        let left = side / 2 + offset.width - imageSize.width * k / 2
        let top = side / 2 + offset.height - imageSize.height * k / 2
        let rect = CGRect(x: -left / k, y: -top / k, width: side / k, height: side / k)
        guard let cropped = ScoopPhotoCoding.crop(source, to: rect, side: 512),
              let data = ScoopPhotoCoding.encode(cropped) else { return }
        onDone(AvatarCropResult(data: data, image: cropped))
        dismiss()
    }
}

private extension View {
    /// Maske mit „Loch“ (sichtbar bleibt alles außer `mask`).
    func reverseMask<M: View>(@ViewBuilder _ mask: () -> M) -> some View {
        self.mask {
            Rectangle()
                .overlay { mask().blendMode(.destinationOut) }
                .compositingGroup()
        }
    }
}

/// Runde Vorschau eines frisch zugeschnittenen (noch nicht hochgeladenen) Bilds im Editor.
struct AvatarPendingPreview: View {
    var image: CGImage
    var size: CGFloat
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Ellipse()
                .fill(theme.mascotGround)
                .frame(width: size * 0.5, height: size * 0.075)
                .blur(radius: size * 0.035)
                .offset(y: size * 0.45)
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size * 0.84, height: size * 0.84)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 1))
                .offset(y: -size * 0.04)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// Leerer Platzhalter „Bild wählen“ (Foto-Modus ohne Bild).
struct AvatarEmptyPreview: View {
    var size: CGFloat
    var tint: Color
    var targeted: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack {
            Circle()
                .fill(tint.opacity(targeted ? 0.3 : 0.14))
            Circle()
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                .foregroundStyle(targeted ? tint : theme.textSecondary.opacity(0.5))
            VStack(spacing: 6) {
                Image(systemName: "photo.badge.plus")
                    .font(.fixed(size * 0.2))
                #if os(macOS)
                Text("Bild hierher ziehen").appFont(11.5, weight: .medium)
                #endif
            }
            .foregroundStyle(theme.textSecondary)
        }
        .frame(width: size * 0.84, height: size * 0.84)
        .offset(y: -size * 0.04)
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
