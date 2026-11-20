import SwiftUI

// MARK: - Layout-Helfer für große Schrift (Dynamic Type)
//
// Ergänzt `AppFont.swift`: Bausteine, damit Zeilen bei großen Stufen umbrechen statt abzuschneiden. Bei Standardgröße
// verhalten sich alle wie das bisherige feste Layout.

/// Knopfzeile: nebeneinander, solange alles in eine Zeile passt, sonst untereinander (z. B. „Freigeben“/„Ablehnen“).
/// Bei Standardgröße und kleiner immer die bisherige HStack.
struct AdaptiveButtonRow<Content: View>: View {
    var spacing: CGFloat = 8
    var alignment: HorizontalAlignment = .leading
    /// Untereinander: Knöpfe gleich breit über die ganze Zeile
    var stretchWhenStacked = false
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        #if os(macOS)
        // Mac: feste Schriftgrößen, Zeile wie bisher
        HStack(spacing: spacing) { content }
        #else
        if dynamicTypeSize <= .large {
            // Standardgröße und kleiner: genau die bisherige Zeile (sie darf stauchen wie vorher)
            HStack(spacing: spacing) { content }
        } else {
            stackingRow
        }
        #endif
    }

    #if !os(macOS)
    private var stackingRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            VStack(alignment: alignment, spacing: spacing) {
                if stretchWhenStacked {
                    Group(subviews: content) { subviews in
                        ForEach(subviews) { $0.frame(maxWidth: .infinity) }
                    }
                } else {
                    content
                }
            }
            // Platzhalter (`Spacer`) der Zeile werden untereinander zu kleinen Abständen statt die Höhe zu füllen
            .fixedSize(horizontal: false, vertical: true)
        }
    }
    #endif
}

/// HStack, die ab einer Stufe (Standard: Bedienungshilfen-Größen) zur VStack wird.
struct AdaptiveStack<Content: View>: View {
    var horizontalAlignment: HorizontalAlignment = .leading
    var verticalAlignment: VerticalAlignment = .center
    var spacing: CGFloat? = nil
    /// Ab dieser Stufe untereinander
    var stackFrom: DynamicTypeSize = .accessibility1
    @ViewBuilder var content: Content
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize >= stackFrom
            ? AnyLayout(VStackLayout(alignment: horizontalAlignment, spacing: spacing))
            : AnyLayout(HStackLayout(alignment: verticalAlignment, spacing: spacing))
        layout { content }
    }
}

/// Listenzeile „Inhalt links, Bedienelement rechts“: ab den Bedienungshilfen-Größen steht das Bedienelement unter dem
/// Inhalt (eingerückt), damit Titel nicht auf wenige Buchstaben schrumpfen. Darunter eine normale Zeile mit `Spacer`.
struct AdaptiveRow<Leading: View, Trailing: View>: View {
    /// Abstand in der Zeile (HStack) bzw. untereinander
    var spacing: CGFloat = 8
    var stackedSpacing: CGFloat = 8
    /// Mindestabstand des `Spacer` zwischen Inhalt und Bedienelement
    var minSpacer: CGFloat = 8
    var stackFrom: DynamicTypeSize = .accessibility1
    /// Einrückung des Bedienelements, wenn es unter dem Inhalt steht (z. B. Breite des Symbols plus Abstand)
    var trailingIndent: CGFloat = 0
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize >= stackFrom {
            VStack(alignment: .leading, spacing: stackedSpacing) {
                leading
                trailing.padding(.leading, trailingIndent)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(spacing: spacing) {
                leading
                Spacer(minLength: minSpacer)
                trailing
            }
        }
    }
}

/// Fließ-Layout: Elemente nebeneinander, Umbruch in die nächste Zeile bei Platzmangel. Ein Element, das allein zu
/// breit ist, bekommt die volle Zeilenbreite angeboten (Text bricht dann darin um).
struct FlowRow: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    private func size(of s: LayoutSubview, maxWidth: CGFloat) -> CGSize {
        let ideal = s.sizeThatFits(.unspecified)
        guard ideal.width > maxWidth else { return ideal }
        return s.sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let size = size(of: s, maxWidth: maxWidth)
            if x > 0, x + size.width > maxWidth {
                y += lineHeight + lineSpacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            width = max(width, x - spacing)
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: min(width, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for s in subviews {
            let size = size(of: s, maxWidth: bounds.width)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + lineSpacing
                x = bounds.minX
                lineHeight = 0
            }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct ScaledFrame: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let width: CGFloat?
    let height: CGFloat?
    let style: Font.TextStyle
    let alignment: Alignment

    func body(content: Content) -> some View {
        content.frame(width: width.map { AppFont.scaled($0, relativeTo: style, in: dynamicTypeSize) },
                      height: height.map { AppFont.scaled($0, relativeTo: style, in: dynamicTypeSize) },
                      alignment: alignment)
    }
}

private struct ScaledMinFrame: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let minWidth: CGFloat?
    let minHeight: CGFloat?
    let style: Font.TextStyle
    let alignment: Alignment

    func body(content: Content) -> some View {
        content.frame(minWidth: minWidth.map { AppFont.scaled($0, relativeTo: style, in: dynamicTypeSize) },
                      minHeight: minHeight.map { AppFont.scaled($0, relativeTo: style, in: dynamicTypeSize) },
                      alignment: alignment)
    }
}

private struct AdaptiveLineLimit: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let limit: Int?
    let large: Int?
    let accessibility: Int?

    func body(content: Content) -> some View {
        let n: Int? = if dynamicTypeSize.isAccessibilitySize { accessibility }
            else if dynamicTypeSize > .large { large }
            else { limit }
        content.lineLimit(n)
    }
}

private struct FixedSizeUnlessAccessibility: ViewModifier {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        content.fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: dynamicTypeSize.isAccessibilitySize)
    }
}

extension View {
    /// `.fixedSize()` (nie kürzen) bis zur größten normalen Stufe; bei Bedienungshilfen-Größen darf der Text umbrechen.
    func fixedSizeUnlessAccessibility() -> some View {
        modifier(FixedSizeUnlessAccessibility())
    }

    /// Fester Rahmen, der mit der Schrift wächst (Symbolkreise, Knopfgrößen). Bei Standardgröße genau `width`×`height`.
    func scaledFrame(width: CGFloat? = nil, height: CGFloat? = nil, relativeTo style: Font.TextStyle = .body,
                     alignment: Alignment = .center) -> some View {
        modifier(ScaledFrame(width: width, height: height, style: style, alignment: alignment))
    }

    /// Quadratischer Rahmen, der mit der Schrift wächst.
    func scaledFrame(_ side: CGFloat, relativeTo style: Font.TextStyle = .body) -> some View {
        modifier(ScaledFrame(width: side, height: side, style: style, alignment: .center))
    }

    /// Mindestmaße, die mit der Schrift wachsen (Zeilenhöhen).
    func scaledMinFrame(minWidth: CGFloat? = nil, minHeight: CGFloat? = nil, relativeTo style: Font.TextStyle = .body,
                        alignment: Alignment = .center) -> some View {
        modifier(ScaledMinFrame(minWidth: minWidth, minHeight: minHeight, style: style, alignment: alignment))
    }

    /// `lineLimit`, das bei großer Schrift mehr Zeilen erlaubt, damit nichts verloren geht.
    /// Standard: über „Groß“ doppelt, bei Bedienungshilfen-Größen dreimal so viele Zeilen (Vorschauen bleiben
    /// überschaubar); `accessibility: .max` für unbegrenzt.
    func adaptiveLineLimit(_ limit: Int?, large: Int? = nil, accessibility: Int? = nil) -> some View {
        modifier(AdaptiveLineLimit(limit: limit, large: large ?? limit.map { $0 * 2 },
                                   accessibility: accessibility == .max ? nil : (accessibility ?? limit.map { $0 * 3 })))
    }
}
