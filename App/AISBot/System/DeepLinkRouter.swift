import CoreSpotlight
import Foundation
import Observation

/// Öffnet tiefe Links (`DeepLink`) in der App: Chat, „Neue Nachricht“, Sprechmodus, „Heute“, Ablage.
///
/// Kommt ein Link, bevor die Chats geladen sind (Kaltstart, Verbindung wird aufgebaut, noch kein Server
/// verbunden, Einführung offen), merkt der Router ihn vor und löst ihn ein, sobald der Chat da ist.
final class DeepLinkRouter {
    static let shared = DeepLinkRouter()

    private weak var store: AppStore?
    private var pending: (link: DeepLink, since: Date)?
    /// Öffnet die Seite „Heute“ (setzt das Paket, das die Seite baut). Ohne Handler kommt nur die App nach vorn.
    var openToday: (() -> Void)?
    /// Vorgemerkte Links verfallen, damit die App nicht viel später unerwartet springt
    private static let pendingLifetime: TimeInterval = 600

    func start(store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        SystemBridge.shared.linkHandler = { [weak self] link in self?.open(link) }
        observe()
    }

    func open(_ url: URL) -> Bool {
        guard let link = DeepLink(url: url) else { return false }
        open(link)
        return true
    }

    func open(_ link: DeepLink) {
        if !apply(link) { pending = (link, Date()) }
    }

    /// Spotlight-Treffer (`CSSearchableItemActionType`)
    func open(_ activity: NSUserActivity) {
        guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
              let link = SpotlightIndexer.link(forItemID: id) else { return }
        open(link)
    }

    // MARK: Vorgemerkt

    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.phase
            _ = store.bots
            _ = store.groups
            _ = store.sharedBots
            _ = store.onboardingPresentation
            _ = store.account.sharedLoaded
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.retryPending()
                self?.observe()
            }
        }
    }

    private func retryPending() {
        guard let waiting = pending else { return }
        guard Date().timeIntervalSince(waiting.since) < Self.pendingLifetime else {
            pending = nil
            return
        }
        if apply(waiting.link) { pending = nil }
    }

    // MARK: Anwenden

    /// `true`: erledigt (oder endgültig nicht möglich). `false`: später noch einmal versuchen.
    private func apply(_ link: DeepLink) -> Bool {
        guard let store else { return false }
        switch link {
        case .outbox:
            ShareOutboxSender.shared.deliverSoon()
            return true
        case .today:
            // Erst wenn die Verbindung steht, weiß die App, ob der Server die Seite kennt (Kaltstart: warten).
            // Reine Gast-Verbindungen und ältere Server haben keine Seite „Heute“: Dann kommt nur die App nach vorn.
            guard store.onboardingPresentation == nil else { return false }
            switch store.phase {
            case .connecting: return false
            case .unconfigured where store.sharedBots.isEmpty: return false
            default: break
            }
            openToday?()
            return true
        case .chat(let id, let server, let compose):
            guard let chatID = resolve(id, server: server, store: store) else { return isFinal(id, server: server, store: store) }
            store.voiceChatID = nil
            store.openChat(chatID)
            store.showInspector = false
            if compose {
                // Das Eingabefeld gibt es erst, wenn der Chat aufgebaut ist
                Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    store.composerFocusRequest += 1
                }
            }
            return true
        case .voice(let id, let server):
            guard let chatID = resolve(id, server: server, store: store) else { return isFinal(id, server: server, store: store) }
            // Sprechmodus ist ein Einzelgespräch: bei einer Gruppe nur den Chat öffnen
            store.openChat(chatID)
            store.showInspector = false
            if ChatGroup.isGroupID(chatID) || !store.canWrite(chatID) {
                store.showToast(String(localized: "Der Sprechmodus geht hier nicht."))
            } else {
                store.voiceChatID = chatID
            }
            return true
        }
    }

    /// Chat-ID, die es in der App gerade gibt. Ohne ID: Haupt-Scoop, sonst der erste eigene Scoop.
    private func resolve(_ id: String?, server: String?, store: AppStore) -> String? {
        guard store.onboardingPresentation == nil else { return nil }
        if let id { return store.chatExists(id) ? id : nil }
        return (store.primaryBot ?? store.bots.first ?? store.sharedBots.first)?.id
    }

    /// Chat nicht gefunden: Lohnt Warten (lädt noch), oder ist klar, dass es ihn hier nicht gibt?
    private func isFinal(_ id: String?, server: String?, store: AppStore) -> Bool {
        // Einführung, keine Verbindung oder Aufbau: warten
        guard store.onboardingPresentation == nil else { return false }
        let sharesLoading = store.account.isSignedIn && !store.account.sharedLoaded
        switch store.phase {
        case .unconfigured:
            // Nur geteilte Scoops ohne eigenen Server: Liste ist da, sobald „Mit mir geteilt“ geladen ist
            if sharesLoading || store.sharedBots.isEmpty { return false }
        case .connecting, .offline:
            return false
        case .online:
            if sharesLoading { return false }
        }
        if id == nil {
            store.showToast(String(localized: "Lege zuerst einen Scoop an."))
        } else if let server, let active = store.systemServerID, server != active, !store.guestConnections.keys.contains(server) {
            store.showToast(String(localized: "Dieser Scoop gehört zu einem anderen Server."))
        } else {
            store.showToast(String(localized: "Diesen Scoop gibt es nicht mehr."))
        }
        return true
    }
}
