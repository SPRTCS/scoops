import SwiftUI
import WidgetKit

@main
struct AISBotWidgetsBundle: WidgetBundle {
    var body: some Widget {
        ScoopWidget()
        ScoopsGridWidget()
        LimitsWidget()
        #if os(iOS)
        ScoopsCountWidget()
        LimitsLockWidget()
        ScoopsLiveActivity()
        // Timer/Wecker der Scoops (AlarmKit, API v1.18)
        AlarmCountdownLiveActivity()
        // Alte Einzel-Aktivität bleibt vorerst registriert, damit hängende Aktivitäten noch gerendert/beendet werden.
        BotRunLiveActivity()
        #endif
    }
}
