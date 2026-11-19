import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

extension AppStore {
    /// Kompakter Stand für Widgets und Live Activities.
    var widgetSnapshot: WidgetSnapshot {
        let list = bots.map { b -> WidgetBot in
            let running = messages[b.id]?.last(where: { $0.role == .status && $0.isRunning })
                ?? (b.lastMessage?.isRunning == true ? b.lastMessage : nil)
            let busy = isBusy(b.id)
            return WidgetBot(id: b.id, name: b.name, label: b.label, mascot: b.mascot, pinned: b.pinned,
                             busy: busy,
                             statusLine: busy ? (running?.meta.lines?.last ?? "Arbeitet …") : nil,
                             runStartedAt: busy ? (running?.meta.startedAt ?? running?.createdAt) : nil,
                             runId: busy ? running?.meta.runId : nil,
                             unread: b.unread,
                             lastMessagePreview: b.lastMessage.map { $0.previewText },
                             lastMessageAt: b.lastMessage?.createdAt ?? b.createdAt)
        }
        return WidgetSnapshot(generatedAt: .distantPast, userName: userName, bots: list)
    }
}

/// Schreibt den Schnappschuss in den App-Group-Container und lädt Widgets neu
/// (gedrosselt auf max. alle 5 s, sofort bei Änderungen am Arbeitsstatus).
final class WidgetSync {
    static let shared = WidgetSync()

    private var last: WidgetSnapshot?
    private var lastReload = Date.distantPast
    private var pending: Task<Void, Never>?

    init() {
        // Eigene Scoop-Bilder: Ist eine neue Version im App-Group-Container, Widgets neu zeichnen.
        ScoopPhotoCache.shared.onStored = { [weak self] _ in self?.reload() }
    }

    func update(_ snapshot: WidgetSnapshot) {
        guard snapshot != last else { return }
        let busyChanged = Set(snapshot.bots.filter(\.busy).map(\.id)) != Set((last?.bots ?? []).filter(\.busy).map(\.id))
        last = snapshot
        var stamped = snapshot
        stamped.generatedAt = Date()
        SharedContainer.save(stamped)
        // Maskottchen-Bilder für Mitteilungen (rendert nur, wenn sich das Aussehen geändert hat).
        NotificationAvatarSync.shared.update(bots: snapshot.bots)
        // Eigene Scoop-Bilder für Widgets und Live-Aktivität vorab in den App-Group-Container laden.
        for photo in snapshot.bots.compactMap(\.mascot.photo) { ScoopPhotoCache.shared.request(photo) }

        pending?.cancel()
        let elapsed = Date().timeIntervalSince(lastReload)
        if busyChanged || elapsed >= 5 {
            reload()
        } else {
            pending = Task { [weak self] in
                try? await Task.sleep(for: .seconds(5 - elapsed))
                guard !Task.isCancelled else { return }
                self?.reload()
            }
        }
        #if os(iOS)
        LiveActivityManager.shared.sync(with: snapshot)
        #endif
    }

    private func reload() {
        lastReload = Date()
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }
}
