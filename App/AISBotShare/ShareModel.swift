import CoreGraphics
import Foundation
import Observation
#if os(macOS)
import AppKit
#endif

/// Zustand des Blatts „An Scoop senden“: Inhalte einsammeln, Scoop wählen, senden bzw. ablegen.
@Observable
final class ShareModel {
    enum Phase: Equatable {
        /// Inhalte werden eingesammelt
        case loading
        case ready
        case sending
        case sent(String)
        /// Nicht gesendet, aber sicher abgelegt: Die App sendet nach
        case queued(String)
        case failed(String)
        /// Nichts zu tun (kein Server, kein Scoop, nichts Lesbares)
        case unavailable(String)
    }

    private(set) var phase: Phase = .loading
    private(set) var targets: [SystemChat] = []
    var selectedID: String?
    var note = ""
    private(set) var content = ShareContent()
    private(set) var thumbnails: [String: CGImage] = [:]
    /// Fortschritt beim Senden (0…1)
    private(set) var progress: Double = 0

    @ObservationIgnored private var directory = SystemDirectory.empty
    @ObservationIgnored private var item: ShareOutboxItem?
    @ObservationIgnored private var sendTask: Task<Void, Never>?
    @ObservationIgnored private weak var context: NSExtensionContext?

    init(context: NSExtensionContext?) {
        self.context = context
    }

    var selected: SystemChat? { targets.first { $0.id == selectedID } }
    var canSend: Bool { phase == .ready && selected != nil && !content.isEmpty }

    // MARK: Laden

    func load() async {
        directory = SystemDirectory.current()
        targets = directory.shareTargets
        guard !targets.isEmpty else {
            phase = .unavailable(directory.isEmpty
                ? String(localized: "Öffne AIS Scoops und verbinde dich mit deinem Server. Danach kannst du hierhin teilen.")
                : String(localized: "Hier gibt es keinen Scoop, dem du schreiben darfst."))
            return
        }
        selectedID = targets.first?.id
        ShareOutbox.removeStaleDrafts()
        guard let staged = ShareOutbox.begin(), let folder = ShareOutbox.folder(of: staged.id) else {
            phase = .unavailable(String(localized: "Die Inhalte ließen sich nicht ablegen."))
            return
        }
        item = staged
        let inputs = (context?.inputItems ?? []).compactMap { $0 as? NSExtensionItem }
        content = await ShareItemLoader.load(inputs, into: folder)
        guard !content.isEmpty else {
            ShareOutbox.remove(staged.id)
            item = nil
            phase = .unavailable(content.skipped.first ?? String(localized: "Diese Inhalte lassen sich nicht an einen Scoop senden."))
            return
        }
        phase = .ready
        // Vorschaubilder nacheinander und klein (Speichergrenze der Erweiterung)
        for attachment in content.attachments where attachment.isImage {
            let url = folder.appending(path: attachment.file)
            let image = await Task.detached(priority: .utility) { ShareItemLoader.thumbnail(url) }.value
            if let image { thumbnails[attachment.file] = image }
        }
    }

    // MARK: Senden

    func send() {
        guard canSend, var item, let chat = selected else { return }
        item.chatID = chat.id
        item.serverID = chat.serverID
        item.chatName = chat.name
        item.text = content.messageText(note: note)
        item.attachments = content.attachments
        item.demo = directory.demo
        item.touchedAt = Date()
        self.item = item
        phase = .sending
        progress = 0
        sendTask = Task { await deliver(item, to: chat) }
    }

    private func deliver(_ original: ShareOutboxItem, to chat: SystemChat) async {
        var item = original
        #if os(macOS)
        // Mac: Die App sendet (sie hat die Anmeldung). Ablegen und die App wecken.
        item.state = .queued
        ShareOutbox.save(item)
        SystemDirectory.noteUsed(chatID: chat.id)
        NSWorkspace.shared.open(DeepLink.outbox.url)
        phase = .sent(String(localized: "AIS Scoops sendet es an \(chat.name)."))
        finishSoon()
        #else
        if directory.demo, !directory.demoOffline {
            // Demo-Modus: Senden nachspielen; die App zeigt die Nachricht beim nächsten Öffnen im Demo-Chat
            for step in 1...10 {
                try? await Task.sleep(for: .milliseconds(90))
                progress = Double(step) / 10
            }
            item.state = .queued
            item.silent = true
            ShareOutbox.save(item)
            SystemDirectory.noteUsed(chatID: chat.id)
            phase = .sent(String(localized: "An \(chat.name) gesendet"))
            finishSoon()
            return
        }
        item.state = .sending
        ShareOutbox.save(item)
        // Lebenszeichen, damit die App eine laufende Sendung nicht parallel übernimmt
        let alive = Task {
            while !Task.isCancelled {
                ShareOutbox.touch(item.id)
                try? await Task.sleep(for: .seconds(20))
            }
        }
        defer { alive.cancel() }
        do {
            let service = try await SystemAccess.service(for: chat, directory: directory)
            try await ShareOutbox.deliver(item, using: service) { [weak self] fraction in
                Task { @MainActor in self?.progress = max(self?.progress ?? 0, fraction) }
            }
            phase = .sent(String(localized: "An \(chat.name) gesendet"))
            finishSoon()
        } catch {
            let failure = SystemError.from(error)
            // Zwischenstand (schon hochgeladene Dateien) von der Platte übernehmen
            var latest = ShareOutbox.load(item.id) ?? item
            latest.lastError = failure.message
            if failure.isTransient || failure.kind == .notConnected {
                latest.state = .queued
                ShareOutbox.save(latest)
                self.item = latest
                SystemDirectory.noteUsed(chatID: chat.id)
                phase = .queued(failure.kind == .offline
                    ? String(localized: "Der Server ist gerade nicht erreichbar. AIS Scoops sendet es an \(chat.name), sobald du die App öffnest.")
                    : String(localized: "Das Senden klappt gerade nicht von hier. AIS Scoops sendet es an \(chat.name), sobald du die App öffnest."))
            } else {
                latest.state = .staging
                ShareOutbox.save(latest)
                self.item = latest
                content.attachments = latest.attachments
                phase = .failed(failure.message)
            }
        }
        #endif
    }

    /// Nach einem Fehler: zurück zur Auswahl (anderer Scoop, Notiz ändern, erneut senden)
    func backToEditing() {
        guard case .failed = phase else { return }
        phase = .ready
    }

    // MARK: Schließen

    private func finishSoon() {
        Task {
            try? await Task.sleep(for: .milliseconds(1100))
            done()
        }
    }

    /// Blatt schließen; eine abgelegte Sendung bleibt liegen.
    func done() {
        context?.completeRequest(returningItems: nil)
    }

    /// Abbrechen: Entwurf samt Dateien verwerfen (eine schon abgelegte Sendung bleibt).
    func cancel() {
        sendTask?.cancel()
        if let item, let stored = ShareOutbox.load(item.id), stored.state != .queued { ShareOutbox.remove(item.id) }
        context?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
