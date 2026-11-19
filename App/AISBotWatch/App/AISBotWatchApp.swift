import SwiftUI
import UserNotifications
import WatchKit

@main
struct AISBotWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @State private var store: WatchStore

    init() {
        let store = WatchStore()
        _store = State(initialValue: store)
        WatchAppDelegate.store = store
        WatchSession.shared.activate()
    }

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .environment(\.theme, .nacht)
                .onOpenURL { url in
                    if let route = WatchRoute(url: url) { store.open(route) }
                }
                .task { WatchLaunch.apply(to: store) }
        }
        .backgroundTask(.appRefresh(WatchAppDelegate.refreshTaskID)) {
            await WatchAppDelegate.backgroundRefresh()
        }
    }
}

/// Mitteilungs-Aktionen (Freigeben/Ablehnen an gespiegelten iPhone-Mitteilungen) und Hintergrund-Aktualisierung
final class WatchAppDelegate: NSObject, WKApplicationDelegate, UNUserNotificationCenterDelegate {
    static weak var store: WatchStore?
    static let refreshTaskID = "scoops-refresh"

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().delegate = self
        ApprovalNotificationActions.register()
        Self.scheduleRefresh()
    }

    func applicationDidBecomeActive() {
        guard let store = Self.store else { return }
        Task { await store.refresh() }
    }

    static func scheduleRefresh() {
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: Date().addingTimeInterval(20 * 60),
                                                         userInfo: nil) { _ in }
    }

    /// Hält die Komplikationen aktuell (watchOS weckt die App etwa alle 20–30 Minuten)
    static func backgroundRefresh() async {
        if let store { await store.refresh() }
        scheduleRefresh()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping @Sendable () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        let approvalID = ApprovalNotificationActions.approvalID(in: userInfo)
        let chatID = (userInfo[ApprovalNotificationActions.chatIDKey] as? String) ?? (userInfo["bot_id"] as? String)
        Task { @MainActor in
            guard let store = WatchAppDelegate.store else { completionHandler(); return }
            if let raw = ApprovalNotificationActions.decision(for: action), let decision = ApprovalDecision(rawValue: raw),
               let approvalID {
                _ = await store.decide(approvalID: approvalID, decision: decision)
            } else if action == UNNotificationDefaultActionIdentifier, let chatID {
                store.open(.chat(id: chatID, compose: false))
            }
            completionHandler()
        }
    }
}

/// Steuerung für Screenshots: `-demo`, `-open chat:<id>|approvals`, `-compose`, `-anchor top|bottom|<0…1>`
enum WatchLaunch {
    /// Startposition des Chats (Store-Screenshots): `-anchor top` zeigt den Anfang, eine Zahl die relative Höhe.
    static let chatAnchor: UnitPoint = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-anchor"), i + 1 < args.count else { return .bottom }
        switch args[i + 1] {
        case "top": return .top
        case "bottom": return .bottom
        default: return Double(args[i + 1]).map { UnitPoint(x: 0.5, y: $0) } ?? .bottom
        }
    }()

    static func apply(to store: WatchStore) {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-open"), i + 1 < args.count else { return }
        let target = args[i + 1]
        if target == "approvals" {
            store.open(.approvals)
        } else if target.hasPrefix("chat:") {
            store.open(.chat(id: String(target.dropFirst(5)), compose: args.contains("-compose")))
        }
    }
}
