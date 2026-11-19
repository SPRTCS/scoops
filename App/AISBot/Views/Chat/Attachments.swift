import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Anhänge, die vor dem Senden hochgeladen werden (Chips über der Eingabe).
/// Die Rohdaten liegen zusätzlich auf der Platte (`DraftArchive`), damit der Entwurf ein Beenden der App übersteht.
@Observable
final class AttachmentQueue {
    struct Item: Identifiable {
        var id = UUID()
        var name: String
        var mime: String
        var size: Int
        var progress: Double = 0
        var file: LibraryFile?
        var failed: String?
        var thumbnail: PlatformImage?
    }

    private(set) var items: [Item] = [] {
        didSet { onChange?() }
    }
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    /// Meldet jede Änderung (Store sichert den Entwurf)
    @ObservationIgnored var onChange: (() -> Void)?

    static let maxBytes = 25 * 1024 * 1024

    var isEmpty: Bool { items.isEmpty }
    var isUploading: Bool { items.contains { $0.file == nil && $0.failed == nil } }
    var fileIDs: [String] { items.compactMap { $0.file?.id } }

    func add(data: Data, name: String, mime: String, chatID: String, store: AppStore) {
        var item = Item(name: name, mime: mime, size: data.count)
        if mime.hasPrefix("image/") { item.thumbnail = PlatformImage(data: data) }
        guard data.count <= Self.maxBytes else {
            item.failed = "Größer als 25 MB"
            items.append(item)
            return
        }
        DraftArchive.storeData(data, id: item.id)
        items.append(item)
        upload(item.id, data: data, name: name, mime: mime, chatID: chatID, store: store)
    }

    private func upload(_ id: UUID, data: Data, name: String, mime: String, chatID: String, store: AppStore) {
        tasks[id] = Task {
            do {
                let file = try await store.uploadFile(chatID: chatID, name: name, mime: mime, data: data) { p in
                    Task { @MainActor in self.setProgress(id, p) }
                }
                if let idx = items.firstIndex(where: { $0.id == id }) {
                    items[idx].file = file
                    items[idx].progress = 1
                } else {
                    // Schon entfernt, während der Upload lief
                    await store.deleteFile(file)
                }
            } catch {
                guard !Task.isCancelled else { return }
                if let idx = items.firstIndex(where: { $0.id == id }) { items[idx].failed = error.localizedDescription }
            }
        }
    }

    /// Gesicherten Entwurf nach einem Neustart wiederherstellen. Schon hochgeladene Dateien werden übernommen,
    /// unterbrochene Uploads neu gestartet. Fehlen die Rohdaten (z. B. Schreiben nicht fertig), entfällt der Anhang.
    func restore(_ saved: [DraftArchive.SavedAttachment], chatID: String, store: AppStore) {
        for s in saved where !items.contains(where: { $0.id == s.id }) {
            guard let data = try? Data(contentsOf: DraftArchive.fileURL(s.id)) else { continue }
            var item = Item(id: s.id, name: s.name, mime: s.mime, size: s.size, file: s.file)
            if s.mime.hasPrefix("image/") { item.thumbnail = PlatformImage(data: data) }
            if s.file != nil { item.progress = 1 }
            items.append(item)
            if s.file == nil { upload(s.id, data: data, name: s.name, mime: s.mime, chatID: chatID, store: store) }
        }
    }

    /// Stand für die Sicherung. Auch fehlgeschlagene Uploads (z. B. offline) bleiben, sie werden beim nächsten
    /// Start erneut versucht; nur zu große Dateien haben keine Rohdaten auf der Platte.
    var saved: [DraftArchive.SavedAttachment] {
        items.filter { $0.size <= Self.maxBytes }
            .map { DraftArchive.SavedAttachment(id: $0.id, name: $0.name, mime: $0.mime, size: $0.size, file: $0.file) }
    }

    func add(fileURL url: URL, chatID: String, store: AppStore) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return }
        let type = UTType(filenameExtension: url.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        add(data: data, name: url.lastPathComponent, mime: mime, chatID: chatID, store: store)
    }

    private func setProgress(_ id: UUID, _ p: Double) {
        guard let idx = items.firstIndex(where: { $0.id == id }), items[idx].file == nil else { return }
        items[idx].progress = p
    }

    /// Entfernt einen Anhang; bereits hochgeladene Dateien werden wieder gelöscht.
    func remove(_ id: UUID, store: AppStore) {
        tasks[id]?.cancel()
        tasks[id] = nil
        if let item = items.first(where: { $0.id == id }), let file = item.file {
            Task { await store.deleteFile(file) }
        }
        DraftArchive.removeFile(id)
        items.removeAll { $0.id == id }
    }

    /// Nach dem Senden: Dateien bleiben in der Bibliothek, die Chips (und ihre Sicherung) verschwinden.
    func reset() {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        for item in items { DraftArchive.removeFile(item.id) }
        items = []
    }
}

/// Chips über der Eingabe mit Fortschritt und Entfernen-Knopf.
struct AttachmentChips: View {
    let queue: AttachmentQueue
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(queue.items) { item in chip(item) }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
        }
        .scrollIndicators(.never)
    }

    private func chip(_ item: AttachmentQueue.Item) -> some View {
        HStack(spacing: 8) {
            ZStack {
                if let img = item.thumbnail {
                    Image(platformImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: LibraryFile.symbol(forMime: item.mime, name: item.name))
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            .frame(width: 34, height: 34)
            .background(theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.textPrimary).lineLimit(1)
                if let failed = item.failed {
                    Text(failed).font(.system(size: 11)).foregroundStyle(theme.danger).lineLimit(1)
                } else if item.file == nil {
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .tint(theme.accent)
                        .frame(width: 90)
                } else {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(item.size), countStyle: .file))
                        .font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                }
            }
            .frame(maxWidth: 150, alignment: .leading)
            Button {
                withAnimation(.snappy(duration: 0.2)) { queue.remove(item.id, store: store) }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 18, height: 18)
                    .background(theme.hover, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(item.name) entfernen")
        }
        .padding(.leading, 6).padding(.trailing, 8).padding(.vertical, 6)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(theme.surfaceBorder))
    }
}

extension LibraryFile {
    static func symbol(forMime mime: String, name: String) -> String {
        LibraryFile(id: "", chatId: "", authorId: nil, kind: mime.hasPrefix("image/") ? "bild" : "datei", name: name,
                    mime: mime, size: nil, url: nil, note: nil, createdAt: nil, downloadUrl: nil).symbolName
    }
}

// MARK: - Dateien im Verlauf

/// Kompakte Dateikarte (Ereignis mit `meta.file_id`).
struct FileCard: View {
    let fileID: String
    let fallbackText: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let file = store.file(fileID)
        Button {
            if let file { store.open(file) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: file?.symbolName ?? "doc")
                    .font(.system(size: 17))
                    .foregroundStyle(theme.accent)
                    .frame(width: 38, height: 38)
                    .background(theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file?.name ?? fallbackText)
                        .font(.system(size: 13.5, weight: .medium))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle(file))
                        .font(.system(size: 11.5))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 13))
                    .foregroundStyle(theme.textTertiary)
            }
            .padding(10)
            .frame(maxWidth: 320)
            .themedCard(theme, radius: 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .accessibilityLabel("Datei \(file?.name ?? fallbackText) öffnen")
    }

    private func subtitle(_ file: LibraryFile?) -> String {
        guard let file else { return fallbackText }
        var parts: [String] = []
        if let size = file.sizeText { parts.append(size) }
        if let author = store.bot(file.authorId) { parts.append("von \(author.name)") } else { parts.append("von dir") }
        return parts.joined(separator: " · ")
    }
}

/// Anhänge einer Nutzernachricht: Bilder als Vorschau, andere Dateien als Chips.
struct MessageAttachments: View {
    let fileIDs: [String]
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let list = fileIDs.map { (id: $0, file: store.file($0)) }
        HStack(spacing: 6) {
            ForEach(list, id: \.id) { entry in
                if let file = entry.file {
                    Button { store.open(file) } label: {
                        if file.isImage {
                            FileThumbnail(file: file)
                                .frame(width: 120, height: 90)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        } else {
                            HStack(spacing: 6) {
                                Image(systemName: file.symbolName).foregroundStyle(theme.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.textPrimary).lineLimit(1)
                                    if let s = file.sizeText {
                                        Text(s).font(.system(size: 11)).foregroundStyle(theme.textTertiary)
                                    }
                                }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .frame(maxWidth: 200, alignment: .leading)
                            .background(theme.userBubble.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Anhang \(file.name) öffnen")
                } else {
                    Label("Anhang", systemImage: "paperclip")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .padding(8)
                        .background(theme.userBubble.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }
}

/// Bildvorschau einer Bibliotheksdatei (lädt die Datei in den Zwischenspeicher).
struct FileThumbnail: View {
    let file: LibraryFile
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var image: PlatformImage?

    var body: some View {
        ZStack {
            theme.surface
            if let image {
                Image(platformImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: "photo").foregroundStyle(theme.textTertiary)
            }
        }
        .task(id: file.id) {
            guard image == nil, let url = await store.download(file), let data = try? Data(contentsOf: url) else { return }
            image = PlatformImage(data: data)
        }
    }
}

// MARK: - Öffnen

extension AppStore {
    /// Öffnet einen Link im Browser oder lädt eine Datei und zeigt sie in Quick Look.
    func open(_ file: LibraryFile) {
        if file.isLink, let s = file.url, let url = URL(string: s) {
            #if canImport(UIKit)
            UIApplication.shared.open(url)
            #else
            NSWorkspace.shared.open(url)
            #endif
            return
        }
        Task {
            if let url = await download(file) { previewURL = url }
        }
    }
}
