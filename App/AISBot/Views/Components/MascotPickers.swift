import SwiftUI

// Bausteine des Scoop-Editors: Form, Farbe und Augen. Verwendet von „Neuer Scoop“/„Aussehen bearbeiten“
// (CreateBotView) und der geführten Erstellung in der Einführung (OnboardingScoopStep).

/// Auswahlfeld mit Vorschau (Form, Augen, Blick, Mund, Accessoire)
struct MascotChoice<Content: View>: View {
    var selected: Bool
    var label: String
    var action: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            content
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(selected ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? theme.textSecondary.opacity(0.6) : .clear, lineWidth: 1.5))
                .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

extension Mascot {
    /// Maskottchen ohne Bildverweis mit einer Änderung (Vorschauen; behält Blick, Mund und Wangen)
    func variant(_ change: (inout Mascot) -> Void) -> Mascot {
        var m = self
        m.photo = nil
        change(&m)
        return m
    }

    /// Zufälliges Aussehen im neuen Stil: einer der gezeichneten Augenstile, meist satte Farben, höchstens ein
    /// ruhiges Accessoire (oft keins).
    static func random() -> Mascot {
        var rng = SeededRandom(string: UUID().uuidString)
        func pick<T>(_ a: [T]) -> T { a[Int(rng.unit() * Double(a.count)) % a.count] }
        let color = rng.unit() < 0.8 ? pick(boldPalette).hex : pick(palette).hex
        let accessory = rng.unit() < 0.6 ? "none" : pick(calmAccessories)
        var m = Mascot(shape: pick(shapes), color: color, eyes: pick(modernEyeStyles), accessory: accessory)
        if m.hasGaze { m.gaze = pick(["left", "right", "right", "left", "center"]) }
        let r = rng.unit()
        m.mouth = r < 0.65 ? (m.drawnEyes == "dashes" ? "smile" : "smirk") : (r < 0.85 ? "smile" : "neutral")
        return m
    }
}

/// Raster der Formen bzw. Figuren
struct MascotShapeGrid: View {
    @Binding var mascot: Mascot
    var shapes: [String]
    var previewSize: CGFloat = 40

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: previewSize + 14, maximum: previewSize + 32), spacing: 4)], spacing: 4) {
            ForEach(shapes, id: \.self) { shape in
                MascotChoice(selected: mascot.shape == shape, label: Mascot.shapeName(shape)) {
                    mascot.shape = shape
                } content: {
                    MascotView(mascot: mascot.variant { $0.shape = shape; $0.accessory = "none" },
                               size: previewSize, seed: "shape-\(shape)", animated: false)
                }
            }
        }
    }
}

/// Raster der Augenstile (am Ei gezeigt)
struct MascotEyeGrid: View {
    @Binding var mascot: Mascot
    var styles: [String] = Mascot.eyeStyles
    var columns = 6

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            ForEach(styles, id: \.self) { eyes in
                // Nicht mehr angebotene Stile erscheinen als ihr Nachfolger gewählt (`drawnEyes`)
                MascotChoice(selected: mascot.drawnEyes == eyes, label: Mascot.eyesName(eyes)) {
                    mascot.eyes = eyes
                } content: {
                    MascotView(mascot: mascot.variant { $0.shape = "egg"; $0.eyes = eyes; $0.accessory = "none" },
                               size: 40, seed: "eyes", animated: false)
                }
            }
        }
    }
}

/// Farben: erste Reihe 7 satte Key-Visual-Farben, darunter eigene Farbe + 11 klassische Farben.
struct MascotColorPalette: View {
    @Binding var mascot: Mascot
    @Environment(\.theme) private var theme
    #if os(iOS)
    @State private var showColorPicker = false
    #endif

    var body: some View {
        // 7 Spalten à 32 pt mit 8 pt Abstand (passt auch auf schmale iPhones)
        let columns = Array(repeating: GridItem(.fixed(32), spacing: 8), count: 7)
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(Mascot.boldPalette, id: \.hex) { swatch($0) }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                customColorWell
                ForEach(Mascot.palette, id: \.hex) { swatch($0) }
            }
        }
    }

    private func swatch(_ entry: (name: String, hex: String)) -> some View {
        let selected = mascot.color.uppercased() == entry.hex.uppercased()
        return Button { mascot.color = entry.hex } label: {
            Circle()
                .fill(Color(hex: entry.hex))
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(theme.surfaceBorder))
                .padding(3)
                .overlay(Circle().strokeBorder(selected ? theme.textPrimary : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
        .help(entry.name)
        .accessibilityLabel(entry.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Eigene Farbe: runder Regenbogen-Ring (gleiche Größe wie die anderen Farbfelder). Ohne eigene Farbe steht ein „+“ in
    /// der Mitte, sonst die gewählte Farbe. Darüber liegt ein unsichtbarer System-Farbwähler, der das Antippen übernimmt.
    private var customColorWell: some View {
        let isCustom = !(Mascot.boldPalette + Mascot.palette).contains { $0.hex.uppercased() == mascot.color.uppercased() }
        return ZStack {
            Circle()
                .strokeBorder(AngularGradient(colors: [.red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink, .red],
                                              center: .center), lineWidth: 4)
                .frame(width: 26, height: 26)
                .accessibilityHidden(true)
            if isCustom {
                Circle().fill(Color(hex: mascot.color)).frame(width: 16, height: 16).accessibilityHidden(true)
            } else {
                Image(systemName: "plus")
                    .appFont(10, weight: .bold)
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            }
            #if os(macOS)
            // Mac: unsichtbarer System-Farbwähler über dem Kreis öffnet das Farbfenster
            ColorPicker("Eigene Farbe", selection: Binding(
                get: { Color(hex: mascot.color) },
                set: { mascot.color = ColorHex.hex(from: $0) }), supportsOpacity: false)
                .labelsHidden()
                .scaleEffect(1.6)
                .frame(width: 26, height: 26)
                .clipShape(Circle())
                .opacity(0.02)
            #endif
        }
        #if os(iOS)
        // iOS/iPadOS: Antippen öffnet den System-Farbwähler als Blatt
        .onTapGesture { showColorPicker = true }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Eigene Farbe")
        .accessibilityAddTraits(.isButton)
        .sheet(isPresented: $showColorPicker) {
            SystemColorPicker(color: Binding(get: { Color(hex: mascot.color) },
                                             set: { mascot.color = ColorHex.hex(from: $0) }))
                .presentationDetents([.medium, .large])
        }
        #endif
        .frame(width: 26, height: 26)
        .padding(3)
        .overlay(Circle().strokeBorder(isCustom ? theme.textPrimary : .clear, lineWidth: 2))
        .contentShape(Circle())
        .help("Eigene Farbe")
    }
}
