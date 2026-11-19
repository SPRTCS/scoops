#if os(macOS)
import AppKit
import SwiftUI

/// Rendert App-Icon und Vorschaubilder per ImageRenderer:
/// `"AIS Scoops.app/Contents/MacOS/AIS Scoops" -render-assets <Ordner>`
enum AssetRenderer {
    static func renderAll(to directory: String) {
        let dir = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // `AIS_RENDER_ONLY=widgets`: nur die Widget-Tafeln (inkl. Demo-Scoop mit eigenem Bild, v1.12)
        if ProcessInfo.processInfo.environment["AIS_RENDER_ONLY"] == "widgets" {
            for photo in PreviewData.bots.compactMap(\.mascot.photo) where !ScoopPhotoCache.hasFile(photo) {
                ScoopPhotoCache.shared.store(MockService.demoPhotoData(), for: photo)
            }
            for (name, view) in WidgetPreviewBoard.boards() {
                write(view, size: nil, to: dir.appending(path: "\(name).png"), scale: 2)
            }
            return
        }
        // `AIS_RENDER_ONLY=eyes`: nur die Übersicht der Augenstile
        if ProcessInfo.processInfo.environment["AIS_RENDER_ONLY"] == "eyes" {
            write(EyeVariantsSheet(), size: nil, to: dir.appending(path: "augen-varianten.png"), scale: 2)
            return
        }
        // Accessoire-Matrix (alle Formen × alle Accessoires, Nacht und Hell) und Prüfblätter je Accessoire.
        // `AIS_RENDER_ONLY=accessories` rendert nur diese (schneller beim Feinjustieren).
        renderAccessorySheets(to: dir)
        if ProcessInfo.processInfo.environment["AIS_RENDER_ONLY"] == "accessories" { return }
        // App-Symbole: Haupt-Symbol (iOS randlos, macOS mit Raster) und alle Varianten
        write(AppIconArtwork(variant: .gelb), size: CGSize(width: 1024, height: 1024), to: dir.appending(path: "icon-ios.png"))
        write(AppIconArtwork(variant: .gelb, rounded: true), size: CGSize(width: 1024, height: 1024), to: dir.appending(path: "icon-mac.png"))
        for v in AppIconVariant.allCases {
            write(AppIconArtwork(variant: v), size: CGSize(width: 1024, height: 1024), to: dir.appending(path: "icon-\(v.rawValue).png"))
        }
        write(AppIconContactSheet(), size: nil, to: dir.appending(path: "app-icons.png"), scale: 1)
        write(MascotGallery(), size: nil, to: dir.appending(path: "mascots.png"), scale: 2)
        // Neuer Stil (v1.31); `AIS_KEYVISUAL=<png>` legt das Key Visual als Referenz darüber
        let reference = ProcessInfo.processInfo.environment["AIS_KEYVISUAL"].flatMap { NSImage(contentsOfFile: $0) }
        write(MascotStyleSheet(reference: reference), size: nil, to: dir.appending(path: "mascots-neu.png"), scale: 2)
        write(EyeVariantsSheet(), size: nil, to: dir.appending(path: "augen-varianten.png"), scale: 2)
        for (name, view) in WidgetPreviewBoard.boards() {
            write(view, size: nil, to: dir.appending(path: "\(name).png"), scale: 2)
        }
    }

    static func renderAccessorySheets(to dir: URL) {
        for theme in [Theme.nacht, Theme.hell] {
            let name = theme.kind == .nacht ? "nacht" : "hell"
            write(AccessoryMatrix(theme: theme), size: nil, to: dir.appending(path: "accessoires-uebersicht-\(name).png"), scale: 2)
        }
        // Prüfblätter: jedes Accessoire auf allen Formen in Profilgröße (104) und Seitenleistengröße (30/44/62)
        for acc in Mascot.accessories where acc != "none" {
            write(AccessoryCheckSheet(accessory: acc), size: nil, to: dir.appending(path: "check-\(acc).png"), scale: 2)
        }
    }

    private static func write<V: View>(_ view: V, size: CGSize?, to url: URL, scale: CGFloat = 1) {
        let content = Group {
            if let size { view.frame(width: size.width, height: size.height) } else { view }
        }
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cg = renderer.cgImage else {
            print("Rendern fehlgeschlagen: \(url.lastPathComponent)")
            return
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        // Die Mac-App ist sandboxed: Mit `AIS_RENDER_STDOUT=1` gehen die PNGs als Base64 auf stdout
        // (`PNG <name> <base64>`), weil das Terminal den Container der App nicht lesen darf.
        if ProcessInfo.processInfo.environment["AIS_RENDER_STDOUT"] == "1",
           let png = rep.representation(using: .png, properties: [:]) {
            print("PNG \(url.lastPathComponent) \(png.base64EncodedString())")
            return
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        print("geschrieben: \(url.path)")
    }
}

/// Übersicht aller Formen, Augen und Accessoires.
struct MascotGallery: View {
    private func shapeRows(_ shapes: [String], colors: [String], offset: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(0..<((shapes.count + 6) / 7), id: \.self) { row in
                HStack(spacing: 8) {
                    ForEach(Array(shapes.enumerated()).filter { $0.offset / 7 == row }, id: \.offset) { i, s in
                        VStack(spacing: 0) {
                            MascotView(mascot: Mascot(shape: s, color: colors[(i + offset) % colors.count], eyes: "dots", accessory: "none"),
                                       size: 120, seed: s, animated: false, showsGround: true)
                            Text(s).font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                }
            }
        }
    }

    var body: some View {
        let colors = Mascot.palette.map(\.hex)
        VStack(alignment: .leading, spacing: 18) {
            Text("Formen (symmetrisch)").font(.headline).foregroundStyle(.white)
            shapeRows(Mascot.geometricShapes, colors: colors, offset: 2)
            Text("Figuren (organisch)").font(.headline).foregroundStyle(.white)
            shapeRows(Mascot.organicShapes, colors: colors, offset: 4)
            Text("Augen").font(.headline).foregroundStyle(.white)
            HStack(spacing: 8) {
                ForEach(Mascot.eyeStyles, id: \.self) { e in
                    MascotView(mascot: Mascot(shape: "egg", color: "#FF7A30", eyes: e, accessory: "none"),
                               size: 120, seed: e, animated: false, showsGround: true)
                }
            }
            Text("Accessoires").font(.headline).foregroundStyle(.white)
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(120), spacing: 8), count: 7), alignment: .leading, spacing: 4) {
                ForEach(Array(Mascot.accessories.enumerated()), id: \.offset) { i, a in
                    MascotView(mascot: Mascot(shape: Mascot.shapes[i % Mascot.shapes.count], color: colors[(i * 3 + 1) % colors.count],
                                              eyes: Mascot.eyeStyles[i % Mascot.eyeStyles.count], accessory: a),
                               size: 120, seed: a, animated: false, showsGround: true)
                }
            }
            Text("Größen 24 · 36 · 58 · 104 · 160 und Arbeits-Pose").font(.headline).foregroundStyle(.white)
            HStack(alignment: .bottom, spacing: 14) {
                ForEach([24, 36, 58, 104, 160], id: \.self) { s in
                    MascotView(mascot: Mascot(shape: "bean", color: "#8B5CF6", eyes: "dots", accessory: "bowtie"),
                               size: CGFloat(s), seed: "b_mila", animated: false)
                }
                MascotView(mascot: Mascot(shape: "bean", color: "#8B5CF6", eyes: "dots", accessory: "bowtie"),
                           size: 160, mood: .workingStill, seed: "b_mila")
            }
        }
        .padding(28)
        .background(Color(hex: "#121213"))
        .environment(\.theme, .nacht)
    }
}
#endif

#if os(macOS)
/// Matrix: Zeilen = Accessoires, Spalten = alle Formen; darunter jedes Accessoire in Seitenleisten-, Widget- und Profilgröße.
struct AccessoryMatrix: View {
    var theme: Theme
    private let cell: CGFloat = 58

    var body: some View {
        let colors = Mascot.palette.map(\.hex)
        let shapes = Mascot.shapes
        VStack(alignment: .leading, spacing: 18) {
            Text("Accessoires × Formen").font(.system(size: 22, weight: .bold)).foregroundStyle(theme.textPrimary)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    Color.clear.frame(width: 118, height: 1)
                    ForEach(shapes, id: \.self) { s in
                        Text(Mascot.shapeName(s)).font(.system(size: 8.5)).foregroundStyle(theme.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.6).frame(width: cell)
                    }
                }
                ForEach(Array(Mascot.accessories.enumerated()), id: \.offset) { row, acc in
                    HStack(spacing: 2) {
                        Text(Mascot.accessoryName(acc)).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textPrimary)
                            .frame(width: 118, alignment: .leading)
                        ForEach(Array(shapes.enumerated()), id: \.offset) { i, s in
                            MascotView(mascot: Mascot(shape: s, color: colors[(i + row * 5) % colors.count],
                                                      eyes: Mascot.eyeStyles[(i + row) % Mascot.eyeStyles.count], accessory: acc),
                                       size: cell, seed: "\(s)-\(acc)", animated: false)
                                .frame(width: cell, height: cell + 6)
                        }
                    }
                }
            }
            Text("Größen 30 · 44 · 62 · 104 (Seitenleiste, Widget, Profil)").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
            let accs = Mascot.accessories.filter { $0 != "none" }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(290), spacing: 14), count: 5), alignment: .leading, spacing: 10) {
                ForEach(Array(accs.enumerated()), id: \.offset) { i, acc in
                    let m = Mascot(shape: shapes[(i * 7) % shapes.count], color: colors[(i * 3 + 2) % colors.count],
                                   eyes: "dots", accessory: acc)
                    HStack(alignment: .bottom, spacing: 8) {
                        ForEach([30, 44, 62, 104], id: \.self) { s in
                            MascotView(mascot: m, size: CGFloat(s), seed: acc, animated: false)
                        }
                    }
                    .padding(6)
                    .overlay(alignment: .topLeading) {
                        Text(Mascot.accessoryName(acc)).font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                    }
                }
            }
        }
        .padding(28)
        .background(theme.background)
        .environment(\.theme, theme)
    }
}

/// Prüfblatt für ein Accessoire: alle Formen in 104 pt, darunter 30, 44 und 62 pt.
struct AccessoryCheckSheet: View {
    var accessory: String

    var body: some View {
        let colors = Mascot.palette.map(\.hex)
        let shapes = Mascot.shapes
        VStack(alignment: .leading, spacing: 6) {
            Text(Mascot.accessoryName(accessory)).font(.headline).foregroundStyle(.white)
            ForEach(0..<4, id: \.self) { quarter in
                HStack(spacing: 4) {
                    ForEach(Array(shapes.enumerated()).filter { $0.offset / 6 == quarter }, id: \.offset) { i, s in
                        VStack(spacing: 0) {
                            MascotView(mascot: Mascot(shape: s, color: colors[(i * 4 + 3) % colors.count], eyes: "dots", accessory: accessory),
                                       size: 104, seed: s, animated: false)
                            Text(s).font(.system(size: 9)).foregroundStyle(.white.opacity(0.5))
                        }
                        .frame(width: 112)
                    }
                }
            }
            ForEach([30, 30, 44, 44, 62, 62].indices, id: \.self) { k in
                let size = [30, 30, 44, 44, 62, 62][k]
                HStack(spacing: 2) {
                    ForEach(Array(shapes.enumerated()).filter { $0.offset / 12 == k % 2 }, id: \.offset) { i, s in
                        MascotView(mascot: Mascot(shape: s, color: colors[(i * 4 + 3) % colors.count], eyes: "dots", accessory: accessory),
                                   size: CGFloat(size), seed: s, animated: false)
                            .frame(width: 54, height: CGFloat(size) + 8)
                    }
                }
            }
        }
        .padding(16)
        .background(Color(hex: "#121213"))
        .environment(\.theme, .nacht)
    }
}

/// Übersicht aller App-Symbole (groß und in Home-Bildschirm-Größe).
struct AppIconContactSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            Text("AIS Scoops – App-Symbole").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)
            ForEach(AppIconVariant.series, id: \.title) { row in
            Text(row.title).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white.opacity(0.7))
            HStack(alignment: .top, spacing: 28) {
                ForEach(row.variants) { v in
                    VStack(spacing: 12) {
                        AppIconArtwork(variant: v, canvas: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 49, style: .continuous))
                        Text(v.displayName + (v == .gelb ? " (Standard)" : ""))
                            .font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                        HStack(spacing: 12) {
                            ForEach([60, 40, 29], id: \.self) { s in
                                AppIconArtwork(variant: v, canvas: CGFloat(s))
                                    .clipShape(RoundedRectangle(cornerRadius: CGFloat(s) * 0.2245, style: .continuous))
                            }
                        }
                    }
                }
            }
            }
        }
        .padding(40)
        .background(Color(hex: "#2A2A2E"))
    }
}
#endif
