#if os(macOS) && DEBUG
import AppKit

/// Startargument `-sidebarshrinktest` (nur Debug): ahmt einen Bildschirmwechsel nach, bei dem das Fenster in einem
/// Schritt schmaler und danach wieder breiter wird. `setFrame` umgeht dabei – wie der Wechsel auf einen anderen
/// Bildschirm – die Mindestgröße, die beim Aufziehen mit der Maus gilt. Protokolliert den Zustand der Seitenleiste.
/// `-sidebarshrinktest collapse` klappt im schmalen Zustand zusätzlich das Seitenleisten-Item direkt in AppKit ein,
/// wie es AppKit bei zu schmalem Fenster selbst tut (an SwiftUI vorbei).
@MainActor
enum SidebarShrinkTest {
    private static weak var store: AppStore?

    static func run(store: AppStore, collapse: Bool) {
        Self.store = store
        Task {
            try? await Task.sleep(for: .seconds(4))
            guard let window = NSApp.windows.first(where: { $0.isVisible && $0.styleMask.contains(.titled) }) else { return }
            var frame = window.frame
            let wide = max(frame.width, 1300)
            log(window, "vorher")
            frame.size.width = 600
            window.setFrame(frame, display: true)
            if collapse, let item = window.contentView.flatMap(sidebarItem) {
                item.isCollapsed = true
            }
            try? await Task.sleep(for: .seconds(1))
            log(window, "schmal")
            try? await Task.sleep(for: .seconds(3))
            frame.size.width = wide
            window.setFrame(frame, display: true)
            try? await Task.sleep(for: .seconds(1))
            log(window, "breit")
            try? await Task.sleep(for: .seconds(2))
            log(window, "breit +2 s")
        }
    }

    private static func log(_ window: NSWindow, _ step: String) {
        let item = window.contentView.flatMap(sidebarItem)
        NSLog("[shrinktest] %@: Fenster %d, Seitenleiste %@, Store %@", step, Int(window.frame.width),
              item.map { $0.isCollapsed ? "eingeklappt" : "sichtbar" } ?? "nicht gefunden",
              store?.sidebarHidden == true ? "ausgeblendet" : "sichtbar")
    }

    private static func sidebarItem(in view: NSView) -> NSSplitViewItem? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
           let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) { return item }
        return view.subviews.lazy.compactMap(sidebarItem).first
    }
}
#endif
