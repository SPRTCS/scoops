#if os(iOS)
import AlarmKit
import Foundation

/// Zusatzdaten der Wecker und Timer, die Scoops über `apple_wecker` stellen (AlarmKit, API v1.18).
/// App und Widget-Erweiterung teilen den Typ: Die Erweiterung zeigt damit den Countdown eines Timers als
/// Live-Aktivität (Sperrbildschirm, Dynamic Island), siehe `AISBotWidgets/AlarmCountdownLiveActivity.swift`.
nonisolated struct ScoopAlarmMetadata: AlarmMetadata {
    /// Titel, z. B. „Nudeln“ oder „Laufen“
    var title: String
    /// alarm | timer
    var kind: String

    init(title: String, kind: String) {
        self.title = title
        self.kind = kind
    }
}
#endif
