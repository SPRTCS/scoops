import Charts
import SwiftUI

// Diagramm, Tabelle und Limit-Karten der Seite „Nutzung und Verbrauch“.

enum UsageMetric { case cost, tokens }

/// Verlauf pro Anbieter: breit als Flächen-/Linienkurve, schmal als gestapelte Balken.
struct UsageTrendChart: View {
    enum Style { case area, bars }
    let points: [UsageDetails.Point]
    let metric: UsageMetric
    let palette: UsagePalette
    let theme: Theme
    let style: Style
    var hourly = false
    @State private var selected: String?

    private struct Entry: Identifiable {
        let key: String, label: String, provider: UsageProvider, value: Double
        var id: String { key + provider.rawValue }
    }

    private var entries: [Entry] {
        points.flatMap { p in
            UsageProvider.allCases.map { prov in
                let part = p.part(prov)
                return Entry(key: p.key, label: p.label, provider: prov,
                             value: metric == .cost ? part.costUsd : Double(part.tokens))
            }
        }
    }

    private var axisKeys: [String] {
        guard let first = points.first?.key, let last = points.last?.key else { return [] }
        if style == .bars { return [first, last] }
        let mid = points[points.count / 2].key
        return [first, mid, last]
    }

    private func label(for key: String) -> String {
        guard let p = points.first(where: { $0.key == key }) else { return key }
        if hourly { return p.label }
        // „19. Okt.“ statt „19.10.“ wie bei T3
        if let d = UsageFormat.dayFormatter.date(from: key) {
            return d.formatted(.dateTime.day().month(.abbreviated).locale(UsageFormat.locale))
        }
        return p.label
    }

    private func format(_ v: Double, axis: Bool = false) -> String {
        if metric == .cost { return axis ? UsageFormat.axisUsd(v) : UsageFormat.usd(v) }
        return axis ? UsageFormat.axisTokens(v) : UsageFormat.tokens(Int(v))
    }

    var body: some View {
        if style == .bars {
            VStack(spacing: 6) {
                styled
                HStack {
                    Text(points.first.map { label(for: $0.key) } ?? "")
                    Spacer()
                    Text(points.last.map { label(for: $0.key) } ?? "")
                }
                .appFont(13).foregroundStyle(theme.textSecondary)
            }
        } else {
            styled
        }
    }

    private var styled: some View {
        chart
            .chartForegroundStyleScale(domain: UsageProvider.allCases.map(\.rawValue),
                                       range: UsageProvider.allCases.map { palette.color($0) })
            .chartLegend(.hidden)
            .chartXAxis {
                AxisMarks(values: points.map(\.key)) { v in
                    if style == .area, let k = v.as(String.self), axisKeys.contains(k) {
                        AxisValueLabel(anchor: anchor(for: k), collisionResolution: .disabled) {
                            Text(style == .area ? label(for: k).uppercased() : label(for: k))
                                .appFont(style == .area ? 11 : 13, weight: style == .area ? .medium : .regular)
                                .foregroundStyle(theme.textSecondary)
                                .fixedSize()
                        }
                    }
                }
            }
            .chartYAxis {
                if style == .area {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { v in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(theme.surfaceBorder)
                        AxisValueLabel {
                            if let d = v.as(Double.self) {
                                Text(format(d, axis: true)).appFont(11).foregroundStyle(theme.textSecondary)
                            }
                        }
                    }
                } else {
                    AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3])).foregroundStyle(theme.surfaceBorder)
                    }
                }
            }
            // Auswahl mit Tooltip nur im breiten Diagramm: auf dem iPhone würde die Geste das Scrollen schlucken
            .chartXSelection(value: style == .area ? $selected : .constant(nil))
            .accessibilityLabel(metric == .cost ? "Kostenverlauf" : "Tokenverlauf")
    }

    private func anchor(for key: String?) -> UnitPoint {
        guard let key else { return .top }
        if key == points.first?.key { return .topLeading }
        if key == points.last?.key { return .topTrailing }
        return .top
    }

    @ViewBuilder
    private var chart: some View {
        switch style {
        case .area:
            Chart {
                ForEach(entries) { e in
                    AreaMark(x: .value("Zeit", e.key), y: .value("Wert", e.value), stacking: .unstacked)
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Anbieter", e.provider.rawValue))
                        .opacity(0.13)
                    LineMark(x: .value("Zeit", e.key), y: .value("Wert", e.value))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(by: .value("Anbieter", e.provider.rawValue))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if let selected, let p = points.first(where: { $0.key == selected }) {
                    RuleMark(x: .value("Zeit", selected))
                        .foregroundStyle(theme.textTertiary)
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .annotation(position: .top, spacing: 4,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(p) }
                }
            }
        case .bars:
            Chart {
                ForEach(entries) { e in
                    BarMark(x: .value("Zeit", e.key), y: .value("Wert", e.value), width: .ratio(0.62))
                        .foregroundStyle(by: .value("Anbieter", e.provider.rawValue))
                }
                if let selected, let p = points.first(where: { $0.key == selected }) {
                    RuleMark(x: .value("Zeit", selected))
                        .foregroundStyle(.clear)
                        .annotation(position: .top, spacing: 0,
                                    overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) { tooltip(p) }
                }
            }
        }
    }

    private func tooltip(_ p: UsageDetails.Point) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label(for: p.key)).appFont(12.5, weight: .medium).foregroundStyle(theme.textSecondary)
            ForEach(UsageProvider.allCases.reversed()) { prov in
                HStack(spacing: 6) {
                    Circle().fill(palette.color(prov)).frame(width: 7, height: 7)
                    Text(prov == .claude ? "Claude" : "OpenAI").appFont(12.5).foregroundStyle(theme.textSecondary)
                    Spacer(minLength: 12)
                    Text(format(metric == .cost ? p.part(prov).costUsd : Double(p.part(prov).tokens)))
                        .appFont(12.5, weight: .medium).monospacedDigit().foregroundStyle(theme.textPrimary)
                }
            }
            Divider()
            HStack {
                Text("Gesamt").appFont(12.5).foregroundStyle(theme.textSecondary)
                Spacer(minLength: 12)
                Text(format(metric == .cost ? p.costUsd : Double(p.tokens)))
                    .appFont(12.5, weight: .semibold).monospacedDigit().foregroundStyle(theme.textPrimary)
            }
        }
        .padding(10)
        .frame(width: 190)
        .background(theme.groupedCard, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 8, y: 2)
    }
}

extension UsageFormat {
    static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}

/// Aufschlüsselung als Tabelle (#, Name mit Anteilsstrich in Anbieterfarbe, Kosten, Anteil, Tokens)
struct UsageTable: View {
    let rows: [UsageDetails.Row]
    let isCost: Bool
    let wide: Bool
    let palette: UsagePalette
    let theme: Theme
    var numbered = true
    var nameTitle = String(localized: "Modell")

    var body: some View {
        VStack(spacing: 0) {
            if wide {
                HStack(spacing: 12) {
                    if numbered { Text("#").frame(width: 22, alignment: .leading) }
                    Text(nameTitle).frame(maxWidth: .infinity, alignment: .leading)
                    Text("Kosten").frame(width: 110, alignment: .trailing)
                    Text("Anteil").frame(width: 70, alignment: .trailing)
                    Text("Tokens").frame(width: 90, alignment: .trailing)
                }
                .appFont(13).foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 12).padding(.vertical, 10)
                Rectangle().fill(theme.surfaceBorder).frame(height: 0.5)
            }
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                if i > 0 { Rectangle().fill(theme.surfaceBorder).frame(height: 0.5).padding(.leading, wide ? 0 : 16) }
                if wide { wideRow(i, r) } else { compactRow(i, r) }
            }
        }
        .background {
            if !wide {
                RoundedRectangle(cornerRadius: 22, style: .continuous).fill(theme.groupedCard)
                    .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
            }
        }
    }

    private func share(_ r: UsageDetails.Row) -> Double { isCost ? r.shareCost : r.shareTokens }
    private var maxShare: Double { max(rows.map(share).max() ?? 1, 0.0001) }

    private func nameCell(_ r: UsageDetails.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if r.provider != nil {
                    Circle().fill(palette.color(r.provider)).frame(width: 8, height: 8)
                }
                Text(r.label).appFont(15).foregroundStyle(theme.textPrimary).adaptiveLineLimit(1)
                if r.priceEstimated == true {
                    Text("Preis geschätzt").appFont(11).foregroundStyle(theme.textTertiary)
                }
                if r.apiUsd > 0.005 && isCost {
                    Text("API \(UsageFormat.usd(r.apiUsd))").appFont(11, weight: .medium)
                        .foregroundStyle(palette.api)
                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                        .background(palette.api.opacity(0.12), in: Capsule())
                        .adaptiveLineLimit(1)
                }
            }
            GeometryReader { g in
                Capsule().fill(r.provider != nil ? palette.color(r.provider) : theme.textTertiary)
                    .frame(width: max(3, g.size.width * share(r) / maxShare), height: 2)
            }
            .frame(height: 2)
            .frame(maxWidth: wide ? 320 : .infinity, alignment: .leading)
        }
    }

    private func wideRow(_ i: Int, _ r: UsageDetails.Row) -> some View {
        HStack(spacing: 12) {
            if numbered {
                Text("\(i + 1)").appFont(13.5).foregroundStyle(theme.textSecondary).frame(width: 22, alignment: .leading)
            }
            nameCell(r).frame(maxWidth: .infinity, alignment: .leading)
            Text(UsageFormat.usd(r.costUsd)).appFont(15).monospacedDigit().foregroundStyle(theme.textPrimary)
                .frame(width: 110, alignment: .trailing)
            Text(UsageFormat.percent(share(r))).appFont(15).monospacedDigit().foregroundStyle(theme.textSecondary)
                .frame(width: 70, alignment: .trailing)
            Text(UsageFormat.tokens(r.tokens)).appFont(15).monospacedDigit().foregroundStyle(theme.textSecondary)
                .frame(width: 90, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func compactRow(_ i: Int, _ r: UsageDetails.Row) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                nameCell(r)
                Spacer(minLength: 8)
                Text(isCost ? UsageFormat.usd(r.costUsd) : UsageFormat.tokens(r.tokens))
                    .appFont(15, weight: .medium).monospacedDigit().foregroundStyle(theme.textPrimary)
                    .adaptiveLineLimit(1)
            }
            Text(isCost ? "\(UsageFormat.percent(share(r))) · \(UsageFormat.tokens(r.tokens)) Tokens"
                        : "\(UsageFormat.percent(share(r))) · \(UsageFormat.usd(r.costUsd))")
                .appFont(12.5).foregroundStyle(theme.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Karte eines Abo-Fensters: „x % übrig“, Zeit bis zum Reset, Balken (übrig gefüllt, verbraucht schraffiert) mit
/// Tempo-Markierung (wo man bei gleichmäßigem Verbrauch stünde) und „unter/über Tempo“.
struct LimitCard: View {
    let window: UsageLimits.Window
    let provider: UsageLimits.Provider
    let now: Date
    let wide: Bool
    let palette: UsagePalette
    let theme: Theme
    var showExtras = false

    private var used: Double { min(100, max(0, window.usedPercent ?? 0)) }
    private var left: Double { 100 - used }
    private var resets: Date? { UsageFormat.date(window.resetsAt) }
    private var span: TimeInterval { TimeInterval((window.windowMinutes ?? 10080) * 60) }

    /// Erwarteter Verbrauch bei gleichmäßigem Tempo (0–100), nil ohne Rücksetzzeit
    private var expectedUsed: Double? {
        guard let resets else { return nil }
        let remaining = max(0, min(span, resets.timeIntervalSince(now)))
        return (1 - remaining / span) * 100
    }

    private enum Pace { case under, on, over }
    private var pace: Pace? {
        guard let e = expectedUsed else { return nil }
        if used < e - 3 { return .under }
        if used > e + 3 { return .over }
        return .on
    }

    private var paceText: String? {
        switch pace {
        case .under: String(localized: "Unter Tempo", comment: "Abo-Limit: Verbrauch langsamer als gleichmäßig")
        case .on: String(localized: "Im Tempo", comment: "Abo-Limit: Verbrauch wie gleichmäßig")
        case .over: String(localized: "Über Tempo", comment: "Abo-Limit: Verbrauch schneller als gleichmäßig")
        case nil: nil
        }
    }

    private var paceColor: Color {
        switch pace {
        case .over: theme.warning
        default: theme.textSecondary
        }
    }

    private var fill: Color {
        provider.id == "claude" ? palette.claude.opacity(theme.colorScheme == .dark ? 0.45 : 0.32)
            : (theme.colorScheme == .dark ? Color(hex: "#5A5A60") : Color(hex: "#B4B4B8"))
    }
    private var hatch: Color {
        provider.id == "claude" ? palette.claude.opacity(0.35) : theme.textTertiary.opacity(0.55)
    }

    private var resetText: String? {
        guard let resets else { return nil }
        let s = resets.timeIntervalSince(now)
        return s <= 0 ? String(localized: "jetzt", comment: "Abo-Limit: Reset steht sofort an") : UsageFormat.remaining(s)
    }

    private var extrasText: String? {
        guard showExtras, let n = provider.extra?.resetCredits, n > 0 else { return nil }
        return "\(n)"
    }

    var body: some View {
        UsageCard {
            if wide {
                HStack(alignment: .center, spacing: 28) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(window.label).appFont(15, weight: .medium).foregroundStyle(theme.textPrimary)
                        percentLine
                        if let paceText {
                            Text(paceText).appFont(12.5).foregroundStyle(paceColor)
                        }
                    }
                    .frame(width: 210, alignment: .leading)
                    bar(height: 42, overlayInfo: true)
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(window.label).appFont(16, weight: .medium).foregroundStyle(theme.textPrimary)
                        Spacer()
                        if let paceText { Text(paceText).appFont(14).foregroundStyle(paceColor) }
                    }
                    percentLine
                    if let resetText {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise").appFont(11, weight: .semibold)
                            Text("+\(Int(used.rounded())) % in \(resetText)")
                            if let extrasText {
                                Text("·")
                                Image(systemName: "ticket").appFont(11)
                                Text(extrasText)
                            }
                        }
                        .appFont(13.5).foregroundStyle(theme.textSecondary)
                    }
                    bar(height: 34, overlayInfo: false)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        let percent = Int(left.rounded())
        var parts = [String(localized: "\(provider.label), \(window.label): \(percent) Prozent übrig")]
        if let resetText { parts.append(String(localized: "Reset in \(resetText)")) }
        if let paceText { parts.append(paceText) }
        return parts.joined(separator: ", ")
    }

    private var percentLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(Int(left.rounded())) %").appFont(wide ? 40 : 38, weight: .bold).monospacedDigit()
                .foregroundStyle(theme.textPrimary)
            Text("übrig").appFont(16).foregroundStyle(theme.textSecondary)
            if let pace {
                Image(systemName: pace == .over ? "chart.line.uptrend.xyaxis" : "chart.line.downtrend.xyaxis")
                    .appFont(12, weight: .semibold).foregroundStyle(paceColor)
            }
        }
    }

    private func bar(height: CGFloat, overlayInfo: Bool) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let leftW = w * left / 100
            ZStack(alignment: .leading) {
                HatchPattern(color: hatch)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(fill)
                    .frame(width: max(left > 0 ? 6 : 0, leftW))
                if let e = expectedUsed {
                    let x = w * (100 - e) / 100
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(theme.textPrimary)
                        .frame(width: 3, height: height - 6)
                        .overlay(RoundedRectangle(cornerRadius: 1.5).stroke(theme.groupedCard, lineWidth: 1.5))
                        .position(x: min(max(x, 3), w - 3), y: height / 2)
                        .accessibilityHidden(true)
                }
                if overlayInfo, let resetText {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.clockwise").appFont(11, weight: .semibold)
                        Text(resetText).monospacedDigit()
                        if let extrasText {
                            Text("·")
                            Image(systemName: "ticket").appFont(11)
                            Text(extrasText)
                        }
                    }
                    .appFont(13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(theme.groupedCard.opacity(0.92), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 8)
                }
            }
        }
        .frame(height: height)
    }
}

/// Schraffur für den verbrauchten Teil
struct HatchPattern: View {
    var color: Color
    var spacing: CGFloat = 7
    var body: some View {
        Canvas { ctx, size in
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width + size.height {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            ctx.stroke(path, with: .color(color), lineWidth: 1)
        }
    }
}
