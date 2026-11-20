import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Varianten des App-Symbols (Grok-Bot-Stil: großer, angeschnittener Scoop unten links, Blick nach rechts oben).
enum AppIconVariant: String, CaseIterable, Identifiable {
    // Serie „Rund“ (seit 1.1) und Serie „Lässig“ (flauschig, Brauen, Seitenblick)
    case gelb, lila, blau, pink, hell
    case blickGelb, blickLila, blickBlau, blickPink, blickHell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .gelb, .blickGelb: String(localized: "Gelb", comment: "Farbe des App-Symbols")
        case .lila, .blickLila: String(localized: "Lila", comment: "Farbe des App-Symbols")
        case .blau, .blickBlau: String(localized: "Blau", comment: "Farbe des App-Symbols")
        case .pink, .blickPink: String(localized: "Pink", comment: "Farbe des App-Symbols")
        case .hell, .blickHell: String(localized: "Hell", comment: "Farbe des App-Symbols: helle Variante")
        }
    }

    /// Reihen der Auswahl: oben die runde Serie, unten die lässige
    static var series: [(title: String, variants: [AppIconVariant])] {
        [
            (String(localized: "Rund", comment: "Serie der App-Symbole: runde Form"), [.gelb, .lila, .blau, .pink, .hell]),
            (String(localized: "Lässig", comment: "Serie der App-Symbole: lässiger Blick zur Seite"),
             [.blickGelb, .blickLila, .blickBlau, .blickPink, .blickHell]),
        ]
    }

    /// Name des alternativen Symbols im Asset-Katalog (nil = Haupt-Symbol).
    var alternateName: String? {
        switch self {
        case .gelb: nil
        // „-2“: neue Symbole ab 1.1. Neuer Name, weil iOS alte alternative Symbole unter dem
        // bisherigen Namen zwischenspeichert und sonst weiter das alte Bild zeigt.
        case .lila: "AppIcon-Lila-2"
        case .blau: "AppIcon-Blau-2"
        case .pink: "AppIcon-Pink-2"
        case .hell: "AppIcon-Hell-2"
        case .blickGelb: "AppIcon-Blick-Gelb"
        case .blickLila: "AppIcon-Blick-Lila"
        case .blickBlau: "AppIcon-Blick-Blau"
        case .blickPink: "AppIcon-Blick-Pink"
        case .blickHell: "AppIcon-Blick-Hell"
        }
    }

    /// Namen aus Version 1.0 (vor dem neuen Symbol) und das entfernte „Klassisch“ (zurück zu Gelb)
    static let legacyNames: [String: AppIconVariant] = [
        "AppIcon-Lila": .lila, "AppIcon-Blau": .blau, "AppIcon-Pink": .pink, "AppIcon-Hell": .hell,
        "AppIcon-Klassisch": .gelb,
    ]

    init(alternateName: String?) {
        self = AppIconVariant.allCases.first { $0.alternateName == alternateName }
            ?? alternateName.flatMap { AppIconVariant.legacyNames[$0] } ?? .gelb
    }

    var mascotColor: String {
        switch self {
        case .gelb, .hell, .blickGelb, .blickHell: "#FFC83D"
        case .lila, .blickLila: "#8B5CF6"
        case .blau, .blickBlau: "#3D84F5"
        case .pink, .blickPink: "#FF5FA8"
        }
    }

    var lightBackground: Bool { self == .hell || self == .blickHell }
}

/// Gezeichnetes App-Symbol in beliebiger Größe (`canvas` = Kantenlänge in Punkten).
struct AppIconArtwork: View {
    var variant: AppIconVariant = .gelb
    var canvas: CGFloat = 1024
    /// macOS-Raster: abgerundete Fläche mit Rand (824/1024) statt randlos
    var rounded: Bool = false

    var body: some View {
        let inner = rounded ? canvas * 824 / 1024 : canvas
        ZStack {
            if rounded {
                content(size: inner)
                    .frame(width: inner, height: inner)
                    .clipShape(RoundedRectangle(cornerRadius: inner * 0.2245, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: canvas * 0.014, y: canvas * 0.008)
            } else {
                content(size: inner)
            }
        }
        .frame(width: canvas, height: canvas)
        .environment(\.theme, variant.lightBackground ? .hell : .nacht)
    }

    @ViewBuilder
    private func content(size c: CGFloat) -> some View {
        if Self.hasArtwork(variant) {
            // Seit 1.1: fertig gestaltete Symbole (Pillen-Augen, Grok-Stil) aus dem Asset-Katalog
            Image("IconArt-\(variant.rawValue)")
                .resizable()
                .interpolation(.high)
                .frame(width: c, height: c)
        } else {
            cropped(size: c)
        }
    }

    private static func hasArtwork(_ v: AppIconVariant) -> Bool {
        #if canImport(UIKit)
        UIImage(named: "IconArt-\(v.rawValue)") != nil
        #else
        NSImage(named: "IconArt-\(v.rawValue)") != nil
        #endif
    }

    private var background: some View {
        ZStack {
            if variant.lightBackground {
                LinearGradient(colors: [Color(hex: "#FFFDF8"), Color(hex: "#EFEBE3")], startPoint: .topTrailing, endPoint: .bottomLeading)
            } else {
                LinearGradient(colors: [Color(hex: "#24222C"), Color(hex: "#0B0B0C")], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
        }
    }

    /// Grok-Stil: Scoop füllt den größten Teil, Mitte bei ~(35 %, 70 %), links und unten angeschnitten,
    /// Gesicht nach rechts oben verschoben und etwas größer – die Augen sind der Blickfang.
    private func cropped(size c: CGFloat) -> some View {
        let mascot = Mascot(shape: "icon_corner", color: variant.mascotColor, eyes: "ovals", accessory: "none")
        let geo = MascotGeometry.make(shape: "icon_corner")
        // Großer, exakter Kreis mit Mitte nahe der Ecke unten links: Seine rechte obere Rundung
        // ragt weit ins Bild, Oberkante und rechte Kante laufen fast bis an den Rand (wie bei Grok Bot).
        let center = CGPoint(x: Self.cornerCenter.x, y: Self.cornerCenter.y)
        let m = c * Self.cornerRadius / 0.4                      // Form hat Radius 0.4 der Maskottchengröße
        let bodyCenter = CGPoint(x: 0.5, y: 0.5)
        let dx = center.x * c - bodyCenter.x * m
        let dy = center.y * c - bodyCenter.y * m
        // Gesicht mitten in der sichtbaren Fläche, Blick nach rechts oben
        let faceTarget = Self.faceTarget
        let faceShift = CGPoint(x: (faceTarget.x - center.x) * c / m - (geo.faceCenter.x - bodyCenter.x),
                                y: (faceTarget.y - center.y) * c / m - (geo.faceCenter.y - bodyCenter.y))
        return ZStack {
            background
            // Weiches Licht in Blickrichtung (rechts oben)
            RadialGradient(colors: [Color(hex: variant.mascotColor).opacity(variant.lightBackground ? 0.20 : 0.34), .clear],
                           center: UnitPoint(x: 0.72, y: 0.28), startRadius: 0, endRadius: c * 0.6)
        }
        .frame(width: c, height: c)
        // Overlay statt ZStack-Kind: der übergroße Scoop darf die Fläche nicht vergrößern
        .overlay(alignment: .topLeading) {
            MascotView(mascot: mascot, size: m, seed: "app-icon-crop", animated: false,
                       faceShift: faceShift, faceScale: Self.eyeHalfSpacing / (geo.eyeSpacing * m / c), faceTilt: Self.faceTilt, cached: false)
                .frame(width: m, height: m)
                .offset(x: dx, y: dy)
        }
        .frame(width: c, height: c)
        .clipped()
    }

    // Lage im Symbol (Anteile der Kantenlänge)
    // Kreis wie von Arman eingezeichnet: links bei ~35 % Höhe angeschnitten, Scheitel bei ~20 %, rechts bis fast an den Rand
    static let cornerCenter = CGPoint(x: 0.35, y: 0.86)
    static let cornerRadius: CGFloat = 0.60
    static let faceTarget = CGPoint(x: 0.48, y: 0.50)
    static let eyeHalfSpacing: CGFloat = 0.155
    static let faceTilt: Double = -16
}

/// Wechselt das App-Symbol (iOS/iPadOS: alternatives Symbol; macOS: Dock-Symbol, solange die App läuft).
enum AppIconSwitcher {
    private static let key = "appIconVariant"

    static var current: AppIconVariant {
        #if os(iOS)
        return AppIconVariant(alternateName: UIApplication.shared.alternateIconName)
        #else
        return UserDefaults.standard.string(forKey: key).flatMap(AppIconVariant.init(rawValue:)) ?? .gelb
        #endif
    }

    /// Wer noch ein Symbol unter altem Namen gewählt hat, bekommt einmalig das neue Bild derselben Farbe
    /// („Klassisch“ gibt es nicht mehr: zurück zum gelben Standard-Symbol).
    @MainActor
    static func migrateLegacyIcon() async {
        #if os(iOS)
        guard let name = UIApplication.shared.alternateIconName,
              let variant = AppIconVariant.legacyNames[name] else { return }
        try? await UIApplication.shared.setAlternateIconName(variant.alternateName)
        #else
        // macOS: unbekannte gespeicherte Auswahl (z. B. „klassisch“) verwerfen
        if let raw = UserDefaults.standard.string(forKey: key), AppIconVariant(rawValue: raw) == nil {
            UserDefaults.standard.removeObject(forKey: key)
        }
        #endif
    }

    static var supportsAlternateIcons: Bool {
        #if os(iOS)
        return UIApplication.shared.supportsAlternateIcons
        #else
        return true
        #endif
    }

    @MainActor
    static func set(_ variant: AppIconVariant) async -> String? {
        #if os(iOS)
        do {
            try await UIApplication.shared.setAlternateIconName(variant.alternateName)
            return nil
        } catch {
            return String(localized: "Das App-Symbol konnte nicht geändert werden.")
        }
        #else
        UserDefaults.standard.set(variant.rawValue, forKey: key)
        applyDockIcon(variant)
        return nil
        #endif
    }

    #if os(macOS)
    /// Dock-Symbol setzen (nur solange die App läuft; im Finder bleibt das Haupt-Symbol).
    @MainActor
    static func applyDockIcon(_ variant: AppIconVariant? = nil) {
        let v = variant ?? current
        guard v != .gelb else { NSApp.applicationIconImage = nil; return }
        let renderer = ImageRenderer(content: AppIconArtwork(variant: v, canvas: 512, rounded: true))
        renderer.scale = 2
        if let cg = renderer.cgImage {
            NSApp.applicationIconImage = NSImage(cgImage: cg, size: NSSize(width: 512, height: 512))
        }
    }
    #endif
}

/// Auswahl des App-Symbols (Einstellungen → Erscheinungsbild).
struct AppIconPicker: View {
    @Environment(\.theme) private var theme
    @State private var selected: AppIconVariant = AppIconSwitcher.current
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(AppIconVariant.series, id: \.title) { row in
                VStack(alignment: .leading, spacing: 8) {
                    Text(row.title)
                        .appFont(12, weight: .semibold)
                        .foregroundStyle(theme.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(row.variants) { v in
                            iconButton(v)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            if let error {
                Text(error).appFont(12).foregroundStyle(theme.danger)
            }
        }
        .groupedRow(vertical: 14)
    }

    private func iconButton(_ v: AppIconVariant) -> some View {
        Button {
            selected = v
            Task { error = await AppIconSwitcher.set(v) }
        } label: {
            VStack(spacing: 6) {
                AppIconArtwork(variant: v, canvas: 52)
                    .clipShape(RoundedRectangle(cornerRadius: 11.7, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 11.7, style: .continuous)
                        .strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
                    .padding(3)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(selected == v ? theme.accent : .clear, lineWidth: 2.5))
                Text(v.displayName)
                    .appFont(12, weight: selected == v ? .semibold : .regular)
                    .foregroundStyle(selected == v ? theme.textPrimary : theme.textSecondary)
                    .adaptiveLineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(v.rawValue.hasPrefix("blick") ? String(localized: "App-Symbol \(v.displayName), lässig")
                                                          : String(localized: "App-Symbol \(v.displayName)"))
        .accessibilityAddTraits(selected == v ? .isSelected : [])
    }
}
