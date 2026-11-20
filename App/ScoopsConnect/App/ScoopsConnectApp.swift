import AppKit
import SwiftUI

@main
struct ScoopsConnectApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuPanel(model: delegate.model, server: delegate.server)
        } label: {
            MenuBarLabel(model: delegate.model, server: delegate.server)
        }
        .menuBarExtraStyle(.window)

        Window("AIS Scoops Server", id: WindowID.main) {
            MainWindowView(model: delegate.model, server: delegate.server)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(delegate.showWindowAtLaunch ? .presented : .suppressed)

        // Nur für Screenshots/Tests (Debug, `-menupreview`): das Menü-Panel als normales Fenster.
        Window("Menü-Vorschau", id: WindowID.menuPreview) {
            MenuPanel(model: delegate.model, server: delegate.server)
                .background(.regularMaterial)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultLaunchBehavior(LaunchOptions.shared.menuPreview ? .presented : .suppressed)
    }
}

/// Symbol in der Menüleiste; öffnet außerdem das Hauptfenster, wenn ein Kopplungslink ankommt.
private struct MenuBarLabel: View {
    let model: AppModel
    let server: ServerController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: server.isServer ? server.menuBarSymbol : model.menuBarSymbol)
            .accessibilityLabel(server.isServer ? "AIS Scoops Server – \(server.manager.statusTitle)"
                                                : "Scoops Connect – \(model.statusTitle)")
            .onReceive(NotificationCenter.default.publisher(for: .openMainWindow)) { _ in
                openWindow(id: WindowID.main)
                NSApp.activate()
            }
    }
}
