import SwiftUI

/// Wahl im „Erscheinungsbild“: wie das System (Nacht bei Dunkel, Hell bei Hell) oder fest Nacht bzw. Hell.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, nacht, hell

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: "System"
        case .nacht: "Nacht"
        case .hell: "Hell"
        }
    }

    var subtitle: String {
        switch self {
        case .system: "Wechselt mit dem Gerät zwischen Nacht und Hell"
        case .nacht: ThemeKind.nacht.subtitle
        case .hell: ThemeKind.hell.subtitle
        }
    }
}

/// Die beiden Entwürfe (Farben) – „System“ wählt automatisch einen davon.
enum ThemeKind: String, CaseIterable, Identifiable {
    case nacht, hell

    var id: String { rawValue }

    /// Früherer Name „papier“ wird auf „hell“ abgebildet.
    init?(stored raw: String) {
        if raw == "papier" { self = .hell } else if let k = ThemeKind(rawValue: raw) { self = k } else { return nil }
    }

    var displayName: String {
        switch self {
        case .nacht: "Nacht"
        case .hell: "Hell"
        }
    }

    var subtitle: String {
        switch self {
        case .nacht: "Fast schwarz, ruhig, wie ein Messenger bei Nacht"
        case .hell: "Klares, neutrales Weiß – Nacht in hell"
        }
    }

    var theme: Theme {
        switch self {
        case .nacht: .nacht
        case .hell: .hell
        }
    }
}

/// Alle Farben und Maße der Oberfläche als Tokens. Views verwenden ausschließlich diese Werte.
struct Theme: Equatable {
    var kind: ThemeKind
    var colorScheme: ColorScheme

    // Flächen
    var background: Color          // Chat-Hintergrund
    var sidebarBackground: Color   // Seitenleiste
    var inspectorBackground: Color // Profil-Spalte
    var surface: Color             // Karten, Bot-Blasen
    var surfaceRaised: Color       // Eingabefeld, Kapsel oben
    var surfaceBorder: Color
    var userBubble: Color
    var hover: Color
    var selection: Color
    var pinnedTile: Color

    // Text
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var textOnAccent: Color

    // Akzente
    var accent: Color
    var unreadDot: Color
    var success: Color
    var warning: Color
    var danger: Color
    var link: Color

    // Bedienelemente
    var circleButton: Color
    var sendButton: Color
    var sendButtonIcon: Color
    var sendButtonDisabled: Color

    // Schatten
    var cardShadow: Color
    var cardShadowRadius: CGFloat
    var cardShadowY: CGFloat

    // Maskottchen-Umfeld
    var mascotGround: Color        // weicher Bodenschatten unter Maskottchen
    var mascotStage: Color         // Hintergrund der großen Vorschau

    // Gruppierte Listen („inset grouped“ wie die iOS-Einstellungen)
    var groupedBackground: Color   // Hintergrund von Einstellungs-Blättern
    var groupedCard: Color         // Karte einer Sektion

    // Maße
    var sidebarWidth: CGFloat = 280
    var inspectorWidth: CGFloat = 300
    var contentMaxWidth: CGFloat = 560
    var bubbleRadius: CGFloat = 18
    var cardRadius: CGFloat = 16

    /// Erscheinungsbild „System“: kein festes Farbschema setzen, damit Fenster und Sheets dem Gerät folgen
    var followsSystem = false

    /// Für `.preferredColorScheme`: bei „System“ `nil` (das Gerät entscheidet), sonst das Schema des Entwurfs
    var preferredScheme: ColorScheme? { followsSystem ? nil : colorScheme }

    static let nacht = Theme(
        kind: .nacht, colorScheme: .dark,
        background: Color(hex: "#121213"),
        sidebarBackground: Color(hex: "#0B0B0C"),
        inspectorBackground: Color(hex: "#0F0F10"),
        surface: Color(hex: "#1E1E20"),
        surfaceRaised: Color(hex: "#1B1B1D"),
        surfaceBorder: Color.white.opacity(0.07),
        userBubble: Color(hex: "#2E2E31"),
        hover: Color.white.opacity(0.045),
        selection: Color.white.opacity(0.085),
        pinnedTile: Color(hex: "#1A1A1C"),
        textPrimary: Color(hex: "#F2F2F3"),
        textSecondary: Color(hex: "#9A9AA1"),
        textTertiary: Color(hex: "#6A6A70"),
        textOnAccent: .white,
        accent: Color(hex: "#3B8BFF"),
        unreadDot: Color(hex: "#3B8BFF"),
        success: Color(hex: "#3CCB7F"),
        warning: Color(hex: "#FFB020"),
        danger: Color(hex: "#FF5D5D"),
        link: Color(hex: "#7DB3FF"),
        circleButton: Color(hex: "#1E1E20"),
        sendButton: Color(hex: "#F2F2F3"),
        sendButtonIcon: Color(hex: "#0B0B0C"),
        sendButtonDisabled: Color(hex: "#3A3A3D"),
        cardShadow: .clear, cardShadowRadius: 0, cardShadowY: 0,
        mascotGround: Color.black.opacity(0.55),
        mascotStage: Color(hex: "#18181A"),
        groupedBackground: Color(hex: "#0F0F10"),
        groupedCard: Color(hex: "#1C1C1E")
    )

    /// Hell: neutrales Weiß ohne warmen Stich – Nacht invertiert, genauso klar.
    static let hell = Theme(
        kind: .hell, colorScheme: .light,
        background: Color(hex: "#FFFFFF"),
        sidebarBackground: Color(hex: "#F7F7F8"),
        inspectorBackground: Color(hex: "#FAFAFA"),
        surface: Color(hex: "#F2F2F3"),
        surfaceRaised: Color(hex: "#FFFFFF"),
        surfaceBorder: Color(hex: "#E8E8EA"),
        userBubble: Color(hex: "#E4E4E7"),
        hover: Color.black.opacity(0.04),
        selection: Color.black.opacity(0.065),
        pinnedTile: Color(hex: "#FFFFFF"),
        textPrimary: Color(hex: "#111111"),
        textSecondary: Color(hex: "#6B6B70"),
        textTertiary: Color(hex: "#A1A1A6"),
        textOnAccent: .white,
        accent: Color(hex: "#2F6FEB"),
        unreadDot: Color(hex: "#2F6FEB"),
        success: Color(hex: "#1FA35B"),
        warning: Color(hex: "#D98A00"),
        danger: Color(hex: "#E5484D"),
        link: Color(hex: "#2463D6"),
        circleButton: Color(hex: "#FFFFFF"),
        sendButton: Color(hex: "#111111"),
        sendButtonIcon: Color(hex: "#FFFFFF"),
        sendButtonDisabled: Color(hex: "#E4E4E7"),
        cardShadow: Color.black.opacity(0.035), cardShadowRadius: 6, cardShadowY: 1,
        mascotGround: Color.black.opacity(0.2),
        mascotStage: Color(hex: "#F5F5F6"),
        groupedBackground: Color(hex: "#F2F2F4"),
        groupedCard: Color(hex: "#FFFFFF")
    )
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.nacht
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// Karte mit Theme-Fläche, Rand und (im hellen Entwurf) weichem Schatten.
    func themedCard(_ theme: Theme, radius: CGFloat? = nil, fill: Color? = nil) -> some View {
        let r = radius ?? theme.cardRadius
        return self
            .background(fill ?? theme.surface, in: RoundedRectangle(cornerRadius: r, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: r, style: .continuous).strokeBorder(theme.surfaceBorder, lineWidth: 1))
            .shadow(color: theme.cardShadow, radius: theme.cardShadowRadius, y: theme.cardShadowY)
    }
}

// MARK: - Farben aus Hex

extension Color {
    init(hex: String) {
        let rgb = RGB(hex: hex)
        self.init(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: rgb.a)
    }
}

/// Einfacher RGB-Farbwert zum Mischen (Maskottchen-Schattierung).
nonisolated struct RGB: Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double = 1

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.count == 3 { s = s.map { "\($0)\($0)" }.joined() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        if s.count == 8 {
            r = Double((value >> 24) & 0xFF) / 255; g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255; a = Double(value & 0xFF) / 255
        } else if s.count == 6 {
            r = Double((value >> 16) & 0xFF) / 255; g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
        } else {
            r = 0.55; g = 0.36; b = 0.96
        }
    }

    func mix(_ o: RGB, _ t: Double) -> RGB {
        let t = max(0, min(1, t))
        return RGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t, a: a + (o.a - a) * t)
    }

    var luminance: Double { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    /// Gleicher Farbton, Helligkeit × `brightness`, Sättigung + `saturationBoost` (HSB).
    func shaded(brightness: Double, saturationBoost: Double) -> RGB {
        let maxC = max(r, g, b), minC = min(r, g, b), d = maxC - minC
        var h = 0.0
        if d > 0 {
            if maxC == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if maxC == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        let s = maxC == 0 ? 0 : d / maxC
        let v = maxC
        let ns = min(1, s + saturationBoost), nv = v * brightness
        let i = Int(h * 6) % 6, f = h * 6 - floor(h * 6)
        let p = nv * (1 - ns), q = nv * (1 - f * ns), t = nv * (1 - (1 - f) * ns)
        switch i {
        case 0: return RGB(r: nv, g: t, b: p, a: a)
        case 1: return RGB(r: q, g: nv, b: p, a: a)
        case 2: return RGB(r: p, g: nv, b: t, a: a)
        case 3: return RGB(r: p, g: q, b: nv, a: a)
        case 4: return RGB(r: t, g: p, b: nv, a: a)
        default: return RGB(r: nv, g: p, b: q, a: a)
        }
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    func opacity(_ o: Double) -> RGB { RGB(r: r, g: g, b: b, a: o) }

    static let white = RGB(r: 1, g: 1, b: 1)
    static let black = RGB(r: 0, g: 0, b: 0)
}
