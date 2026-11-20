import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Was geteilt wurde, nach dem Einsammeln: Texte und Links gehen in die Nachricht, Dateien liegen schon im
/// Ordner der Sendung (`ShareOutbox`).
nonisolated struct ShareContent: Sendable {
    struct Link: Hashable, Sendable {
        var title: String?
        var url: URL
    }

    var texts: [String] = []
    var links: [Link] = []
    var attachments: [ShareOutboxItem.Attachment] = []
    /// Was nicht mitkommt (zu groß, nicht lesbar), als fertiger Satz
    var skipped: [String] = []

    var isEmpty: Bool { texts.isEmpty && links.isEmpty && attachments.isEmpty }

    /// Nachrichtentext aus Notiz, geteiltem Text und Links
    func messageText(note: String) -> String {
        var parts: [String] = []
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { parts.append(trimmed) }
        parts += texts
        parts += links.map { link in
            if let title = link.title, !title.isEmpty, title != link.url.absoluteString { return "\(title)\n\(link.url.absoluteString)" }
            return link.url.absoluteString
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Sammelt die geteilten Inhalte ein, ohne große Dateien in den Speicher zu laden: Dateien werden auf der Platte
/// in den Ordner der Sendung kopiert, Bilder dort bei Bedarf verkleinert (ImageIO liest dafür nur Ausschnitte).
/// Erweiterungen haben wenig Speicher; ein 40-MB-Foto als `Data` oder `UIImage` kann sie schon beenden.
nonisolated enum ShareItemLoader {
    /// Größte Kante, mit der Bilder beim Scoop ankommen
    static let maxImagePixels = 2560
    /// Bis hierhin gehen JPEG, PNG, GIF und WebP unverändert durch
    static let keepImageBytes = 6 * 1024 * 1024
    static let maxBytes = RemoteSystemService.maxUploadBytes

    static func load(_ items: [NSExtensionItem], into folder: URL) async -> ShareContent {
        var content = ShareContent()
        var index = 0
        for item in items {
            // Safari & Co. geben den Seitentitel als Text des Eintrags mit
            let title = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines)
            for provider in item.attachments ?? [] {
                index += 1
                await load(provider, title: title, index: index, folder: folder, into: &content)
            }
        }
        return content
    }

    private static func load(_ provider: NSItemProvider, title: String?, index: Int, folder: URL,
                             into content: inout ShareContent) async {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let name = provider.suggestedName
        // Dokumente (PDF, Video, Audio, Archiv …): alles, was Daten ist, aber weder Adresse noch Text
        let document = types.first {
            $0.conforms(to: .data) && !$0.conforms(to: .url) && !$0.conforms(to: .text) && !$0.conforms(to: .propertyList)
        }
        if let image = types.first(where: { $0.conforms(to: .image) }) {
            await stage(provider, type: image, name: name, index: index, folder: folder, image: true, into: &content)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            // Datei aus „Dateien“ & Co.: den eigentlichen Typ nehmen, nicht die Adresse
            let type = types.first { !$0.conforms(to: .url) } ?? .data
            await stage(provider, type: type, name: name, index: index, folder: folder, image: false, into: &content)
        } else if let document {
            // Vor der Adresse prüfen: Safari gibt zu einer geöffneten PDF Datei und Link mit, gemeint ist die Datei
            await stage(provider, type: document, name: name, index: index, folder: folder, image: false, into: &content)
        } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            guard let url = await object(URL.self, from: provider) else { return }
            if url.isFileURL {
                await stage(provider, type: .data, name: name ?? url.lastPathComponent, index: index, folder: folder,
                            image: false, into: &content)
            } else if !content.links.contains(where: { $0.url == url }) {
                content.links.append(.init(title: title, url: url))
            }
        } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            guard let text = await object(String.self, from: provider)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty, !content.texts.contains(text) else { return }
            content.texts.append(text)
        } else if let type = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .propertyList) }) {
            // Kontakt, formatierter Text und andere Daten als Datei
            await stage(provider, type: type, name: name, index: index, folder: folder, image: false, into: &content)
        }
    }

    private static func object<T: _ObjectiveCBridgeable>(_ type: T.Type, from provider: NSItemProvider) async -> T?
    where T._ObjectiveCType: NSItemProviderReading, T: Sendable {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: type) { value, _ in continuation.resume(returning: value) }
        }
    }

    // MARK: Dateien

    private struct Staged: Sendable {
        var attachment: ShareOutboxItem.Attachment?
        var problem: String?
    }

    private static func stage(_ provider: NSItemProvider, type: UTType, name: String?, index: Int, folder: URL,
                              image: Bool, into content: inout ShareContent) async {
        var staged = await fileRepresentation(provider, type: type, name: name, index: index, folder: folder, image: image)
        if staged.attachment == nil, staged.problem == nil, image {
            // Manche Apps geben Bilder nur als Daten her (kein Dateipfad)
            staged = await dataRepresentation(provider, type: type, name: name, index: index, folder: folder)
        }
        if let attachment = staged.attachment { content.attachments.append(attachment) }
        if let problem = staged.problem { content.skipped.append(problem) }
        if staged.attachment == nil, staged.problem == nil {
            if let name {
                content.skipped.append(String(localized: "„\(name)“ ließ sich nicht lesen."))
            } else {
                content.skipped.append(String(localized: "„Ein Inhalt“ ließ sich nicht lesen."))
            }
        }
    }

    private static func fileRepresentation(_ provider: NSItemProvider, type: UTType, name: String?, index: Int,
                                           folder: URL, image: Bool) async -> Staged {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                // Die Datei gibt es nur innerhalb dieses Aufrufs: sofort in den Ordner der Sendung holen
                guard let url else { return continuation.resume(returning: Staged()) }
                continuation.resume(returning: adopt(url, type: type, name: name, index: index, folder: folder, image: image))
            }
        }
    }

    private static func dataRepresentation(_ provider: NSItemProvider, type: UTType, name: String?, index: Int,
                                           folder: URL) async -> Staged {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                guard let data else { return continuation.resume(returning: Staged()) }
                let temp = folder.appending(path: "in-\(index).tmp")
                guard (try? data.write(to: temp)) != nil else { return continuation.resume(returning: Staged()) }
                let staged = adopt(temp, type: type, name: name, index: index, folder: folder, image: true)
                try? FileManager.default.removeItem(at: temp)
                continuation.resume(returning: staged)
            }
        }
    }

    /// Kopiert (oder verkleinert) eine Datei in den Ordner der Sendung und beschreibt sie.
    private static func adopt(_ source: URL, type: UTType, name: String?, index: Int, folder: URL, image: Bool) -> Staged {
        let fallbackExtension = type.preferredFilenameExtension ?? source.pathExtension
        var display = (name?.isEmpty == false ? name! : source.deletingPathExtension().lastPathComponent)
        display = display.replacingOccurrences(of: "/", with: "-")
        var ext = (display as NSString).pathExtension
        if ext.isEmpty || UTType(filenameExtension: ext) == nil {
            ext = source.pathExtension.isEmpty ? fallbackExtension : source.pathExtension
            if !ext.isEmpty { display += ".\(ext)" }
        }
        if image, let scaled = downscaled(source, folder: folder, index: index) {
            let base = (display as NSString).deletingPathExtension
            return finish(file: scaled, name: "\(base).jpg", mime: "image/jpeg", folder: folder)
        }
        let file = "\(index)-\(sanitized(display))"
        let target = folder.appending(path: file)
        try? FileManager.default.removeItem(at: target)
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            return Staged()
        }
        let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? type.preferredMIMEType ?? "application/octet-stream"
        return finish(file: file, name: display, mime: mime, folder: folder)
    }

    private static func finish(file: String, name: String, mime: String, folder: URL) -> Staged {
        let url = folder.appending(path: file)
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxBytes else {
            try? FileManager.default.removeItem(at: url)
            return Staged(problem: String(localized: "„\(name)“ ist größer als 25 MB und wird nicht gesendet."))
        }
        guard size > 0 else {
            try? FileManager.default.removeItem(at: url)
            return Staged()
        }
        return Staged(attachment: .init(file: file, name: name, mime: mime, size: size, fileID: nil))
    }

    private static func sanitized(_ name: String) -> String {
        String(name.map { $0 == "/" || $0 == ":" || $0 == "\\" ? "-" : $0 }.suffix(120))
    }

    /// Große Bilder und Formate, die Scoops nicht lesen (HEIC, RAW, TIFF), als JPEG mit höchstens
    /// `maxImagePixels` ablegen. Kleine JPEG/PNG/GIF/WebP bleiben unverändert (`nil`).
    private static func downscaled(_ source: URL, folder: URL, index: Int) -> String? {
        guard let input = CGImageSourceCreateWithURL(source as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any]
        let width = properties?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = properties?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let size = (try? source.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let kind = (CGImageSourceGetType(input) as String?).flatMap { UTType($0) }
        let common = [UTType.jpeg, .png, .gif, .webP].contains { kind?.conforms(to: $0) == true }
        if common, size <= keepImageBytes, max(width, height) <= maxImagePixels * 2 { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImagePixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary) else { return nil }
        let file = "\(index)-bild.jpg"
        guard let output = CGImageDestinationCreateWithURL(folder.appending(path: file) as CFURL,
                                                           UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(output) ? file : nil
    }

    /// Kleines Vorschaubild für die Übersicht
    static func thumbnail(_ url: URL, pixels: Int = 220) -> CGImage? {
        guard let input = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(input, 0, options as CFDictionary)
    }
}
