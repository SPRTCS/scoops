import Foundation
import Observation
import SwiftUI

/// Sendet Inhalte nach, die das Teilen-Menü (oder ein Kurzbefehl) in der Ablage hinterlassen hat
/// (`ShareOutbox`, docs/system.md): beim Öffnen der App, sobald der Server erreichbar ist und sofort, wenn die
/// Erweiterung etwas ablegt, während die App läuft (Mac: immer dieser Weg).
@Observable
final class ShareOutboxSender {
    static let shared = ShareOutboxSender()

    /// Sendungen, die noch liegen (Hinweis in der App)
    private(set) var waiting: [ShareOutboxItem] = []
    private(set) var sending = false

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var monitor: DispatchSourceFileSystemObject?
    @ObservationIgnored private var again = false
    /// Hinweis auf Nachgesendetes, der noch gezeigt werden muss (gesendet, während die App im Hintergrund war)
    @ObservationIgnored private var notice: String?

    func start(store: AppStore) {
        guard self.store == nil else { return }
        self.store = store
        observe()
        watchFolder()
        deliverSoon()
    }

    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.phase
            _ = store.isAppActive
            _ = store.guestStates
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.showNoticeIfActive()
                self?.deliverSoon()
                self?.observe()
            }
        }
    }

    /// Zeigt den Hinweis erst, wenn die App sichtbar ist (sonst sähe ihn niemand).
    private func showNoticeIfActive() {
        guard let store, store.isAppActive, let text = notice else { return }
        notice = nil
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            store.showToast(text)
        }
    }

    /// Meldet neue Ordner in der Ablage (andere Prozesse schreiben in denselben Container).
    private func watchFolder() {
        guard let folder = ShareOutbox.folderURL else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = open(folder.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.deliverSoon(after: 1.2) }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        monitor = source
    }

    /// Gebündelt anstoßen (mehrere Auslöser kurz hintereinander)
    func deliverSoon(after seconds: Double = 0.4) {
        task?.cancel()
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.deliver()
        }
    }

    func discard(_ item: ShareOutboxItem) {
        ShareOutbox.remove(item.id)
        waiting.removeAll { $0.id == item.id }
    }

    func discardAll() {
        waiting.forEach { ShareOutbox.remove($0.id) }
        waiting = []
    }

    private func deliver() async {
        guard let store else { return }
        guard !sending else {
            again = true
            return
        }
        sending = true
        defer {
            sending = false
            if again {
                again = false
                deliverSoon()
            }
        }
        var left: [ShareOutboxItem] = []
        var sent: [ShareOutboxItem] = []
        for var item in ShareOutbox.pendingForApp() {
            // Demo-Sendungen gehören nur in den Demo-Modus: außerhalb verwerfen. Echte Sendungen bleiben im
            // Demo-Modus unangetastet liegen (ohne Hinweis), bis die App wieder normal läuft.
            guard item.demo == store.isMock else {
                if item.demo { ShareOutbox.remove(item.id) }
                continue
            }
            guard store.chatExists(item.chatID), store.service(for: item.chatID) != nil else {
                item.lastError = store.phase == .online
                    ? String(localized: "„\(item.chatName)“ gehört zu einem anderen Server.")
                    : String(localized: "Wartet auf die Verbindung zum Server.")
                left.append(item)
                continue
            }
            do {
                try await ShareOutbox.deliver(item, using: StoreSystemService(store: store))
                if !item.silent { sent.append(item) }
            } catch {
                item = ShareOutbox.load(item.id) ?? item
                item.state = .queued
                item.lastError = SystemError.from(error).message
                ShareOutbox.save(item)
                left.append(item)
            }
        }
        if waiting != left { withAnimation(.snappy) { waiting = left } }
        if let first = sent.first {
            notice = sent.count == 1 ? String(localized: "Geteilte Inhalte an \(first.chatName) gesendet")
                                     : String(localized: "\(sent.count) geteilte Sendungen nachgesendet")
            showNoticeIfActive()
        }
    }
}

/// Hinweis unten im Fenster (über Eingabefeld und kurzen Meldungen), solange geteilte Inhalte noch nicht gesendet
/// werden konnten.
struct ShareOutboxBanner: View {
    @Environment(\.theme) private var theme
    private var sender: ShareOutboxSender { .shared }

    var body: some View {
        if let first = sender.waiting.first {
            let count = sender.waiting.count
            Menu {
                Section(first.lastError ?? String(localized: "Wartet auf die Verbindung zum Server.")) {
                    Button("Jetzt senden", systemImage: "arrow.up.circle") { sender.deliverSoon(after: 0) }
                    Button("Verwerfen", systemImage: "trash", role: .destructive) { sender.discardAll() }
                }
            } label: {
                HStack(spacing: 8) {
                    if sender.sending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "tray.and.arrow.up.fill")
                            .appFont(12.5, weight: .semibold)
                            .foregroundStyle(theme.warning)
                    }
                    Text(count == 1 ? "Geteiltes für \(first.chatName) wartet" : "\(count) geteilte Sendungen warten")
                        .appFont(13, weight: .medium)
                        .foregroundStyle(theme.textPrimary)
                        .adaptiveLineLimit(1)
                    Image(systemName: "chevron.down")
                        .appFont(10, weight: .semibold)
                        .foregroundStyle(theme.textTertiary)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(theme.surfaceRaised, in: Capsule())
                .overlay(Capsule().strokeBorder(theme.surfaceBorder))
                .shadow(color: theme.cardShadow, radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .padding(.bottom, 138)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityLabel(count == 1 ? "Geteilte Inhalte für \(first.chatName) warten auf das Senden"
                                           : "\(count) geteilte Sendungen warten auf das Senden")
            .accessibilityHint("Öffnet die Auswahl: jetzt senden oder verwerfen")
        }
    }
}
