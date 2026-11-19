import SwiftUI
import WidgetKit

// Widget „Abo-Limits“ (nach dem Vorbild des T3-Code-Widgets). Liegt im Shared-Ordner, damit die App dieselben
// Ansichten als Vorschau rendern kann (`-usage -widgetgallery`).

enum LimitsWidgetSize { case small, medium, large }

struct LimitsWidgetView: View {
    var snapshot: LimitsSnapshot?
    var size: LimitsWidgetSize
    var theme: Theme
    var now: Date = Date()

    static let deepLink = URL(string: "aisbot://usage/limits")!

    private var de: Locale { Locale(identifier: "de_DE") }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(Self.deepLink)
    }

    @ViewBuilder
    private var content: some View {
        if let snapshot, !snapshot.isEmpty || snapshot.providers.contains(where: { $0.state != "ok" }) {
            switch size {
            case .small: small(snapshot)
            case .medium: medium(snapshot)
            case .large: large(snapshot)
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                LimitsLogo()
                Spacer(minLength: 0)
                Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 20)).foregroundStyle(theme.textTertiary)
                Text("Noch keine Limits")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Text(size == .small ? "In der App unter „Nutzung und Verbrauch“ laden."
                                    : "Öffne in der App Einstellungen → „Nutzung und Verbrauch“, dann erscheinen hier die Limits deiner KI-Abos.")
                    .font(.system(size: 11.5)).foregroundStyle(theme.textSecondary)
                    .lineLimit(size == .small ? 3 : 2)
            }
        }
    }

    // MARK: Farben und Text

    private func color(_ p: LimitsSnapshot.Provider) -> Color {
        if p.id == "claude" { return Color(hex: "#D97757") }
        return theme.colorScheme == .dark ? Color(hex: "#A9A9AE") : Color(hex: "#3A3A3E")
    }

    private var track: Color { theme.colorScheme == .dark ? Color.white.opacity(0.12) : Color.black.opacity(0.08) }

    private func ordered(_ s: LimitsSnapshot) -> [LimitsSnapshot.Provider] {
        // Wie T3: Codex links, Claude rechts
        s.providers.sorted { a, _ in a.id == "openai" }
    }

    private func percentText(_ w: LimitsSnapshot.Window) -> String {
        w.isStale(at: now) ? "neu" : "\(Int(w.leftPercent.rounded())) % übrig"
    }

    private func resetText(_ w: LimitsSnapshot.Window, short: Bool = false) -> String? {
        guard let r = w.resetsAt else { return nil }
        if r <= now { return "Zurückgesetzt – App öffnen" }
        if short {
            let s = r.timeIntervalSince(now)
            let d = Int(s) / 86400, h = (Int(s) % 86400) / 3600, m = (Int(s) % 3600) / 60
            if d > 0 { return "Reset in \(d) T \(h) h" }
            if h > 0 { return "Reset in \(h) h \(m) min" }
            return "Reset in \(max(1, m)) min"
        }
        return "Reset am " + r.formatted(.dateTime.day().month(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(de))
    }

    private func standText(_ s: LimitsSnapshot) -> String {
        "Stand: " + s.generatedAt.formatted(.dateTime.day().month(.abbreviated).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).locale(de))
    }

    private func paceText(_ w: LimitsSnapshot.Window) -> String? {
        switch w.pace(at: now) {
        case .some(-1): "unter Tempo"
        case .some(0): "im Tempo"
        case .some(1): "über Tempo"
        default: nil
        }
    }

    // MARK: Klein: engstes Wochenfenster beider Anbieter

    private func small(_ s: LimitsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LimitsLogo().padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 11) {
                ForEach(ordered(s)) { p in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(p.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            Spacer(minLength: 2)
                            if p.state != "ok" {
                                Text("–").font(.system(size: 13, weight: .semibold)).foregroundStyle(theme.textTertiary)
                            } else if let w = s.tightestWeekly(p) {
                                Text(w.isStale(at: now) ? "neu" : "\(Int(w.leftPercent.rounded())) %")
                                    .font(.system(size: 15, weight: .bold)).monospacedDigit()
                                    .foregroundStyle(theme.textPrimary)
                            }
                        }
                        if p.state == "ok", let w = s.tightestWeekly(p) {
                            LimitBar(left: w.isStale(at: now) ? 100 : w.leftPercent, color: color(p), track: track,
                                     marker: paceMarker(w), height: 5, markerColor: theme.textPrimary)
                            Text(resetText(w, short: true) ?? w.label)
                                .font(.system(size: 10.5)).foregroundStyle(theme.textSecondary).lineLimit(1)
                                .minimumScaleFactor(0.85)
                        } else {
                            Text(p.state == "not_logged_in" ? "Nicht angemeldet" : "Kein Stand")
                                .font(.system(size: 10.5)).foregroundStyle(theme.textTertiary).lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Mittel: zwei Spalten wie T3

    private func medium(_ s: LimitsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            LimitsLogo().padding(.bottom, 8)
            HStack(alignment: .top, spacing: 18) {
                ForEach(ordered(s)) { p in
                    column(p, maxWindows: 2, includeSession: false, compact: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
            Text(standText(s)).font(.system(size: 10.5)).foregroundStyle(theme.textTertiary).lineLimit(1)
        }
    }

    // MARK: Groß: alle Fenster inkl. 5 Stunden, Tempo, Credits

    private func large(_ s: LimitsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                LimitsLogo()
                Spacer()
                Text("Gesamtes Abo").font(.system(size: 10.5, weight: .medium)).foregroundStyle(theme.textTertiary)
            }
            .padding(.bottom, 10)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(ordered(s)) { p in
                    column(p, maxWindows: 3, includeSession: true, compact: false)
                }
            }
            Spacer(minLength: 0)
            Text(standText(s)).font(.system(size: 10.5)).foregroundStyle(theme.textTertiary).lineLimit(1)
        }
    }

    private func windows(_ p: LimitsSnapshot.Provider, includeSession: Bool, max: Int) -> [LimitsSnapshot.Window] {
        let order = ["weekly": 0, "model": 1, "session": 2]
        return p.windows
            .filter { includeSession || $0.kind != "session" || p.windows.allSatisfy { $0.kind == "session" } }
            .sorted { (order[$0.kind] ?? 3) < (order[$1.kind] ?? 3) }
            .prefix(max).map { $0 }
    }

    private func column(_ p: LimitsSnapshot.Provider, maxWindows: Int, includeSession: Bool, compact: Bool) -> some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(p.name).font(.system(size: compact ? 17 : 16, weight: .bold)).foregroundStyle(theme.textPrimary)
                if !compact, let plan = p.plan {
                    Text(plan).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textSecondary)
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(track, in: Capsule())
                }
                Spacer(minLength: 0)
                if !compact, p.id == "openai", let extra = creditsText(p) {
                    Text(extra).font(.system(size: 10.5)).foregroundStyle(theme.textSecondary).lineLimit(1)
                }
            }
            .padding(.bottom, compact ? 1 : 0)
            if p.state != "ok" {
                Text(p.state == "not_logged_in" ? "Nicht angemeldet – in der App unter KI-Abos anmelden."
                                                 : "Gerade kein Stand verfügbar.")
                    .font(.system(size: 11.5)).foregroundStyle(theme.textTertiary).lineLimit(2)
            } else {
                ForEach(windows(p, includeSession: includeSession, max: maxWindows)) { w in
                    VStack(alignment: .leading, spacing: compact ? 3 : 4) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            Text(compact && w.kind == "model" ? w.label.replacingOccurrences(of: "Wöchentlich", with: "Woche") : w.label)
                                .font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 4)
                            Text(percentText(w)).font(.system(size: 12.5, weight: .semibold)).monospacedDigit()
                                .foregroundStyle(theme.textPrimary).lineLimit(1).fixedSize()
                        }
                        LimitBar(left: w.isStale(at: now) ? 100 : w.leftPercent, color: color(p), track: track,
                                 marker: paceMarker(w), height: compact ? 5 : 6,
                                 markerColor: theme.textPrimary)
                        HStack(spacing: 4) {
                            Text(resetText(w, short: compact && w.kind == "session") ?? "")
                                .lineLimit(1).minimumScaleFactor(0.85)
                            if !compact, let pace = paceText(w) {
                                Text("·")
                                Text(pace).foregroundStyle(w.pace(at: now) == 1 ? theme.warning : theme.textTertiary)
                            }
                        }
                        .font(.system(size: 10.5)).foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
    }

    /// Tempo-Linie: so viel wäre bei gleichmäßigem Verbrauch über das Fenster jetzt noch übrig. Liegt die Füllung
    /// rechts davon, verbraucht man weniger, als man könnte. Nach dem Reset (alter Stand) keine Linie.
    private func paceMarker(_ w: LimitsSnapshot.Window) -> Double? {
        w.isStale(at: now) ? nil : w.expectedUsed(at: now).map { 100 - $0 }
    }

    private func creditsText(_ p: LimitsSnapshot.Provider) -> String? {
        var parts: [String] = []
        if let b = p.creditsBalance {
            parts.append("Credits \(b.formatted(.number.precision(.fractionLength(0)).locale(de)))")
        }
        if let r = p.resetCredits, r > 0 { parts.append(r == 1 ? "1 Reset" : "\(r) Resets") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// AIS-Scoops-Logo (Lockup) oben links, wie ein App-Absender
struct LimitsLogo: View {
    var height: CGFloat = 13
    var body: some View {
        Image("WidgetLogo")
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(height: height)
            .accessibilityLabel("AIS Scoops")
    }
}

/// Fortschrittsbalken: übrig gefüllt in Anbieterfarbe, optional Tempo-Markierung
struct LimitBar: View {
    var left: Double
    var color: Color
    var track: Color
    var marker: Double?
    var height: CGFloat = 5
    var markerColor: Color = .primary

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(track)
                Capsule().fill(color).frame(width: max(left > 0 ? height : 0, g.size.width * left / 100))
                if let marker {
                    Capsule().fill(markerColor.opacity(0.85))
                        .frame(width: 2, height: height + 4)
                        .offset(x: min(max(0, g.size.width * marker / 100 - 1), g.size.width - 2))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Sperrbildschirm (Widget „Abo-Limits“ für den Sperrbildschirm)

/// Welche Abos ein Sperrbildschirm-Widget zeigt (beide = Claude und Codex).
nonisolated enum LimitsLockChoice: String, Sendable {
    case both, claude, openai
}

/// Wochenstand je Abo für den Sperrbildschirm: engstes Wochenfenster, nach einem Reset wieder voll.
nonisolated struct LimitsLockRow: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var leftPercent: Double
    var sessionLeft: Double?
    var resetsAt: Date?

    static func rows(_ snapshot: LimitsSnapshot?, choice: LimitsLockChoice, now: Date) -> [LimitsLockRow] {
        (snapshot?.providers ?? [])
            .filter { $0.state == "ok" && (choice == .both || $0.id == choice.rawValue) }
            .compactMap { p in
                guard let w = snapshot?.tightestWeekly(p) else { return nil }
                let stale = w.isStale(at: now)
                let session = p.windows.first { $0.kind == "session" }
                return LimitsLockRow(id: p.id, name: p.name, leftPercent: stale ? 100 : w.leftPercent,
                                     sessionLeft: session.map { $0.isStale(at: now) ? 100 : $0.leftPercent },
                                     resetsAt: stale ? nil : w.resetsAt)
            }
    }
}

/// Rechteckig: je Abo Name, „44 % übrig“ und ein Balken (wie die Systemanzeigen). Ein Abo allein zeigt
/// zusätzlich das 5-Stunden-Fenster und wann die Woche neu beginnt.
struct LimitsAccessoryRectangularView: View {
    var snapshot: LimitsSnapshot?
    var choice: LimitsLockChoice
    var now: Date

    var body: some View {
        let rows = LimitsLockRow.rows(snapshot, choice: choice, now: now)
        Group {
            if rows.isEmpty {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Abo-Limits").font(.headline).widgetAccentable()
                    Text("Öffne AIS Scoops, um die Limits zu laden.").font(.caption2).lineLimit(2)
                }
            } else if rows.count == 1, let r = rows.first {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(r.name).font(.headline).widgetAccentable()
                        Spacer(minLength: 4)
                        Text("\(Int(r.leftPercent.rounded())) % übrig").font(.caption.weight(.semibold)).monospacedDigit()
                    }
                    Gauge(value: r.leftPercent, in: 0...100) { EmptyView() }
                        .gaugeStyle(.accessoryLinearCapacity)
                    HStack(spacing: 4) {
                        if let s = r.sessionLeft { Text("5 Std. \(Int(s.rounded())) %").monospacedDigit() }
                        Spacer(minLength: 2)
                        if let reset = r.resetsAt { Text("neu \(reset, format: .dateTime.weekday(.abbreviated).hour())") }
                    }
                    .font(.caption2)
                    .lineLimit(1)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(rows.prefix(2)) { r in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack {
                                Text(r.name).font(.system(size: 13, weight: .semibold)).widgetAccentable()
                                Spacer(minLength: 4)
                                Text("\(Int(r.leftPercent.rounded())) % übrig")
                                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                            }
                            Gauge(value: r.leftPercent, in: 0...100) { EmptyView() }
                                .gaugeStyle(.accessoryLinearCapacity)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(LimitsWidgetView.deepLink)
        .accessibilityElement(children: .combine)
    }
}

/// Rund: Ring mit dem Wochenstand. Bei „beide“ das Abo mit weniger Rest.
struct LimitsAccessoryCircularView: View {
    var snapshot: LimitsSnapshot?
    var choice: LimitsLockChoice
    var now: Date

    var body: some View {
        let r = LimitsLockRow.rows(snapshot, choice: choice, now: now).min { $0.leftPercent < $1.leftPercent }
        Group {
            if let r {
                Gauge(value: r.leftPercent, in: 0...100) {
                    Text(r.id == "openai" ? "Codex" : "Claude")
                } currentValueLabel: {
                    Text("\(Int(r.leftPercent.rounded()))").monospacedDigit()
                }
                .gaugeStyle(.accessoryCircular)
                .accessibilityLabel("\(r.name): \(Int(r.leftPercent.rounded())) Prozent der Woche übrig")
            } else {
                ZStack {
                    AccessoryWidgetBackground()
                    Image(systemName: "gauge.with.dots.needle.33percent").font(.system(size: 20, weight: .semibold))
                }
            }
        }
        .widgetURL(LimitsWidgetView.deepLink)
    }
}

/// Eine Zeile über der Uhr: „Claude 44 % · Codex 96 %“.
struct LimitsAccessoryInlineView: View {
    var snapshot: LimitsSnapshot?
    var choice: LimitsLockChoice
    var now: Date

    var body: some View {
        let rows = LimitsLockRow.rows(snapshot, choice: choice, now: now)
        if rows.isEmpty {
            Label("Abo-Limits", systemImage: "gauge.with.dots.needle.33percent")
        } else {
            Text(rows.map { "\($0.name) \(Int($0.leftPercent.rounded())) %" }.joined(separator: " · "))
                .widgetURL(LimitsWidgetView.deepLink)
        }
    }
}
