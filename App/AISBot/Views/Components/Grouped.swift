import SwiftUI

// Einheitliches „inset grouped“-Layout (wie die iOS-Einstellungen) für Profil, Einstellungen,
// Initiative, Tresor usw.: Sektion = abgerundete Karte, Haarlinien zwischen Zeilen,
// kleine Überschrift darüber, optionaler Fußtext darunter.

enum GroupedMetrics {
    static let cornerRadius: CGFloat = 18
    static let rowInset: CGFloat = 16
    static let rowMinHeight: CGFloat = 44
    static let sectionSpacing: CGFloat = 26
}

/// Abschnitt mit Überschrift, Karte und Fußtext. Zwischen die Zeilen werden automatisch Trennlinien gesetzt.
struct GroupedSection<Content: View>: View {
    var header: String?
    var footer: String?
    /// Einrückung der Trennlinien (z. B. hinter einem Symbol)
    var dividerInset: CGFloat = GroupedMetrics.rowInset
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    /// Überschrift und Fußtext als übersetzbare Texte (Literale landen im String Catalog).
    init(_ header: LocalizedStringResource? = nil, footer: LocalizedStringResource? = nil,
         dividerInset: CGFloat = GroupedMetrics.rowInset, @ViewBuilder content: () -> Content) {
        self.header = header.map { String(localized: $0) }
        self.footer = footer.map { String(localized: $0) }
        self.dividerInset = dividerInset
        self.content = content()
    }

    /// Überschrift und Fußtext als fertige Texte (schon übersetzt oder vom Server).
    @_disfavoredOverload
    init(_ header: String? = nil, footer: String? = nil, dividerInset: CGFloat = GroupedMetrics.rowInset,
         @ViewBuilder content: () -> Content) {
        self.header = header
        self.footer = footer
        self.dividerInset = dividerInset
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if let header {
                Text(header.uppercased())
                    .appFont(12, weight: .semibold)
                    .tracking(0.4)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, GroupedMetrics.rowInset)
                    .accessibilityAddTraits(.isHeader)
            }
            VStack(spacing: 0) {
                Group(subviews: content) { rows in
                    ForEach(rows.indices, id: \.self) { i in
                        if i > 0 { GroupedDivider(inset: dividerInset) }
                        rows[i]
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.groupedCard, in: RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: GroupedMetrics.cornerRadius, style: .continuous)
                .strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
            if let footer {
                Text(footer)
                    .appFont(12.5)
                    .foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, GroupedMetrics.rowInset)
            }
        }
    }
}

struct GroupedDivider: View {
    var inset: CGFloat = GroupedMetrics.rowInset
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle()
            .fill(theme.surfaceBorder)
            .frame(height: 1 / max(scale, 1))
            .padding(.leading, inset)
    }
}

extension View {
    /// Standardzeile: einheitliche Innenabstände, mindestens 44 pt hoch, ganze Fläche antippbar.
    func groupedRow(vertical: CGFloat = 11) -> some View {
        self
            .padding(.horizontal, GroupedMetrics.rowInset)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, minHeight: GroupedMetrics.rowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
    }
}

/// Zeile mit Symbol, Titel, optionalem Untertitel und Inhalt rechts (Wert, Schalter, Pfeil …).
struct GroupedLabelRow<Trailing: View>: View {
    var icon: String?
    var iconColor: Color?
    var title: String
    var subtitle: String?
    var titleColor: Color?
    @ViewBuilder var trailing: Trailing
    @Environment(\.theme) private var theme

    /// Titel und Untertitel als übersetzbare Texte (Literale landen im String Catalog).
    init(icon: String? = nil, iconColor: Color? = nil, title: LocalizedStringResource,
         subtitle: LocalizedStringResource? = nil, titleColor: Color? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.icon = icon; self.iconColor = iconColor; self.title = String(localized: title)
        self.subtitle = subtitle.map { String(localized: $0) }
        self.titleColor = titleColor; self.trailing = trailing()
    }

    /// Titel und Untertitel als fertige Texte (schon übersetzt oder vom Server).
    @_disfavoredOverload
    init(icon: String? = nil, iconColor: Color? = nil, title: String, subtitle: String? = nil, titleColor: Color? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.icon = icon; self.iconColor = iconColor; self.title = title; self.subtitle = subtitle
        self.titleColor = titleColor; self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            if let icon {
                Image(systemName: icon)
                    .appFont(15, weight: .medium)
                    .foregroundStyle(iconColor ?? theme.textSecondary)
                    .scaledFrame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .appFont(15)
                    .foregroundStyle(titleColor ?? theme.textPrimary)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .appFont(12.5)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            trailing
        }
        .groupedRow()
    }
}

/// Pfeil rechts für Zeilen, die etwas öffnen.
struct DisclosureChevron: View {
    @Environment(\.theme) private var theme
    var body: some View {
        Image(systemName: "chevron.right")
            .appFont(12, weight: .semibold)
            .foregroundStyle(theme.textTertiary)
    }
}

/// Kopf eines Blatts: Titel links, Schließen rechts, sauberer Abstand, Trennlinie.
struct SheetHeader<Trailing: View>: View {
    var title: String
    var icon: String?
    @ViewBuilder var trailing: Trailing
    var onClose: () -> Void
    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(_ title: LocalizedStringResource, icon: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         onClose: @escaping () -> Void) {
        self.title = String(localized: title); self.icon = icon; self.trailing = trailing(); self.onClose = onClose
    }

    /// Titel als fertiger Text (schon übersetzt oder Name).
    @_disfavoredOverload
    init(_ title: String, icon: String? = nil, @ViewBuilder trailing: () -> Trailing = { EmptyView() },
         onClose: @escaping () -> Void) {
        self.title = title; self.icon = icon; self.trailing = trailing(); self.onClose = onClose
    }

    var body: some View {
        // Große Schrift (Bedienungshilfen): Zusatzknöpfe in eine eigene Zeile unter den Titel, damit der Titel Platz hat
        let stacked = dynamicTypeSize.isAccessibilitySize && !(Trailing.self == EmptyView.self)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let icon {
                    Image(systemName: icon).appFont(15, weight: .semibold).foregroundStyle(theme.textSecondary)
                }
                Text(title).appFont(17, weight: .semibold).foregroundStyle(theme.textPrimary)
                Spacer()
                if !stacked { trailing }
                CircleIconButton(systemName: "xmark", help: String(localized: "Schließen"), size: 30, action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            if stacked { trailing }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }
}

/// Senkrechter Stapel von Sektionen mit großzügigem Abstand.
struct GroupedStack<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: GroupedMetrics.sectionSpacing) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
