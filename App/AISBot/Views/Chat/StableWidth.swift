import SwiftUI

/// Hält den Chat (Verlauf + Eingabe) auf fester Breite, während daneben eine Spalte ein- oder ausfährt
/// (Profil rechts, Seitenleiste links).
///
/// Hintergrund (Build 12, gemessen): Beim Ein-/Ausfahren ändert AppKit bzw. UIKit die Breite des Chats in jedem
/// Bild der Animation. SwiftUI hat dann jede sichtbare Zeile neu vermessen und verschoben (die Zeilen sind seit
/// Build 11 volle Breite und zentrieren die Lesespalte innen, siehe `chatColumn`). Mit vielen Nachrichten waren
/// das rund 15 Bilder pro Animation über dem 120-Hz-Budget von 8,3 ms.
///
/// Solange die Lesespalte ohnehin ihre volle Breite hat (Fenster breiter als `minimumWidth`), sieht der Chat bei
/// jeder Breite gleich aus, nur mittig verschoben. Deshalb bekommt der Inhalt während der Animation die Breite vom
/// Anfang und wird als Ganzes mittig platziert: Innen ändert sich nichts (keine neue Vermessung, kein
/// Scroll-Verankern, die Zeilen bleiben bei x = 0 im ScrollView), außen verschiebt sich nur eine Ebene.
/// Kurz nach dem letzten Breitenwechsel übernimmt der Inhalt wieder die echte Breite – optisch identisch.
/// Wird es schmaler als `minimumWidth` (würde die Spalte umbrechen), folgt der Inhalt sofort wieder live.
struct ColumnTransitionStabilizer<Content: View>: View {
    /// Ab dieser Breite haben Lesespalte und Eingabe ihre volle Breite.
    var minimumWidth: CGFloat
    @ViewBuilder var content: Content

    @Environment(AppStore.self) private var store
    @State private var frozenWidth: CGFloat?
    @State private var tracker = WidthTracker()

    var body: some View {
        StableWidthLayout(frozenWidth: frozenWidth, minimumWidth: minimumWidth) { content }
            // Während der Animation ist der Inhalt ggf. breiter als der Chat – nicht über Nachbarspalten zeichnen.
            // Nur waagerecht beschneiden: Oben läuft der Verlauf seit Build 15 unter Kopf-Pille und Knöpfen bis an
            // den Rand (der ScrollView reicht in die obere Safe Area), das darf der Clip nicht abschneiden.
            .clipShape(HorizontalClip())
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { tracker.widthChanged($0) }
            .onChange(of: store.showInspector) { freeze() }
            .onChange(of: store.sidebarColumns) { freeze() }
    }

    private func freeze() {
        let width = tracker.width
        guard width >= minimumWidth else { return }
        frozenWidth = width
        tracker.scheduleRelease { frozenWidth = nil }
    }
}

/// Merkt sich die aktuelle Breite, ohne die Oberfläche zu invalidieren, und gibt die feste Breite frei,
/// sobald sich die Breite eine Weile nicht mehr geändert hat.
@MainActor
final class WidthTracker {
    private(set) var width: CGFloat = 0
    private var release: Task<Void, Never>?
    private var onRelease: (() -> Void)?
    private var started = Date.distantPast

    /// Wartezeit nach dem letzten Breitenwechsel bzw. bis die Animation überhaupt beginnt
    private static let settle: Duration = .milliseconds(120)
    private static let startGrace: Duration = .milliseconds(350)
    /// Spätestens dann wieder live (z. B. bei sehr langsamen Animationen)
    private static let maximum: TimeInterval = 1.2

    func widthChanged(_ newWidth: CGFloat) {
        width = newWidth
        guard onRelease != nil else { return }
        if Date().timeIntervalSince(started) > Self.maximum { fire() } else { reschedule(after: Self.settle) }
    }

    func scheduleRelease(_ action: @escaping () -> Void) {
        onRelease = action
        started = Date()
        reschedule(after: Self.startGrace)
    }

    private func reschedule(after delay: Duration) {
        release?.cancel()
        release = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        release?.cancel()
        release = nil
        let action = onRelease
        onRelease = nil
        action?()
    }
}

/// Schlägt dem Inhalt eine feste Breite vor (falls gesetzt) und setzt ihn waagerecht mittig bzw. rechtsbündig.
struct StableWidthLayout: Layout {
    var frozenWidth: CGFloat?
    var minimumWidth: CGFloat = 0
    /// `.leading`: Inhalt hängt an der linken Kante und wandert mit ihr (Profil-Spalte gleitet nach rechts hinaus)
    var alignment: HorizontalAlignment = .center

    private func childWidth(for width: CGFloat) -> CGFloat {
        guard let frozenWidth, width >= minimumWidth else { return width }
        return frozenWidth
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return proposal.replacingUnspecifiedDimensions() }
        guard let width = proposal.width else { return child.sizeThatFits(proposal) }
        let size = child.sizeThatFits(ProposedViewSize(width: childWidth(for: width), height: proposal.height))
        return CGSize(width: width, height: size.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let proposal = ProposedViewSize(width: childWidth(for: bounds.width), height: bounds.height)
        if alignment == .leading {
            child.place(at: CGPoint(x: bounds.minX, y: bounds.minY), anchor: .topLeading, proposal: proposal)
        } else {
            child.place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: proposal)
        }
    }
}

/// Beschneidet nur links und rechts; oben und unten darf der Inhalt (Verlauf unter der Kopfzeile) überstehen.
nonisolated struct HorizontalClip: Shape {
    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX, y: rect.minY - 4000, width: rect.width, height: rect.height + 8000))
    }
}
