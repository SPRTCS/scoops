#if os(macOS)
import AppKit
import SwiftUI

/// Maße des Mac-Fensters, auf die sich Fenster, Seitenleiste und Profil-Spalte beziehen.
enum MacWindowLayout {
    /// Kleinste Fensterbreite mit Seitenleiste (Seitenleiste 250 + Chat 510)
    static let minWidth: CGFloat = 760
    static let sidebarMinWidth: CGFloat = 250
    static let inspectorMinWidth: CGFloat = 280

    /// Fensterbreite, ab der Seitenleiste, Chat und ggf. das Profil nebeneinander passen.
    static func widthForSidebar(inspector: Bool) -> CGFloat {
        minWidth + (inspector ? inspectorMinWidth : 0)
    }
}

/// Hält die linke Seitenleiste (AppKit) und `AppStore.sidebarColumns` deckungsgleich.
///
/// Hintergrund: Unter `NavigationSplitView` liegt auf dem Mac ein `NSSplitViewController`. Dessen Seitenleisten-Item
/// klappt AppKit selbst ein, wenn das Fenster für alle Spalten zu schmal wird (`canCollapseFromWindowResize`), etwa
/// wenn das Fenster beim Wechsel auf einen anderen Bildschirm in einem Schritt schmaler wird. Wieder ausgeklappt wird
/// es nur während eines Live-Resize (Fenster mit der Maus aufziehen). Die SwiftUI-Bindung bekam davon nichts mit und
/// blieb auf `.all`: Die Seitenleiste blieb weg, es gab keinen sichtbaren Knopf (der System-Knopf ist entfernt), und
/// ⌃⌘S wollte sie beim ersten Druck „ausblenden“.
///
/// Die Ansicht beobachtet deshalb `isCollapsed` des Seitenleisten-Items und die Fenster-Ereignisse (Größe, Bildschirm,
/// Auflösung, Vollbild):
/// - Klappt AppKit die Leiste ein, übernimmt der Store den echten Zustand (`.detailOnly`), ohne das als Wunsch des
///   Nutzers zu werten. Ein Einklappen ohne Größenänderung (Ziehen am Trenner) gilt dagegen als bewusst.
/// - Ist das Fenster danach (wieder) breit genug und hat der Nutzer die Leiste nicht selbst ausgeblendet, fährt sie
///   wieder ein – einmal pro Fensterbreite, damit es kein Hin und Her mit AppKit gibt.
struct SidebarSync: NSViewRepresentable {
    let store: AppStore
    /// Rahmen der Ampelknöpfe im Fenster (oben links als Ursprung), `nil` im Vollbild
    var onTitlebarButtons: (CGRect?) -> Void = { _ in }

    func makeNSView(context: Context) -> SidebarSyncView {
        let view = SidebarSyncView()
        view.store = store
        view.onTitlebarButtons = onTitlebarButtons
        return view
    }

    func updateNSView(_ view: SidebarSyncView, context: Context) {
        view.store = store
        view.onTitlebarButtons = onTitlebarButtons
        view.scheduleReconcile()
    }

    static func dismantleNSView(_ view: SidebarSyncView, coordinator: ()) {
        view.detach()
    }
}

@MainActor
final class SidebarSyncView: NSView {
    weak var store: AppStore?
    var onTitlebarButtons: (CGRect?) -> Void = { _ in }

    private weak var observedWindow: NSWindow?
    private var tokens: [NSObjectProtocol] = []
    private weak var sidebarItem: NSSplitViewItem?
    private var collapseObservation: NSKeyValueObservation?
    private var reconcileTask: Task<Void, Never>?
    /// Letzte Größen- bzw. Bildschirmänderung: Ein Einklappen kurz danach kommt von AppKit, nicht vom Nutzer.
    private var lastWindowChange = Date.distantPast
    /// Fensterbreite beim letzten Ausklappen. Klappt AppKit bei derselben Breite wieder ein, nicht erneut versuchen.
    private var expandAttemptWidth: CGFloat?
    private var lastTitlebarFrame: CGRect??

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        attach(to: window)
    }

    func detach() {
        reconcileTask?.cancel()
        collapseObservation?.invalidate()
        collapseObservation = nil
        sidebarItem = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        observedWindow = nil
    }

    private func attach(to window: NSWindow?) {
        guard window !== observedWindow else { return }
        detach()
        guard let window else { return }
        observedWindow = window
        let center = NotificationCenter.default
        let changes: [Notification.Name] = [
            NSWindow.didResizeNotification, NSWindow.didChangeScreenNotification,
            NSWindow.didChangeBackingPropertiesNotification, NSWindow.didEndLiveResizeNotification,
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
        ]
        for name in changes {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.windowChanged(name) }
            })
        }
        observeStore()
        scheduleReconcile()
    }

    /// Profil auf/zu und Spaltenwechsel ändern, ob die Seitenleiste passt: danach abgleichen (nach der Animation).
    /// Über Beobachtung statt über `updateNSView`, damit `RootView` dafür nicht neu ausgewertet werden muss.
    private func observeStore() {
        guard let store, observedWindow != nil else { return }
        withObservationTracking {
            _ = store.showInspector
            _ = store.sidebarColumns
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observedWindow != nil else { return }
                self.scheduleReconcile(after: .milliseconds(450))
                self.observeStore()
            }
        }
    }

    private func windowChanged(_ name: Notification.Name) {
        if name != NSWindow.didEndLiveResizeNotification { lastWindowChange = Date() }
        // Während des Aufziehens mit der Maus regelt AppKit das Ein- und Ausklappen selbst; danach abgleichen.
        scheduleReconcile(after: .milliseconds(name == NSWindow.didEndLiveResizeNotification ? 30 : 180))
    }

    func scheduleReconcile(after delay: Duration = .milliseconds(60)) {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reconcile()
        }
    }

    // MARK: Abgleich

    private func reconcile() {
        guard let window = observedWindow, let store else { return }
        reportTitlebarButtons(in: window)
        guard let item = locateSidebarItem(in: window) else { return }
        guard !window.inLiveResize else { return }

        if item.isCollapsed {
            if store.sidebarColumns != .detailOnly {
                // Eingeklappt, ohne dass der Store davon weiß (AppKit, bevor die Beobachtung lief)
                Self.log("Abgleich: eingeklappt, Store stand auf sichtbar")
                setColumns(.detailOnly, animated: false)
            }
            let width = window.frame.width
            let needed = MacWindowLayout.widthForSidebar(inspector: store.showInspector)
            guard !store.sidebarHiddenByUser, width >= needed, expandAttemptWidth != width else { return }
            expandAttemptWidth = width
            Self.log("Wieder einblenden (Fenster \(Int(width)) ≥ \(Int(needed)))")
            setColumns(.all, animated: true)
            // Falls SwiftUI die Bindung nicht als Änderung sieht: das Item direkt ausklappen.
            Task { @MainActor [weak self, weak item] in
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let item, item.isCollapsed, self.store?.sidebarColumns == .all,
                      self.store?.sidebarHiddenByUser == false else { return }
                Self.log("Bindung wirkte nicht, Item direkt ausklappen")
                item.animator().isCollapsed = false
            }
        } else {
            expandAttemptWidth = nil
            if store.sidebarColumns == .detailOnly {
                Self.log("Abgleich: sichtbar, Store stand auf ausgeblendet")
                store.sidebarHiddenByUser = false
                setColumns(.all, animated: false)
            }
        }
    }

    private func collapseChanged(_ collapsed: Bool) {
        guard let store, let window = observedWindow else { return }
        if collapsed {
            guard !store.sidebarHiddenByUser else { return setColumns(.detailOnly, animated: false) }
            let resizing = window.inLiveResize || Date().timeIntervalSince(lastWindowChange) < 1.0
                || window.frame.width < MacWindowLayout.widthForSidebar(inspector: store.showInspector)
            // Ohne Größenänderung eingeklappt (am Trenner zugezogen): wie Ausblenden per Menü
            if !resizing { store.sidebarHiddenByUser = true }
            Self.log("Eingeklappt (\(resizing ? "durch AppKit" : "vom Nutzer"), Fenster \(Int(window.frame.width)))")
            setColumns(.detailOnly, animated: false)
        } else {
            Self.log("Ausgeklappt")
            store.sidebarHiddenByUser = false
            expandAttemptWidth = nil
            setColumns(.all, animated: false)
        }
    }

    private func setColumns(_ columns: NavigationSplitViewVisibility, animated: Bool) {
        guard let store, store.sidebarColumns != columns else { return }
        if animated {
            withAnimation(.snappy) { store.sidebarColumns = columns }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { store.sidebarColumns = columns }
        }
    }

    // MARK: AppKit-Hierarchie

    /// Seitenleisten-Item des Split-Views im Fenster (SwiftUI legt es ggf. neu an, z. B. nach dem Onboarding).
    private func locateSidebarItem(in window: NSWindow) -> NSSplitViewItem? {
        if let item = sidebarItem, item.viewController.view.window === window { return item }
        collapseObservation?.invalidate()
        collapseObservation = nil
        sidebarItem = nil
        guard let root = window.contentView, let item = Self.findSidebarItem(in: root) else { return nil }
        sidebarItem = item
        collapseObservation = item.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            let collapsed = item.isCollapsed
            Task { @MainActor [weak self] in self?.collapseChanged(collapsed) }
        }
        return item
    }

    private static func findSidebarItem(in view: NSView) -> NSSplitViewItem? {
        if let split = view as? NSSplitView, let controller = split.delegate as? NSSplitViewController,
           let item = controller.splitViewItems.first(where: { $0.behavior == .sidebar }) {
            return item
        }
        for subview in view.subviews {
            if let item = findSidebarItem(in: subview) { return item }
        }
        return nil
    }

    /// Rahmen der Ampelknöpfe für den Glas-Knopf daneben (nur bei Änderung melden).
    private func reportTitlebarButtons(in window: NSWindow) {
        var frame: CGRect?
        if !window.styleMask.contains(.fullScreen), let content = window.contentView,
           let close = window.standardWindowButton(.closeButton),
           let zoom = window.standardWindowButton(.zoomButton) {
            let rect = close.convert(close.bounds, to: nil).union(zoom.convert(zoom.bounds, to: nil))
            frame = CGRect(x: rect.minX, y: content.frame.height - rect.maxY, width: rect.width, height: rect.height)
        }
        guard lastTitlebarFrame != .some(frame) else { return }
        lastTitlebarFrame = .some(frame)
        onTitlebarButtons(frame)
    }

    private static func log(_ message: String) {
        #if DEBUG
        NSLog("[sidebar] %@", message)
        #endif
    }
}
#endif

#if os(macOS)
/// Runder Glas-Knopf „Seitenleiste einblenden“ oben links (Stil wie „Profil einblenden“ in `ChatMacHeader`).
struct SidebarRevealButton: View {
    static let size: CGFloat = 28
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        Button { store.setSidebarHidden(false) } label: {
            Image(systemName: "sidebar.left")
                .appFont(13, weight: .medium)
                .foregroundStyle(theme.textPrimary)
                .frame(width: Self.size, height: Self.size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(Glass.chatHeader(theme), in: .circle)
        .help("Seitenleiste einblenden (⌃⌘S)")
        .accessibilityLabel("Seitenleiste einblenden")
    }
}
#endif
