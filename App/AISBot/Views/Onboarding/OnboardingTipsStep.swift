import SwiftUI

/// Nach der ersten Antwort: kurze, einmalige Tipps (Freigaben, Widgets, Watch). Abschaltbar in den Einstellungen
/// unter „Einführung“. Was auf dem Gerät keinen Sinn ergibt, fehlt (Watch nur auf dem iPhone, Freigaben nur mit Konto).
struct OnboardingTipsStep: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        OnboardingPage {
            WelcomeCrew(scale: 0.7).padding(.top, 20)
            OnboardingTitle(title: "Gut zu wissen", text: "Drei Kleinigkeiten, die den Alltag mit deinen Scoops leichter machen.")
            VStack(spacing: 12) {
                if store.account.isSignedIn {
                    OnboardingInfoCard(icon: "person.2.fill", title: "Scoops teilen",
                                       text: "Teile einen Scoop mit Familie oder Freunden: im Profil des Scoops unter „Teilen“. Du bestimmst, was sie dürfen.")
                }
                OnboardingInfoCard(icon: "square.grid.2x2.fill", title: "Widgets", text: widgetText)
                #if os(iOS)
                if UIDevice.current.userInterfaceIdiom == .phone {
                    OnboardingInfoCard(icon: "applewatch", title: "Auf der Apple Watch",
                                       text: "Lies Antworten und diktiere deine Nachrichten direkt auf der Uhr. Installiere AIS Scoops dazu in der Watch-App deines iPhone.")
                }
                #endif
            }
            Text("Die Einführung kannst du jederzeit in den Einstellungen unter „Einführung“ erneut ansehen.")
                .font(.footnote)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
        } actions: {
            Button("Los geht’s") { finish() }
                .buttonStyle(OnboardingButtonStyle())
                .keyboardShortcut(.defaultAction)
        }
    }

    private var widgetText: LocalizedStringKey {
        #if os(macOS)
        "Rechtsklick auf den Schreibtisch, dann „Widgets bearbeiten“ und „AIS Scoops“: So siehst du deine Scoops und ihre letzten Nachrichten auf einen Blick."
        #else
        "Drück lange auf den Home-Bildschirm, tippe auf „Bearbeiten“ und „Widget hinzufügen“ und wähle „AIS Scoops“. So siehst du deine Scoops auf einen Blick."
        #endif
    }

    private func finish() {
        let botID = store.onboarding.firstBotID
        store.onboarding.finish()
        if let botID { store.openChat(botID) }
    }
}
