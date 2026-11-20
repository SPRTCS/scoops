import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Menü „Neu“: Neuer Scoop / Neue Gruppe (Seitenleiste und Navigationsleiste).
struct NewChatMenuItems: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            store.editingBot = nil
            store.showCreateBot = true
        } label: { Label("Neuer Scoop", systemImage: "sparkles") }
        Button {
            store.showCreateGroup = true
        } label: { Label("Neue Gruppe", systemImage: "person.3") }
        .disabled(store.bots.count < 2)
        Divider()
        Button {
            store.sectionPrompt = .create(moveChatID: nil)
        } label: { Label("Neuer Bereich", systemImage: "rectangle.stack.badge.plus") }
    }
}

#if os(iOS)
/// Systemleisten-Knöpfe für iPhone, iPhone Duo und iPad: „Neu“ (square.and.pencil), „Apps verbinden“ (link), „Aufgaben“
/// (checklist, Board, v1.22). Solange die Tastatur sichtbar ist, steht stattdessen „Tastatur schließen“ sichtbar
/// und die drei anderen liegen in einem Drei-Punkte-Menü. Auf dem iPhone Duo setzt das System diese Toolbar-Einträge
/// in seine senkrechte Leiste am Rand (eigene Platzierungen gibt es dafür nicht; `toolbarVerticalEdge`
/// meldet nur, an welchem Rand sie liegt). Ab iOS 27 bleibt „Neu“ per `.topBarPinnedTrailing` immer sichtbar.
struct SystemBarItems: ToolbarContent {
    /// Vom umgebenden View übergeben (dort wird die Beobachtung zuverlässig ausgelöst).
    var keyboardVisible: Bool
    /// „Neu“, „Apps verbinden“ und „Aufgaben“ zeigen. Sie stehen immer nur an einer Stelle: iPhone in der
    /// Seitenleiste oben, iPad unten in der Seitenleiste (`SidebarActionBar`), bei eingeklappter Seitenleiste oben
    /// rechts im Chat, iPhone Duo aufgeklappt in der senkrechten Systemleiste des Chats.
    var showActions: Bool = true
    /// Untere Leiste statt oben rechts: iPad, unten in der Seitenleiste (siehe `SidebarActionBar`)
    var atBottom: Bool = false
    /// iPhone-Chat (seit App 1.3 steht dort auch die Suche im Chat; mit vier Knöpfen blieb vom Namen nur „…“):
    /// „Aufgaben“ bleibt ein eigener Knopf (ein Tipp, zeigt an, wenn Aufgaben warten), „Neu“ und „Apps verbinden“
    /// liegen im Drei-Punkte-Menü. Im Chat legt man selten einen neuen Scoop an; in der Chatliste steht „Neu“ wie bisher.
    var collapseActions: Bool = false

    @Environment(AppStore.self) private var store

    var body: some ToolbarContent {
        if atBottom {
            bottomItems
        } else {
            topItems
        }
    }

    @ToolbarContentBuilder
    private var bottomItems: some ToolbarContent {
        // Links unten in der Seitenleiste, unter der Chatliste (die Liste läuft unter dem Glas durch)
        if showActions {
            ToolbarItem(placement: .bottomBar) { newMenu }
            ToolbarItem(placement: .bottomBar) { connectionsButton }
            ToolbarItem(placement: .bottomBar) { tasksButton }
        }
        if keyboardVisible {
            ToolbarItem(placement: .bottomBar) { keyboardButton }
        }
        ToolbarSpacer(.flexible, placement: .bottomBar)
    }

    @ToolbarContentBuilder
    private var topItems: some ToolbarContent {
        if keyboardVisible {
            // Tastatur offen: „Tastatur schließen“ steht sichtbar (angepinnt), „Neu“, „Apps verbinden“ und „Aufgaben“
            // wandern gemeinsam in ein Drei-Punkte-Menü. Vorher steckte „Tastatur schließen“ selbst im Überlauf-Menü.
            if showActions {
                if #available(iOS 27, *) {
                    ToolbarItem(placement: .topBarTrailing) { moreMenu }
                    ToolbarItem(placement: .topBarPinnedTrailing) { keyboardButton }
                } else {
                    ToolbarItem(placement: .topBarTrailing) { moreMenu }
                    ToolbarItem(placement: .topBarTrailing) { keyboardButton }
                }
            } else {
                ToolbarItem(placement: .topBarTrailing) { keyboardButton }
            }
        } else if showActions, collapseActions {
            if #available(iOS 27, *) {
                ToolbarItem(placement: .topBarTrailing) { tasksButton }
                ToolbarItem(placement: .topBarPinnedTrailing) { actionsMenu }
            } else {
                ToolbarItem(placement: .topBarTrailing) { tasksButton }
                ToolbarItem(placement: .topBarTrailing) { actionsMenu }
            }
        } else if showActions {
            if #available(iOS 27, *) {
                // Angepinnt zeigt iOS 27 nur einen Eintrag: „Neu“ bleibt angepinnt, die anderen stehen daneben
                // Bei Platzmangel (iPhone Duo, Tastatur offen) wandern „Apps verbinden“ und „Aufgaben“ zuerst ins
                // Überlauf-Menü, damit der Name des Chats nicht zu „L…“ gekürzt wird
                ToolbarItem(placement: .topBarTrailing) { connectionsButton }
                    .visibilityPriority(.low)
                ToolbarItem(placement: .topBarTrailing) { tasksButton }
                    .visibilityPriority(.low)
                ToolbarItem(placement: .topBarPinnedTrailing) { newMenu }
            } else {
                ToolbarItem(placement: .topBarTrailing) { newMenu }
                ToolbarItem(placement: .topBarTrailing) { connectionsButton }
                ToolbarItem(placement: .topBarTrailing) { tasksButton }
            }
        }
    }

    private var keyboardButton: some View {
        Button {
            KeyboardMonitor.dismiss()
        } label: {
            Label("Tastatur schließen", systemImage: "keyboard.chevron.compact.down")
        }
    }

    private var connectionsButton: some View {
        Button { store.showConnections = true } label: {
            Label("Apps verbinden", systemImage: "link")
        }
        .accessibilityLabel("Apps verbinden")
    }

    /// Aufgaben-Board (alle Scoops)
    private var tasksButton: some View {
        Button { store.showTaskBoard.toggle() } label: {
            Label("Aufgaben", systemImage: store.taskBoard.attentionCount > 0 ? "checklist.unchecked" : "checklist")
        }
        .accessibilityLabel(store.taskBoard.attentionCount > 0
                            ? "Aufgaben, \(store.taskBoard.attentionCount) brauchen dich" : "Aufgaben")
    }

    /// Drei-Punkte-Menü bei offener Tastatur: „Neu“ (als Untermenü), „Apps verbinden“, „Aufgaben“
    private var moreMenu: some View {
        Menu {
            Menu {
                NewChatMenuItems()
                Divider()
                PaletteMenuButton()
            } label: {
                Label("Neu", systemImage: "square.and.pencil")
            }
            connectionsButton
            tasksButton
        } label: {
            Label("Mehr", systemImage: "ellipsis")
        }
        .accessibilityLabel("Mehr: Neu, Apps verbinden, Aufgaben")
    }

    /// Drei-Punkte-Menü im iPhone-Chat: Neuer Scoop, Neue Gruppe, Neuer Bereich, Apps verbinden, Befehle (siehe
    /// `collapseActions`)
    private var actionsMenu: some View {
        Menu {
            NewChatMenuItems()
            Divider()
            connectionsButton
            PaletteMenuButton()
        } label: {
            Label("Mehr", systemImage: "ellipsis")
        }
        .accessibilityLabel("Mehr: Neu, Apps verbinden, Befehle")
    }

    private var newMenu: some View {
        Menu {
            NewChatMenuItems()
            Divider()
            PaletteMenuButton()
        } label: {
            Label("Neu", systemImage: "square.and.pencil")
        }
        .accessibilityLabel("Neuer Scoop oder neue Gruppe")
    }
}

/// iPad: „Neu“, „Apps verbinden“ und „Aufgaben“ als schwebende Glas-Kapsel unten links in der Seitenleiste, neben
/// den Scoops. Das Nachrichtenfeld im Chat bleibt damit ganz unten (vorher stand die Kapsel unten im Chat und schob
/// das Feld nach oben). iPhone Duo aufgeklappt (senkrechte Systemleiste) nicht: Dort bleiben die Knöpfe oben im Chat,
/// wo das System sie hinsetzt. Bei eingeklappter Seitenleiste übernimmt der Chat (`sidebarCarriesActions`).
struct SidebarActionBar: ViewModifier {
    /// Nur in der Split-Seitenleiste (iPad, Duo aufgeklappt), nicht auf dem iPhone
    var enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(Reader(enabled: enabled))
        } else {
            content.toolbar {
                if enabled { SystemBarItems(keyboardVisible: false, atBottom: true) }
            }
        }
    }

    @available(iOS 27.1, *)
    private struct Reader: ViewModifier {
        let enabled: Bool
        @Environment(\.toolbarVerticalEdge) private var verticalEdge

        func body(content: Content) -> some View {
            content.toolbar {
                if enabled && verticalEdge == nil {
                    SystemBarItems(keyboardVisible: false, atBottom: true)
                }
            }
        }
    }
}

/// Stehen „Neu“, „Apps verbinden“ und „Aufgaben“ gerade unten in der Seitenleiste (`SidebarActionBar`)? Nur auf dem
/// iPad mit waagerechter Systemleiste und sichtbarer Seitenleiste; Chat und Platzhalter zeigen sie dann nicht.
@MainActor
func sidebarCarriesActions(store: AppStore, verticalBar: Bool) -> Bool {
    !verticalBar && !store.sidebarHidden
}

/// Systemknöpfe ohne geöffneten Chat (nur breite Darstellung): iPad oben rechts, solange die Seitenleiste
/// eingeklappt ist (sonst stehen sie unten in der Seitenleiste), iPhone Duo dort, wo das System sie hinsetzt.
struct PlaceholderSystemBar: ViewModifier {
    @Environment(AppStore.self) private var store

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.modifier(Reader())
        } else {
            content.toolbar {
                SystemBarItems(keyboardVisible: false, showActions: !sidebarCarriesActions(store: store, verticalBar: false))
            }
        }
    }

    @available(iOS 27.1, *)
    private struct Reader: ViewModifier {
        @Environment(\.toolbarVerticalEdge) private var verticalEdge
        @Environment(AppStore.self) private var store

        func body(content: Content) -> some View {
            let inSidebar = sidebarCarriesActions(store: store, verticalBar: verticalEdge != nil)
            content.toolbar { SystemBarItems(keyboardVisible: false, showActions: !inSidebar) }
        }
    }
}

/// „Befehle …“ im Neu-Menü (iPhone/iPad ohne Hardware-Tastatur; mit Tastatur ⌘K).
struct PaletteMenuButton: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        Button { store.showCommandPalette = true } label: { Label("Befehle …", systemImage: "command") }
    }
}

/// Tastatur schließen (die Sichtbarkeit melden die Eingabefelder über ihren Fokus).
enum KeyboardMonitor {
    static func dismiss() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
#endif
