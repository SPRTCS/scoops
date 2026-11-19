import Charts
import SwiftUI

// Seite „Nutzung und Verbrauch“ (Server 1.31, docs/nutzung.md), nach dem Vorbild der Usage-Ansicht von T3 Code:
// Tabs Kosten / Tokens / Limits, Zeitraum 24 h – 90 T. Breite Fenster (Mac, iPad, Duo aufgeklappt) zeigen das
// Desktop-Layout (Kennzahlen links, Flächendiagramm rechts, Tabellen), schmale (iPhone, Duo zugeklappt) das mobile
// (Karten untereinander, gestapelte Balken).

enum UsageTab: String, CaseIterable, Identifiable {
    case cost, tokens, limits
    var id: String { rawValue }
    var title: String {
        switch self {
        case .cost: "Kosten"
        case .tokens: "Tokens"
        case .limits: "Limits"
        }
    }
}

enum UsageBreakdown: String, CaseIterable, Identifiable {
    case model, day, app, scoop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .model: "Modell"
        case .day: "Tag"
        case .app: "App"
        case .scoop: "Scoop"
        }
    }
}

/// Anbieterfarben wie in T3 Code: Claude-Orange, OpenAI dunkelgrau (im Dunkelmodus hellgrau).
struct UsagePalette {
    let theme: Theme
    var claude: Color { Color(hex: "#D97757") }
    var openai: Color { theme.colorScheme == .dark ? Color(hex: "#C9C9CE") : Color(hex: "#2C2C30") }
    func color(_ p: UsageProvider) -> Color { p == .claude ? claude : openai }
    func color(_ id: String?) -> Color { id == "openai" ? openai : (id == "claude" ? claude : theme.textTertiary) }
    var api: Color { theme.accent }
    var abo: Color { theme.colorScheme == .dark ? Color(hex: "#6C6C72") : Color(hex: "#B9B9BE") }
    /// Kosten nach Typ: Eingabe, Cache lesen, Cache schreiben, Ausgabe (Grautöne wie T3)
    var types: [Color] {
        theme.colorScheme == .dark
            ? [Color(hex: "#8E8E93"), Color(hex: "#5A5A5F"), Color(hex: "#B5B5BA"), Color(hex: "#F2F2F3")]
            : [Color(hex: "#6E6E73"), Color(hex: "#B8B8BD"), Color(hex: "#48484C"), Color(hex: "#111111")]
    }
}

struct UsageView: View {
    /// Eigenes Fenster auf dem Mac (AISBotApp)
    static let windowID = "usage"

    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var tab: UsageTab = UsageRouter.shared.tab ?? UsageView.initialTab
    @State private var range: UsageRange = .month
    @State private var source: UsageSource = .all
    @State private var breakdown: UsageBreakdown = .model
    @State private var details: [String: UsageDetails] = [:]
    @State private var limits: UsageLimits?
    @State private var loadingDetails = false
    @State private var loadingLimits = false
    @State private var message: String?
    @State private var limitsMessage: String?
    @State private var width: CGFloat = 0
    @State private var now = PreviewData.clock

    private var wide: Bool { width >= 720 }
    private var palette: UsagePalette { UsagePalette(theme: theme) }
    private var key: String { "\(range.rawValue)|\(source.rawValue)" }
    private var current: UsageDetails? { details[key] }

    private static var initialTab: UsageTab {
        let a = ProcessInfo.processInfo.arguments
        if let i = a.firstIndex(of: "-usagetab"), i + 1 < a.count, let t = UsageTab(rawValue: a[i + 1]) { return t }
        return .cost
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(theme.surfaceBorder).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: wide ? 34 : 22) {
                    if !wide { compactControls }
                    if wide && width < 1100 && tab != .limits {
                        // Mittlere Breite (iPad hochkant, Duo aufgeklappt): Zeitraum in eigener Zeile
                        HStack {
                            Spacer()
                            UsageSegments(items: UsageRange.allCases, selection: $range) { $0.long }
                                .frame(maxWidth: 400)
                        }
                        .padding(.bottom, -12)
                    }
                    if let message { notice(message, icon: "exclamationmark.triangle") }
                    switch tab {
                    case .cost, .tokens: metricContent
                    case .limits: limitsContent
                    }
                }
                .padding(.horizontal, wide ? 36 : 16)
                .padding(.top, wide ? 28 : 16)
                .padding(.bottom, 40)
                .frame(maxWidth: wide ? 1240 : 640)
                .frame(maxWidth: .infinity)
            }
            .refreshable { await reload(force: true) }
        }
        .background(theme.groupedBackground.ignoresSafeArea())
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: key) { await loadDetails(force: false) }
        .task { await loadLimits(force: true) }  // Limits gleich beim Öffnen frisch holen (ohne Modellaufruf)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                now = PreviewData.clock
            }
        }
        #if os(macOS)
        .frame(minWidth: 760, idealWidth: 1120, minHeight: 600, idealHeight: 820)
        #endif
    }

    // MARK: Kopf

    private var header: some View {
        HStack(spacing: 12) {
            Text("Nutzung und Verbrauch")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(theme.textPrimary)
                .lineLimit(1)
                .layoutPriority(1)
            if wide && tab != .limits { sourceMenu }
            Spacer(minLength: 8)
            if wide {
                if tab != .limits && width >= 1100 {
                    UsageSegments(items: UsageRange.allCases, selection: $range) { $0.long }
                        .frame(maxWidth: 380)
                }
                UsageSegments(items: UsageTab.allCases, selection: $tab) { $0.title }
                    .frame(maxWidth: 270)
            }
            refreshButton
            #if os(iOS)
            CircleIconButton(systemName: "xmark", help: "Schließen", size: 30) { dismiss() }
                .keyboardShortcut(.cancelAction)
            #endif
        }
        .padding(.horizontal, wide ? 24 : 16)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var refreshButton: some View {
        Button { Task { await reload(force: true) } } label: {
            ZStack {
                if loadingDetails || loadingLimits {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(width: 30, height: 30)
            .background(theme.circleButton, in: Circle())
            .overlay(Circle().strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help("Aktualisieren")
        .accessibilityLabel("Aktualisieren")
        .keyboardShortcut("r", modifiers: .command)
    }

    private var sourceMenu: some View {
        Menu {
            Picker("Quelle", selection: $source) {
                ForEach(UsageSource.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 5) {
                Text(source.title).font(.system(size: 14, weight: .medium)).foregroundStyle(theme.textPrimary)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 6)
            .background(theme.surface, in: Capsule())
            .fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Quelle: \(source.title)")
    }

    private var compactControls: some View {
        VStack(spacing: 10) {
            UsageSegments(items: UsageTab.allCases, selection: $tab, large: true) { $0.title }
            if tab != .limits {
                UsageSegments(items: UsageRange.allCases, selection: $range, large: true) { $0.short }
                HStack {
                    sourceMenu
                    Spacer()
                    if let d = current { logsStatus(d) }
                }
            }
        }
    }

    // MARK: Kosten und Tokens

    @ViewBuilder
    private var metricContent: some View {
        if let d = current {
            if d.logs?.state == "running" {
                notice("Die Protokolle von Claude Code und Codex werden gerade eingelesen. Die Zahlen ergänzen sich gleich.",
                       icon: "hourglass")
            }
            if wide { wideMetrics(d) } else { compactMetrics(d) }
            notes(d)
        } else if loadingDetails {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 80)
        }
    }

    private var isCost: Bool { tab == .cost }

    private func mainValue(_ d: UsageDetails) -> String {
        isCost ? UsageFormat.usd(d.totals.costUsd) : UsageFormat.tokens(d.totals.tokens)
    }

    private func sessionsText(_ d: UsageDetails) -> String {
        let s = d.totals.sessions
        return s == 1 ? "1 Sitzung" : "\(s.formatted(.number.locale(UsageFormat.locale))) Sitzungen"
    }

    // Breit: wie T3 Desktop
    @ViewBuilder
    private func wideMetrics(_ d: UsageDetails) -> some View {
        HStack(alignment: .top, spacing: 40) {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(mainValue(d))
                            .font(.system(size: 46, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                            .minimumScaleFactor(0.5)
                            .lineLimit(1)
                        if isCost { Text("*").font(.system(size: 30, weight: .bold)).foregroundStyle(theme.textSecondary) }
                    }
                    Text(isCost ? "\(sessionsText(d)) · * zum API-Listenpreis (Schätzung)" : sessionsText(d))
                        .font(.system(size: 13.5)).foregroundStyle(theme.textSecondary)
                }
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(UsageProvider.allCases) { p in providerSummary(d, p) }
                }
                if isCost { realCostBlock(d) }
            }
            .frame(width: min(max(width * 0.3, 300), 380), alignment: .leading)
            VStack(alignment: .leading, spacing: 12) {
                Text(chartTitle(d)).font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                UsageTrendChart(points: d.series, metric: isCost ? .cost : .tokens, palette: palette, theme: theme,
                                style: .area, hourly: d.bucket == "hour")
                    .frame(height: 300)
            }
            .frame(maxWidth: .infinity)
        }
        totalsSection(d, columns: 5)
        HStack(alignment: .top, spacing: 40) {
            typeSection(d).frame(maxWidth: .infinity, alignment: .leading)
            if isCost { splitSection(d).frame(maxWidth: .infinity, alignment: .leading) }
            else { sourceSection(d).frame(maxWidth: .infinity, alignment: .leading) }
        }
        if isCost { sourceSection(d) }
        breakdownSection(d)
    }

    // Schmal: wie T3 mobil
    @ViewBuilder
    private func compactMetrics(_ d: UsageDetails) -> some View {
        UsageCard {
            VStack(alignment: .leading, spacing: 4) {
                Text(isCost ? "Rohe Token-Kosten" : "Verarbeitete Tokens")
                    .font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(mainValue(d))
                        .font(.system(size: 36, weight: .bold))
                        .monospacedDigit()
                        .foregroundStyle(theme.textPrimary)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    if isCost { Text("*").font(.system(size: 26, weight: .bold)).foregroundStyle(theme.textPrimary) }
                }
                Text(isCost ? "* bei vollem API-Preis (Schätzung)" : "Über \(sessionsText(d))")
                    .font(.system(size: 13.5)).foregroundStyle(theme.textSecondary)
            }
            UsageTrendChart(points: d.series, metric: isCost ? .cost : .tokens, palette: palette, theme: theme,
                            style: .bars, hourly: d.bucket == "hour")
                .frame(height: 210)
                .padding(.top, 14)
            legend
                .padding(.top, 6)
        }
        if isCost {
            sectionTitle("Was du wirklich bezahlst")
            UsageCard { realCostBlock(d) }
        }
        sectionTitle("Anbieter")
        UsageCard(spacing: 0) {
            ForEach(Array(UsageProvider.allCases.enumerated()), id: \.element) { i, p in
                if i > 0 { GroupedDivider(inset: 0).padding(.vertical, 12) }
                providerCompactRow(d, p)
            }
        }
        totalsSection(d, columns: 2)
        typeSection(d)
        sourceSection(d)
        breakdownSection(d)
    }

    private func chartTitle(_ d: UsageDetails) -> String {
        let hourly = d.bucket == "hour"
        if isCost { return hourly ? "Kosten pro Stunde" : "Tägliche Kosten" }
        return hourly ? "Verarbeitete Tokens pro Stunde" : "Täglich verarbeitete Tokens"
    }

    private var legend: some View {
        HStack(spacing: 16) {
            ForEach(UsageProvider.allCases) { p in
                HStack(spacing: 6) {
                    Circle().fill(palette.color(p)).frame(width: 8, height: 8)
                    Text(p == .claude ? "Claude" : "OpenAI").font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                }
            }
        }
    }

    private func providerSummary(_ d: UsageDetails, _ p: UsageProvider) -> some View {
        let row = d.provider(p) ?? .init(id: p.rawValue, label: p == .claude ? "Claude" : "OpenAI")
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Circle().fill(palette.color(p)).frame(width: 9, height: 9).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
                Text(row.label).font(.system(size: 17, weight: .medium)).foregroundStyle(theme.textPrimary)
                Text(requestsText(row.requests)).font(.system(size: 12.5)).foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(isCost ? UsageFormat.usd(row.costUsd) : UsageFormat.tokens(row.tokens))
                    .font(.system(size: 17, weight: .semibold)).monospacedDigit().foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
            }
            Text(providerDetail(row))
                .font(.system(size: 13)).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 17)
        }
    }

    private func providerCompactRow(_ d: UsageDetails, _ p: UsageProvider) -> some View {
        let row = d.provider(p) ?? .init(id: p.rawValue, label: p == .claude ? "Claude" : "OpenAI")
        let share = isCost ? row.shareCost : row.shareTokens
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(palette.color(p)).frame(width: 9, height: 9)
                Text(row.label).font(.system(size: 18, weight: .medium)).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 6)
                Text(isCost ? UsageFormat.usd(row.costUsd) : UsageFormat.tokens(row.tokens))
                    .font(.system(size: 18, weight: .medium)).monospacedDigit().foregroundStyle(theme.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            ShareBar(share: share, color: palette.color(p), track: theme.surfaceBorder)
            Text(providerDetail(row)).font(.system(size: 13)).foregroundStyle(theme.textSecondary)
        }
    }

    private func requestsText(_ n: Int) -> String {
        n == 1 ? "1 Anfrage" : "\(n.formatted(.number.locale(UsageFormat.locale))) Anfragen"
    }

    private func providerDetail(_ row: UsageDetails.Row) -> String {
        if isCost {
            var s = "\(UsageFormat.percent(row.shareCost)) der Kosten · \(UsageFormat.tokens(row.tokens)) Tokens"
            if row.scoopsUsd > 0 { s += " · davon Scoops \(UsageFormat.usd(row.scoopsUsd))" }
            return s
        }
        var s = "\(UsageFormat.percent(row.shareTokens)) der Tokens · \(UsageFormat.usd(row.costUsd))"
        if row.scoopsTokens > 0 { s += " · davon Scoops \(UsageFormat.tokens(row.scoopsTokens))" }
        return s
    }

    /// Der eigentliche Mehrwert: echte API-Kosten der Scoops vs. über das Abo abgedeckt
    private func realCostBlock(_ d: UsageDetails) -> some View {
        let t = d.totals
        let total = max(t.costUsd, 0.0001)
        return VStack(alignment: .leading, spacing: 10) {
            ValueSplitBar(parts: [(t.apiUsd / total, palette.api), (t.aboUsd / total, palette.abo)], height: 8)
            VStack(alignment: .leading, spacing: 7) {
                keyValue(dot: palette.api, "Echte API-Kosten (Scoops)", UsageFormat.usd(t.apiUsd), bold: true)
                keyValue(dot: palette.abo, "Über Abos abgedeckt", UsageFormat.usd(t.aboUsd), bold: false)
            }
            Text("Abo-Läufe kosten nichts extra; der Betrag zeigt, was sie über den API-Schlüssel gekostet hätten.")
                .font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func keyValue(dot: Color, _ title: String, _ value: String, bold: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 2).fill(dot).frame(width: 8, height: 8)
            Text(title).font(.system(size: 14)).foregroundStyle(theme.textSecondary).lineLimit(1).minimumScaleFactor(0.8)
            Spacer(minLength: 8)
            Text(value).font(.system(size: 14, weight: bold ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(theme.textPrimary).lineLimit(1)
        }
    }

    private func sectionTitle(_ s: String, trailing: AnyView? = nil) -> some View {
        HStack {
            Text(s).font(.system(size: wide ? 17 : 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
            Spacer()
            if let trailing { trailing }
        }
        .padding(.horizontal, wide ? 0 : 4)
        .padding(.bottom, wide ? 0 : -10)
    }

    private func totalsSection(_ d: UsageDetails, columns: Int) -> some View {
        let t = d.totals
        let items: [(String, String)] = [
            ("Verarbeitete Tokens", UsageFormat.tokens(t.tokens)),
            ("Cached Input", UsageFormat.tokens(t.cacheRead)),
            ("Uncached Input", UsageFormat.tokens(t.input + t.cacheWrite)),
            ("Output", UsageFormat.tokens(t.output)),
            ("Cache-Ersparnis", UsageFormat.usd(t.cacheSavingsUsd)),
        ]
        let grid = LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 16, alignment: .leading), count: columns),
                             alignment: .leading, spacing: 18) {
            ForEach(items, id: \.0) { item in
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.0).font(.system(size: 13)).foregroundStyle(theme.textSecondary).lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text(item.1).font(.system(size: wide ? 22 : 20, weight: .semibold)).monospacedDigit()
                        .foregroundStyle(theme.textPrimary).lineLimit(1).minimumScaleFactor(0.6)
                }
            }
        }
        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Summen")
            if wide { grid } else { UsageCard { grid } }
        }
    }

    private func typeSection(_ d: UsageDetails) -> some View {
        let t = d.totals
        let names = ["Input", "Cache lesen", "Cache schreiben", "Output"]
        let values: [Double] = isCost
            ? [d.byType.input, d.byType.cacheRead, d.byType.cacheWrite, d.byType.output]
            : [Double(t.input), Double(t.cacheRead), Double(t.cacheWrite), Double(t.output)]
        let sum = max(values.reduce(0, +), 0.000001)
        let body = VStack(alignment: .leading, spacing: 12) {
            ValueSplitBar(parts: zip(values, palette.types).map { ($0 / sum, $1) }, height: 10)
            FlowLegend(items: names.indices.map { i in
                (palette.types[i], names[i], isCost ? UsageFormat.usd(values[i]) : UsageFormat.tokens(Int(values[i])))
            })
        }
        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle(isCost ? "Kosten nach Typ" : "Tokens nach Typ")
            if wide { body } else { UsageCard { body } }
        }
    }

    private func splitSection(_ d: UsageDetails) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Abo und API").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Spacer()
                Text("API \(UsageFormat.usd(d.totals.apiUsd))").font(.system(size: 13.5)).foregroundStyle(theme.textSecondary)
            }
            realCostBlock(d)
        }
    }

    private func sourceSection(_ d: UsageDetails) -> some View {
        let rows = d.sources
        let colors: [String: Color] = ["scoops": theme.accent, "other": palette.abo]
        let sum = max(rows.reduce(0) { $0 + (isCost ? $1.costUsd : Double($1.tokens)) }, 0.000001)
        let body = VStack(alignment: .leading, spacing: 12) {
            ValueSplitBar(parts: rows.map { ((isCost ? $0.costUsd : Double($0.tokens)) / sum, colors[$0.id] ?? palette.abo) },
                          height: 10)
            FlowLegend(items: rows.map { r in
                (colors[r.id] ?? palette.abo, r.id == "other" ? "Andere Apps" : r.label, isCost ? UsageFormat.usd(r.costUsd) : UsageFormat.tokens(r.tokens))
            })
            if let acc = d.account?.openai, !isCost {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
                    Text("OpenAI-Konto insgesamt: \(UsageFormat.tokens(acc.tokens)) Tokens (laut Codex, alle Geräte)")
                        .font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        return VStack(alignment: .leading, spacing: 16) {
            sectionTitle("Nach Quelle")
            if wide { body } else { UsageCard { body } }
        }
    }

    private func breakdownRows(_ d: UsageDetails) -> [UsageDetails.Row] {
        let rows: [UsageDetails.Row]
        switch breakdown {
        case .model: rows = d.models
        case .day: rows = d.days
        case .app: rows = d.apps
        case .scoop: rows = d.scoops
        }
        if breakdown == .day { return rows }
        return rows.sorted { isCost ? $0.costUsd > $1.costUsd : $0.tokens > $1.tokens }
    }

    private var breakdownOptions: [UsageBreakdown] {
        var o: [UsageBreakdown] = [.model, .day, .app]
        if source != .other { o.append(.scoop) }
        if range == .day { o.removeAll { $0 == .day } }
        return o
    }

    @ViewBuilder
    private func breakdownSection(_ d: UsageDetails) -> some View {
        let rows = breakdownRows(d)
        VStack(alignment: .leading, spacing: 12) {
            Group {
                if wide {
                    HStack {
                        Text("Aufschlüsselung").font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.textPrimary)
                        Spacer()
                        UsageSegments(items: breakdownOptions, selection: $breakdown) { $0.title }
                            .frame(maxWidth: 320)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Aufschlüsselung").font(.system(size: 16, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            .padding(.horizontal, 4)
                        UsageSegments(items: breakdownOptions, selection: $breakdown) { $0.title }
                    }
                }
            }
            .onChange(of: range) { if !breakdownOptions.contains(breakdown) { breakdown = .model } }
            .onChange(of: source) { if !breakdownOptions.contains(breakdown) { breakdown = .model } }
            UsageTable(rows: rows, isCost: isCost, wide: wide, palette: palette, theme: theme, numbered: breakdown != .day,
                       nameTitle: breakdown.title)
            if rows.isEmpty {
                Text(breakdown == .scoop ? "Keine Scoop-Läufe in diesem Zeitraum." : "Keine Nutzung in diesem Zeitraum.")
                    .font(.system(size: 13.5)).foregroundStyle(theme.textSecondary).padding(.horizontal, 4)
            }
        }
    }

    private func notes(_ d: UsageDetails) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text("Kosten und Tokens enthalten alle Programme auf dem Server-Mac (Claude Code, Codex, T3 Code, Scoops …). "
                     + "Nutzung auf anderen Geräten oder in claude.ai/ChatGPT im Browser fehlt hier – in den Limits ist sie enthalten.")
            } icon: { Image(systemName: "info.circle") }
            Label {
                Text("Abo-Verbrauch ist zum API-Listenpreis bewertet; echte Kosten entstehen nur über den API-Schlüssel.")
            } icon: { Image(systemName: "dollarsign.circle") }
            if (d.totals.unpricedTokens ?? 0) > 0 || d.models.contains(where: { $0.priceEstimated == true }) {
                Label { Text("Einige Modelle haben keinen eigenen Listenpreis; sie sind geschätzt oder ohne Betrag.") }
                    icon: { Image(systemName: "questionmark.circle") }
            }
        }
        .font(.system(size: 12.5))
        .foregroundStyle(theme.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, wide ? 0 : 4)
    }

    @ViewBuilder
    private func logsStatus(_ d: UsageDetails) -> some View {
        if let files = d.logs?.files, files > 0 {
            Text("\(files) Protokolle").font(.system(size: 12)).foregroundStyle(theme.textTertiary)
        }
    }

    private func notice(_ text: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).foregroundStyle(theme.textSecondary)
            Text(text).font(.system(size: 13.5)).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(theme.groupedCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
    }

    // MARK: Limits

    @ViewBuilder
    private var limitsContent: some View {
        if let limits {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.checkmark").foregroundStyle(theme.textSecondary)
                Text(limits.scopeNote ?? "Gesamtes Abo, alle Apps und Geräte")
                    .font(.system(size: 13.5)).foregroundStyle(theme.textSecondary)
            }
            .padding(.horizontal, wide ? 0 : 4)
            if let limitsMessage { notice(limitsMessage, icon: "exclamationmark.triangle") }
            ForEach(sortedLimitProviders(limits)) { p in
                VStack(alignment: .leading, spacing: 12) {
                    limitHeader(p)
                    switch p.state {
                    case "ok":
                        ForEach(p.windows) { w in
                            LimitCard(window: w, provider: p, now: now, wide: wide, palette: palette, theme: theme,
                                      showExtras: w.id == p.windows.first?.id)
                        }
                        limitFooter(p)
                    case "not_logged_in":
                        notLoggedIn(p)
                    default:
                        notice(p.error.map { "Limits gerade nicht abrufbar (\($0))." } ?? "Limits gerade nicht abrufbar. Nach dem nächsten Lauf über das Abo erscheint hier der letzte Stand.",
                               icon: "clock.badge.questionmark")
                    }
                }
            }
        } else if loadingLimits {
            HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 80)
        } else if let limitsMessage {
            notice(limitsMessage, icon: "exclamationmark.triangle")
        }
    }

    private func sortedLimitProviders(_ l: UsageLimits) -> [UsageLimits.Provider] {
        // Angemeldete zuerst (wie T3: Codex oben, wenn beide)
        l.providers.sorted { a, b in
            if (a.state == "ok") != (b.state == "ok") { return a.state == "ok" }
            return a.id == "openai" && b.id == "claude"
        }
    }

    private func limitHeader(_ p: UsageLimits.Provider) -> some View {
        HStack(spacing: 9) {
            Image(systemName: p.id == "claude" ? "asterisk" : "hexagon")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(p.id == "claude" ? palette.claude : theme.textPrimary)
            Text(p.id == "claude" ? "Claude" : "Codex · ChatGPT")
                .font(.system(size: 18, weight: .medium)).foregroundStyle(theme.textPrimary)
            if let plan = p.plan {
                Text(plan).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(theme.surface, in: Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, wide ? 0 : 4)
    }

    @ViewBuilder
    private func limitFooter(_ p: UsageLimits.Provider) -> some View {
        let at = UsageFormat.date(p.at)
        let parts: [String] = [
            p.credits.flatMap { c in
                if c.unlimited == true { return "Credits: unbegrenzt" }
                return c.balance.map { "Credits: \($0.formatted(.number.precision(.fractionLength(0)).locale(UsageFormat.locale)))" }
            },
            p.extra?.resetCredits.flatMap { $0 > 0 ? ($0 == 1 ? "1 Limit-Reset verfügbar" : "\($0) Limit-Resets verfügbar") : nil },
            p.extraUsage.flatMap { $0.enabled == false ? "Zusatznutzung aus" : $0.usedPercent.map { "Zusatznutzung \(Int($0)) %" } },
            at.map { d in
                let src = p.source == "live" ? "live" : (p.source == "event" ? "aus dem letzten Scoops-Lauf" : "aus den Protokollen")
                return "Stand \(Formatting.dayTime(d)) (\(src))"
            },
        ].compactMap { $0 }
        if !parts.isEmpty || p.error != nil {
            VStack(alignment: .leading, spacing: 4) {
                Text(parts.joined(separator: " · "))
                if p.error != nil, p.source != "live" || (at.map { now.timeIntervalSince($0) > 600 } ?? false) {
                    Text("Live-Abfrage gerade nicht möglich – das ist der letzte bekannte Stand.")
                }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(theme.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, wide ? 4 : 8)
        }
    }

    private func notLoggedIn(_ p: UsageLimits.Provider) -> some View {
        let name = p.id == "claude" ? "Claude" : "ChatGPT"
        return UsageCard {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 22))
                    .foregroundStyle(theme.textSecondary)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nicht mit \(name) angemeldet").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                    Text("Melde dich in den Einstellungen unter „KI-Abos“ mit deinem \(name)-Abo an. Danach erscheinen hier "
                         + "Wochenlimit, 5-Stunden-Fenster und Modellfenster.")
                        .font(.system(size: 13.5)).foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    #if os(iOS)
                    Button("Zu den KI-Abos") { dismiss() }
                        .font(.system(size: 14, weight: .medium))
                        .padding(.top, 2)
                    #endif
                }
            }
        }
    }

    // MARK: Laden

    private func reload(force: Bool) async {
        if tab == .limits {
            await loadLimits(force: force)
        } else {
            await loadDetails(force: force)
            if force { Task { await loadLimits(force: true) } }
        }
    }

    private func loadDetails(force: Bool) async {
        guard let service = store.service else { message = "Nur mit Verbindung zum Server verfügbar."; return }
        let k = key
        if details[k] != nil && !force { return }
        loadingDetails = true
        defer { loadingDetails = false }
        do {
            var d = try await service.usageDetails(range: range.rawValue, source: source.rawValue, refresh: force)
            details[k] = d
            message = nil
            // Erster Durchlauf der Protokolle: nachladen, bis er fertig ist
            var tries = 0
            while d.logs?.state == "running", tries < 20, !Task.isCancelled {
                tries += 1
                try? await Task.sleep(for: .seconds(3))
                d = try await service.usageDetails(range: range.rawValue, source: source.rawValue, refresh: false)
                details[k] = d
            }
        } catch let e as APIError where e.status == 404 {
            message = "Der Server ist zu alt für diese Ansicht. Bitte „AIS Scoops Server“ aktualisieren (ab Version 1.31)."
        } catch {
            if details[k] == nil { message = error.localizedDescription }
        }
    }

    private func loadLimits(force: Bool) async {
        guard let service = store.service else { return }
        loadingLimits = true
        defer { loadingLimits = false }
        do {
            let l = try await service.usageLimits(refresh: force)
            limits = l
            limitsMessage = nil
            AppStore.storeLimitsForWidget(l, mock: store.isMock)  // Widget „Abo-Limits“ aktuell halten
        } catch let e as APIError where e.status == 404 {
            limitsMessage = "Der Server ist zu alt für diese Ansicht (ab Version 1.31)."
        } catch {
            limitsMessage = error.localizedDescription
        }
        now = PreviewData.clock
    }
}

// MARK: - Bausteine

/// Karte im Stil der App (groupedCard, Haarlinie)
struct UsageCard<Content: View>: View {
    var spacing: CGFloat = 0
    @ViewBuilder var content: Content
    @Environment(\.theme) private var theme

    init(spacing: CGFloat = 0, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.groupedCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(theme.surfaceBorder, lineWidth: 0.5))
    }
}

/// Kapsel-Segmente wie in T3 (ausgewählt: helle Kapsel mit leichtem Schatten)
struct UsageSegments<Item: Hashable & Identifiable>: View {
    let items: [Item]
    @Binding var selection: Item
    var large = false
    let title: (Item) -> String
    @Environment(\.theme) private var theme
    @Namespace private var ns

    init(items: [Item], selection: Binding<Item>, large: Bool = false, title: @escaping (Item) -> String) {
        self.items = items; self._selection = selection; self.large = large; self.title = title
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items) { item in
                let on = item == selection
                Button {
                    withAnimation(.snappy(duration: 0.22)) { selection = item }
                } label: {
                    Text(title(item))
                        .font(.system(size: large ? 15 : 13.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? theme.textPrimary : theme.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.horizontal, large ? 8 : 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: large ? 36 : 30)
                        .background {
                            if on {
                                Capsule().fill(theme.colorScheme == .dark ? Color(hex: "#3A3A3E") : .white)
                                    .shadow(color: .black.opacity(theme.colorScheme == .dark ? 0 : 0.08), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "sel", in: ns)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(theme.colorScheme == .dark ? Color(hex: "#1F1F22") : Color(hex: "#E6E6E9"), in: Capsule())
    }
}

/// Anteil als dünner Balken (Anbieterzeile mobil)
struct ShareBar: View {
    var share: Double
    var color: Color
    var track: Color
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: max(4, g.size.width * min(1, max(0, share))))
            }
        }
        .frame(height: 6)
    }
}

/// Segmentbalken (Kosten nach Typ, Abo/API, Quelle)
struct ValueSplitBar: View {
    var parts: [(Double, Color)]
    var height: CGFloat = 10
    var body: some View {
        GeometryReader { g in
            let visible = parts.filter { $0.0 > 0.0005 }
            let gap: CGFloat = 3
            let usable = max(0, g.size.width - gap * CGFloat(max(0, visible.count - 1)))
            HStack(spacing: gap) {
                ForEach(visible.indices, id: \.self) { i in
                    Capsule().fill(visible[i].1).frame(width: max(height * 0.6, usable * visible[i].0))
                }
            }
        }
        .frame(height: height)
    }
}

/// Legende, die bei wenig Platz umbricht
struct FlowLegend: View {
    var items: [(Color, String, String)]
    @Environment(\.theme) private var theme
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 175), spacing: 22, alignment: .leading)], alignment: .leading,
                  spacing: 8) {
            ForEach(items.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2).fill(items[i].0).frame(width: 9, height: 9)
                    Text(items[i].1).font(.system(size: 13.5)).foregroundStyle(theme.textSecondary).lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    Text(items[i].2).font(.system(size: 13.5, weight: .medium)).monospacedDigit()
                        .foregroundStyle(theme.textPrimary).lineLimit(1)
                }
            }
        }
    }
}
