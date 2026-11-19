import SwiftUI

// ┌──────────────────────────────────────────────────────────────────────────────────────────────┐
// │ EINHÄNGESTELLE „Apple“ in „Apps verbinden“ (ConnectionsView)                                  │
// │                                                                                              │
// │ Der Chip „Apple“ steht direkt nach „Verbunden“ und zeigt statt der Composio-Liste diesen View.│
// │ Solange `isEnabled == false` ist, bleibt der Chip ausgeblendet.                               │
// │                                                                                              │
// │ Für die Apple-Dienste (Views/AppleConnectionsSection.swift) nur hier zwei Zeilen ändern:      │
// │   1. `isEnabled` auf `true` setzen                                                            │
// │   2. im `body` `AppleConnectionsSection()` einsetzen                                          │
// │ ConnectionsView.swift selbst muss dafür nicht angefasst werden.                              │
// └──────────────────────────────────────────────────────────────────────────────────────────────┘

/// Inhalt der Kategorie „Apple“ in „Apps verbinden“: Apple-Dienste (Erinnerungen, Kalender, Kontakte).
struct ConnectionsAppleSlot: View {
    /// Chip „Apple“ anzeigen?
    static let isEnabled = true

    var body: some View {
        AppleConnectionsSection()
    }
}
