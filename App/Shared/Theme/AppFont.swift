import SwiftUI
#if os(iOS) || os(visionOS)
import UIKit
#endif

// MARK: - Schrift, die der Systemeinstellung folgt (Dynamic Type)
//
// Regel (siehe App/README.md, Abschnitt „Schriftgröße“):
// - Text und Symbole neben Text: `.appFont(15, weight: .semibold)` statt `.font(.system(size: 15, weight: .semibold))`.
//   Die Zahl ist die Größe bei der Standardeinstellung („Groß“); dort sieht alles aus wie mit fester Größe.
//   Bei anderen Einstellungen wächst oder schrumpft die Größe wie der nächstliegende Textstil des Systems
//   (13 → `.footnote`, 15 → `.subheadline`, 17 → `.body` …), auf Wunsch mit `relativeTo:` fest vorgegeben.
// - Wo ein `Font`-Wert gebraucht wird (Text-Verkettung, AttributedString, Markdown): `Font.app(15, in: dynamicTypeSize)`
//   mit `@Environment(\.dynamicTypeSize)`.
// - Maße, die mit der Schrift wachsen sollen (Höhen, Symbolrahmen, Abstände): `@AppMetric private var h: CGFloat = 44`.
// - Dekoration, Figuren und aus der Geometrie abgeleitete Größen bleiben fest: `.font(.fixed(size * 0.44))`.
// - Dichte Bedienelemente deckeln mit `.dynamicTypeSize(...AppFont.controlCap)` (bzw. `.compactCap`).
// - macOS und watchOS: unverändert feste Größen (das Mac-Design ist abgestimmt, die Uhr hat eigene Schriften).

nonisolated enum AppFont {
    /// Obergrenze für dichte Bedienelemente (Symbolleisten, runde Knöpfe, Reiter, Zähler): größte normale Stufe.
    static let controlCap: DynamicTypeSize = .xxxLarge
    /// Obergrenze für sehr enge Stellen (Abzeichen, Mini-Zähler auf Avataren): zwei Stufen über Standard.
    static let compactCap: DynamicTypeSize = .xxLarge

    /// Textstil, dessen Standardgröße der festen Größe am nächsten liegt.
    static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: .caption2      // 11
        case ..<12.5: .caption       // 12
        case ..<14: .footnote        // 13
        case ..<15.75: .subheadline  // 15
        case ..<16.75: .callout      // 16
        case ..<18.5: .body          // 17
        case ..<21: .title3          // 20
        case ..<25: .title2          // 22
        case ..<31: .title           // 28
        default: .largeTitle         // 34
        }
    }

    /// Größe bei der gewählten Systemstufe. Bei „Groß“ (Standard) und auf macOS/watchOS genau `size`.
    static func scaled(_ size: CGFloat, relativeTo style: Font.TextStyle? = nil, in dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        #if os(iOS) || os(visionOS)
        guard dynamicTypeSize != .large else { return size }
        let metrics = UIFontMetrics(forTextStyle: uiTextStyle(style ?? textStyle(for: size)))
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(dynamicTypeSize))
        return metrics.scaledValue(for: size, compatibleWith: traits)
        #else
        return size
        #endif
    }

    /// Systemschrift, skaliert für die Stufe. Gleiche Parameter wie `Font.system(size:weight:design:)`.
    static func font(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil,
                     relativeTo style: Font.TextStyle? = nil, in dynamicTypeSize: DynamicTypeSize) -> Font {
        .system(size: scaled(size, relativeTo: style, in: dynamicTypeSize), weight: weight, design: design)
    }

    #if os(iOS) || os(visionOS)
    private static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .body: .body
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        @unknown default: .body
        }
    }
    #endif
}

extension Font {
    /// Systemschrift, die mit der Systemeinstellung wächst; für Stellen, die einen `Font`-Wert brauchen.
    /// In Views lieber `.appFont(…)` verwenden, das liest die Stufe selbst.
    static func app(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil,
                    relativeTo style: Font.TextStyle? = nil, in dynamicTypeSize: DynamicTypeSize) -> Font {
        AppFont.font(size, weight: weight, design: design, relativeTo: style, in: dynamicTypeSize)
    }

    /// Feste Größe, wächst nicht mit: nur für Dekoration, Figuren und aus der Geometrie abgeleitete Größen.
    static func fixed(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        .system(size: size, weight: weight, design: design)
    }
}

private struct AppFontModifier: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let size: CGFloat
    let weight: Font.Weight?
    let design: Font.Design?
    let style: Font.TextStyle?

    func body(content: Content) -> some View {
        content.font(AppFont.font(size, weight: weight, design: design, relativeTo: style, in: dynamicTypeSize))
    }
}

extension View {
    /// Systemschrift mit `size` pt bei Standardgröße, die mit der Schriftgröße des Systems wächst und schrumpft.
    func appFont(_ size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil,
                 relativeTo style: Font.TextStyle? = nil) -> some View {
        modifier(AppFontModifier(size: size, weight: weight, design: design, style: style))
    }
}

/// Wie `@ScaledMetric`, aber auf macOS/watchOS fest und mit derselben Kurve wie `appFont`:
/// `@AppMetric private var rowHeight: CGFloat = 44` oder `@AppMetric(relativeTo: .footnote) private var badge: CGFloat = 18`.
@propertyWrapper
struct AppMetric: DynamicProperty {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let base: CGFloat
    private let style: Font.TextStyle

    init(wrappedValue: CGFloat, relativeTo style: Font.TextStyle = .body) {
        base = wrappedValue
        self.style = style
    }

    var wrappedValue: CGFloat { AppFont.scaled(base, relativeTo: style, in: dynamicTypeSize) }
}

extension DynamicTypeSize {
    /// Startargument `-dynamictype <stufe>` (Debug, Screenshots): `xSmall` … `xxxLarge`, `accessibility1` … `accessibility5`,
    /// auch kurz `ax1` … `ax5`. Setzt die Stufe an der Wurzel der App.
    static var launchOverride: DynamicTypeSize? {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-dynamictype"), i + 1 < args.count else { return nil }
        let raw = args[i + 1].lowercased().replacingOccurrences(of: "accessibility", with: "ax")
        let all: [(String, DynamicTypeSize)] = [
            ("xsmall", .xSmall), ("small", .small), ("medium", .medium), ("large", .large), ("xlarge", .xLarge),
            ("xxlarge", .xxLarge), ("xxxlarge", .xxxLarge), ("ax1", .accessibility1), ("ax2", .accessibility2),
            ("ax3", .accessibility3), ("ax4", .accessibility4), ("ax5", .accessibility5),
        ]
        return all.first { $0.0 == raw }?.1
        #else
        return nil
        #endif
    }
}

extension View {
    /// Wendet `-dynamictype <stufe>` an (nur Debug); sonst unverändert.
    @ViewBuilder func launchDynamicTypeOverride() -> some View {
        if let size = DynamicTypeSize.launchOverride { dynamicTypeSize(size) } else { self }
    }
}
