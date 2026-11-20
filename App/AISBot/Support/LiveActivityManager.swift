#if os(iOS)
import ActivityKit
import Foundation
import UIKit

/// EINE gemeinsame Live-Aktivität für alle arbeitenden Scoops (`ScoopsLiveAttributes`).
///
/// - Push-to-Start: Token aus `Activity<ScoopsLiveAttributes>.pushToStartTokenUpdates` → `POST /api/devices`
///   (platform `ios-scoops-live-start`). Der Server startet die Aktivität, sobald ein Scoop zu arbeiten beginnt,
///   und aktualisiert sie bevorzugt über einen APNs-Broadcast-Kanal (iOS 18+), sonst per Token.
/// - Läuft eine Aktivität mit `pushType: .token`, geht ihr Update-Token → `POST /api/live-activities`
///   (`chat_id: "scoops"`, `run_id: <Server-Sitzung>`).
/// - Vordergrund: Arbeitet ein Scoop und gibt es keine Aktivität → `POST /api/live-activity/ensure`; ist die Sitzung
///   aktiv, startet die App sie lokal (Kanal bzw. Token) mit dem Inhalt vom Server. Danach aktualisiert die App nur im
///   Vordergrund aus dem Schnappschuss nach, sonst übernimmt der Server per Push.
/// - Aufräumen: alte Einzel-Aktivitäten (`BotRunAttributes`) werden sofort beendet; von mehreren Scoops-Aktivitäten
///   bleibt nur die neueste; arbeitet kein Scoop mehr, endet die Aktivität mit „Alle fertig“ (5 s sichtbar).
final class LiveActivityManager {
    static let shared = LiveActivityManager()

    typealias State = ScoopsLiveAttributes.ContentState
    typealias Entry = ScoopsLiveAttributes.Entry

    weak var store: AppStore?
    private var observing = false
    private var reportedTokens: Set<String> = []
    /// Push-to-Start-Token, das noch nicht gemeldet werden konnte (z. B. weil die App noch nicht verbunden war).
    private var pendingStartToken: String?
    /// Update-Tokens von Aktivitäten, die noch nicht gemeldet werden konnten.
    private var pendingActivityTokens: Set<String> = []
    /// Server-Sitzung der gemeinsamen Aktivität (`run_id` beim Token-Melden).
    private var session: String?
    private var ensuring = false
    /// `ensure` höchstens alle 30 s (außer die Menge arbeitender Scoops ändert sich).
    private var lastEnsure: (at: Date, busy: Set<String>) = (.distantPast, [])
    private var lastSnapshot: WidgetSnapshot?
    /// `-livedemo`: lokal gestartete Demo-Aktivität, nicht vom Schnappschuss überschreiben.
    private var demoRunning = false

    private nonisolated static let staleInterval: TimeInterval = 30 * 60
    /// Abgeschlossene Einträge bleiben so lange in der Liste (lokale Aktualisierung).
    private nonisolated static let keepFinished: TimeInterval = 10 * 60

    // MARK: Beobachten

    /// Beobachtet Push-to-Start-Token und neue Aktivitäten (einmal pro App-Start) und räumt alte Aktivitäten weg.
    func startObserving() {
        guard !observing else { return }
        observing = true
        Self.endLegacyActivities()
        Task.detached {
            for await data in Activity<ScoopsLiveAttributes>.pushToStartTokenUpdates {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                await LiveActivityManager.shared.registerStartToken(hex)
            }
        }
        Task.detached {
            // Bereits laufende Aktivitäten (z. B. nach Neustart der App) ebenfalls beobachten
            for activity in Activity<ScoopsLiveAttributes>.activities { LiveActivityManager.observeTokens(activityID: activity.id) }
            for await activity in Activity<ScoopsLiveAttributes>.activityUpdates {
                LiveActivityManager.observeTokens(activityID: activity.id)
            }
        }
    }

    /// App kommt in den Vordergrund: aufräumen, liegengebliebene Tokens melden, mit dem letzten Stand abgleichen.
    func appBecameActive() {
        startObserving()
        Self.endLegacyActivities()
        Task { await self.flushPending() }
        if let lastSnapshot { sync(with: lastSnapshot) }
    }

    /// Beobachtet das Update-Token einer Aktivität (per ID gesucht, damit nichts Nicht-Sendable die Isolation wechselt).
    /// Aktivitäten mit Broadcast-Kanal liefern keine Tokens; die Schleife wartet dann einfach.
    private nonisolated static func observeTokens(activityID: String) {
        Task.detached {
            guard let activity = Activity<ScoopsLiveAttributes>.activities.first(where: { $0.id == activityID }) else { return }
            for await data in activity.pushTokenUpdates {
                let hex = data.map { String(format: "%02x", $0) }.joined()
                await LiveActivityManager.shared.reportActivityToken(hex)
            }
        }
    }

    private func registerStartToken(_ hex: String) async {
        let key = "start:\(hex)"
        guard !reportedTokens.contains(key) else { return }
        pendingStartToken = hex
        guard let store, store.phase == .online, !store.isMock else { return }
        do {
            try await store.registerDevice(DeviceRegistration(apnsToken: hex, platform: "ios-scoops-live-start",
                                                              name: UIDevice.current.name))
            reportedTokens.insert(key)
            if pendingStartToken == hex { pendingStartToken = nil }
        } catch {}
    }

    private func reportActivityToken(_ hex: String) async {
        guard !reportedTokens.contains("activity:\(hex)") else { return }
        pendingActivityTokens.insert(hex)
        guard let store, store.phase == .online, !store.isMock else { return }
        if session == nil { session = await store.liveActivityStatus(ensure: false)?.session }
        guard let session else { return }
        if await store.registerLiveActivity(chatID: "scoops", runID: session, pushToken: hex) {
            reportedTokens.insert("activity:\(hex)")
            pendingActivityTokens.remove(hex)
        }
    }

    private func flushPending() async {
        if let pendingStartToken { await registerStartToken(pendingStartToken) }
        for hex in pendingActivityTokens { await reportActivityToken(hex) }
    }

    // MARK: Abgleich mit dem Schnappschuss

    func sync(with snapshot: WidgetSnapshot) {
        lastSnapshot = snapshot
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        startObserving()
        // Im Hintergrund aktualisiert der Server per Push; Aktivitäten dürfen nur im Vordergrund starten.
        guard UIApplication.shared.applicationState == .active, !demoRunning,
              let store, store.isMock || store.phase == .online, !snapshot.bots.isEmpty else { return }
        if store.phase == .online, pendingStartToken != nil || !pendingActivityTokens.isEmpty {
            Task { await self.flushPending() }
        }

        Self.keepNewestOnly()
        let busy = snapshot.bots.filter(\.busy)
        let current = Self.currentActivity()

        if busy.isEmpty {
            // Kein Scoop arbeitet mehr: Aktivität mit Endzustand beenden, wenn sie noch „running“ zeigt.
            if let current, current.state.scoops.contains(where: \.isRunning) {
                let now = Date()
                let done = State(scoops: current.state.scoops.map { e in
                    var e = e
                    if e.isRunning { e.state = "done"; e.statusLine = String(localized: "Fertig", comment: "Live-Aktivität: Scoop hat seine Arbeit beendet"); e.finishedAt = now }
                    return e
                }, updatedAt: now)
                Self.end(id: current.id, state: done, after: 5)
            }
            return
        }

        if let current {
            let merged = Self.merge(current.state, with: snapshot)
            if merged.scoops != current.state.scoops { Self.update(id: current.id, state: merged) }
            return
        }

        // Keine Aktivität, aber ein Scoop arbeitet → Sitzung beim Server sicherstellen und lokal starten.
        let busyIDs = Set(busy.map(\.id))
        guard !ensuring, busyIDs != lastEnsure.busy || Date().timeIntervalSince(lastEnsure.at) > 30 else { return }
        ensuring = true
        lastEnsure = (Date(), busyIDs)
        Task {
            defer { self.ensuring = false }
            if store.isMock {
                // Demo: kein Server, rein lokal ohne Push.
                guard Self.currentActivity() == nil else { return }
                Self.request(state: Self.merge(nil, with: snapshot), channel: nil, push: false)
                return
            }
            guard let status = await store.liveActivityStatus(ensure: true) else { return }
            self.session = status.session ?? self.session
            guard status.active, Self.currentActivity() == nil,
                  UIApplication.shared.applicationState == .active else { return }
            let state = status.content ?? Self.merge(nil, with: self.lastSnapshot ?? snapshot)
            Self.request(state: state, channel: status.channel, push: true)
        }
    }

    /// Baut den Inhalt aus dem Schnappschuss; übernimmt Schritte/abgeschlossene Einträge aus dem bisherigen Stand.
    private static func merge(_ old: State?, with snapshot: WidgetSnapshot) -> State {
        let now = Date()
        let previous = Dictionary((old?.scoops ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var scoops: [Entry] = []
        for bot in snapshot.bots where bot.busy {
            let before = previous[bot.id]
            let startedAt = bot.runStartedAt ?? (before?.isRunning == true ? before!.startedAt : now)
            scoops.append(Entry(id: bot.id, name: bot.name, label: bot.label, mascot: bot.mascot, state: "running",
                                statusLine: bot.statusLine ?? before?.statusLine ?? String(localized: "Arbeitet …"),
                                steps: before?.isRunning == true ? before!.steps : 0,
                                startedAt: startedAt, finishedAt: nil))
        }
        // Bisher Laufende, die nicht mehr arbeiten → fertig; Abgeschlossene eine Weile behalten.
        for e in old?.scoops ?? [] where !scoops.contains(where: { $0.id == e.id }) && snapshot.bot(e.id) != nil {
            var e = e
            if e.isRunning { e.state = "done"; e.statusLine = String(localized: "Fertig", comment: "Live-Aktivität: Scoop hat seine Arbeit beendet"); e.finishedAt = now }
            if now.timeIntervalSince(e.finishedAt ?? now) < keepFinished { scoops.append(e) }
        }
        return State(scoops: scoops, updatedAt: old.map { scoops == $0.scoops ? $0.updatedAt : now } ?? now)
    }

    // MARK: Demo (`-livedemo`)

    /// Startet lokal eine Scoops-Aktivität mit drei Beispiel-Einträgen (Screenshots/Designprüfung).
    func startDemo() {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            NSLog("[LiveActivity] Live-Aktivitäten sind deaktiviert")
            return
        }
        demoRunning = true
        startObserving()
        for id in Self.allActivityIDs() { Self.end(id: id, state: nil, after: 0) }
        let now = Date()
        let state = State(scoops: [
            Entry(id: "b_mila", name: "Mila", label: demoText("Recherche", en: "Research"),
                  mascot: Mascot(shape: "bean", color: "#FF5FA8", eyes: "dots", accessory: "beret"),
                  state: "running", statusLine: demoText("Vergleicht drei Angebote", en: "Compares three quotes"), steps: 4,
                  startedAt: now.addingTimeInterval(-94), finishedAt: nil),
            Entry(id: "b_theo", name: "Theo", label: nil,
                  mascot: Mascot(shape: "cloud", color: "#3D84F5", eyes: "ovals", accessory: "glasses"),
                  state: "running", statusLine: demoText("Ist im Browser auf google.com", en: "Browses google.com"), steps: 7,
                  startedAt: now.addingTimeInterval(-312), finishedAt: nil),
            Entry(id: "b_tina", name: "Tina", label: nil,
                  mascot: Mascot(shape: "egg", color: "#FFB524", eyes: "happy", accessory: "headphones"),
                  state: "done", statusLine: demoText("Fertig", en: "Done"), steps: 3,
                  startedAt: now.addingTimeInterval(-600), finishedAt: now.addingTimeInterval(-30)),
        ], updatedAt: now)
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            Self.request(state: state, channel: nil, push: false)
        }
    }

    // MARK: ActivityKit (außerhalb des MainActors; Aktivitäten werden per ID gesucht)

    private nonisolated static func allActivityIDs() -> [String] {
        Activity<ScoopsLiveAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }.map(\.id)
    }

    /// Die neueste aktive Scoops-Aktivität (größtes `updatedAt`, bei Gleichstand die zuletzt gelistete).
    private nonisolated static func currentActivity() -> (id: String, state: State)? {
        let list = Activity<ScoopsLiveAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        guard let newest = list.enumerated().max(by: { a, b in
            let (ua, ub) = (a.element.content.state.updatedAt, b.element.content.state.updatedAt)
            return ua == ub ? a.offset < b.offset : ua < ub
        })?.element else { return nil }
        return (newest.id, newest.content.state)
    }

    /// Mehrere Scoops-Aktivitäten → nur die neueste behalten.
    private nonisolated static func keepNewestOnly() {
        guard let keep = currentActivity()?.id else { return }
        for id in allActivityIDs() where id != keep { end(id: id, state: nil, after: 0) }
    }

    /// Alte Einzel-Aktivitäten (eine pro Lauf) sofort beenden; sie hingen teils stundenlang auf „Denkt nach“.
    private nonisolated static func endLegacyActivities() {
        Task.detached {
            for a in Activity<BotRunAttributes>.activities {
                await a.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private nonisolated static func request(state: State, channel: String?, push: Bool) {
        do {
            let pushType: PushType? = push ? (channel.map { .channel($0) } ?? .token) : nil
            let activity = try Activity.request(
                attributes: ScoopsLiveAttributes(title: ScoopsLiveAttributes.defaultTitle),
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleInterval)),
                pushType: pushType)
            if pushType == .token { observeTokens(activityID: activity.id) }
        } catch {
            NSLog("[LiveActivity] Start fehlgeschlagen: %@", String(describing: error))
        }
    }

    private nonisolated static func update(id: String, state: State) {
        Task.detached {
            for a in Activity<ScoopsLiveAttributes>.activities where a.id == id {
                await a.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleInterval)))
            }
        }
    }

    private nonisolated static func end(id: String, state: State?, after seconds: Double) {
        Task.detached {
            for a in Activity<ScoopsLiveAttributes>.activities where a.id == id {
                let content = state.map { ActivityContent(state: $0, staleDate: nil) }
                await a.end(content, dismissalPolicy: seconds > 0 ? .after(Date().addingTimeInterval(seconds)) : .immediate)
            }
        }
    }
}
#endif
