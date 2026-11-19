import Foundation
import UserNotifications
import WidgetKit
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// APNs: registriert das Gerät (und auf iOS die Widgets) beim Bot-Server.
/// `POST /api/devices` ist idempotent, deshalb wird bei jedem Start und bei Token-Wechsel neu gemeldet.
final class PushManager {
    static let shared = PushManager()

    weak var store: AppStore?
    private(set) var deviceToken: String?
    private var registeredKeys: Set<String> = []

    /// true, sobald der Server unser APNs-Token kennt – dann übernimmt der Server die Mitteilungen
    /// und die App erzeugt keine eigenen lokalen Mitteilungen mehr (keine Dubletten).
    var isRegisteredWithServer: Bool { !registeredKeys.filter { $0.hasPrefix(platform + ":") }.isEmpty }

    /// `ios` bzw. `macos` (auch für die Meldung bei Admin-Servern geteilter Scoops)
    var platformName: String { platform }

    private var platform: String {
        #if os(iOS)
        "ios"
        #else
        "macos"
        #endif
    }

    private var deviceName: String {
        #if os(iOS)
        UIDevice.current.name
        #else
        Host.current().localizedName ?? "Mac"
        #endif
    }

    /// Fragt (beim ersten Mal) nach der Erlaubnis und registriert sich danach bei APNs.
    func requestAuthorizationAndRegister() {
        Task {
            let center = UNUserNotificationCenter.current()
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
            #if os(iOS)
            // Auch ohne Mitteilungs-Erlaubnis registrieren: Stille Pushes (Home, Wecker, Standort, v1.18) brauchen
            // nur das Geräte-Token, keine sichtbaren Mitteilungen.
            UIApplication.shared.registerForRemoteNotifications()
            _ = granted
            #else
            guard granted else { return }
            NSApplication.shared.registerForRemoteNotifications()
            #endif
        }
    }

    func didRegister(deviceToken data: Data) {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        if hex != deviceToken { registeredKeys = registeredKeys.filter { !$0.hasPrefix(platform + ":") } }
        deviceToken = hex
        #if DEBUG
        // Für Push-Tests im Simulator (echter Sandbox-Push, siehe README „Mitteilungen mit Scoop-Bild“).
        if ProcessInfo.processInfo.arguments.contains("-askpush") { NSLog("[Push] Geräte-Token: %@", hex) }
        #endif
        Task {
            await syncWithServer()
            await store?.registerGuestPushEverywhere()
            AppleDeviceAgent.shared.sendHello()  // Push-Token fürs Aufwecken (v1.18)
        }
    }

    func didFailToRegister(_ error: Error) {
        #if DEBUG
        print("[Push] Registrierung fehlgeschlagen: \(error.localizedDescription)")
        #endif
    }

    /// Meldet Geräte- und Widget-Token an den Server (nach jeder erfolgreichen Verbindung).
    func syncWithServer() async {
        guard let store, !store.isMock, store.phase == .online else { return }
        if let token = deviceToken {
            await register(token: token, platform: platform)
        }
        #if os(iOS)
        // Widget-Push (iOS 26+): Token kommt von WidgetKit, Thema com.ais.aisbot.push-type.widgets.
        if let data = await Self.widgetPushToken() {
            let hex = data.map { String(format: "%02x", $0) }.joined()
            await register(token: hex, platform: "ios-widgets")
        }
        #endif
    }

    #if os(iOS)
    /// Außerhalb des MainActors abfragen (WidgetCenter ist nicht Sendable).
    @concurrent private nonisolated static func widgetPushToken() async -> Data? {
        await WidgetCenter.shared.currentPushInfo?.token
    }
    #endif

    private func register(token: String, platform: String) async {
        let key = "\(platform):\(token)"
        guard !registeredKeys.contains(key), let store else { return }
        do {
            try await store.registerDevice(DeviceRegistration(apnsToken: token, platform: platform, name: deviceName))
            registeredKeys = registeredKeys.filter { !$0.hasPrefix(platform + ":") }
            registeredKeys.insert(key)
        } catch {
            #if DEBUG
            print("[Push] Server-Registrierung (\(platform)) fehlgeschlagen: \(error.localizedDescription)")
            #endif
        }
    }

    /// Bei Serverwechsel neu melden.
    func reset() { registeredKeys = [] }
}

#if os(iOS)
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushManager.shared.didFailToRegister(error)
    }

    /// Stille Push vom Server (`content-available`, v1.18): Befehl für Home, Wecker oder Standort abholen.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        let commandID = userInfo["apple_cmd"] as? String
        guard commandID != nil else { return .noData }
        return await AppleDeviceAgent.shared.handleWake(commandID: commandID) ? .newData : .noData
    }
}
#else
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        PushManager.shared.didRegister(deviceToken: deviceToken)
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        PushManager.shared.didFailToRegister(error)
    }
}
#endif
