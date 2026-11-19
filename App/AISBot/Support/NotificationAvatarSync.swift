import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// Rendert pro Scoop ein Maskottchen-PNG für Mitteilungen in den App-Group-Container
/// (siehe `NotificationAvatars`). Läuft über `WidgetSync.update`, also bei App-Start, nach dem Laden
/// der Bot-Liste und nach jeder Änderung am Aussehen. Vorhandene Bilder mit gleichem Hash werden
/// nicht neu gerendert; veraltete Dateien werden gelöscht.
final class NotificationAvatarSync {
    static let shared = NotificationAvatarSync()

    private var task: Task<Void, Never>?
    /// Zuletzt geschriebene Zuordnung (spart das Einlesen bei jedem Schnappschuss).
    private var lastIndex: NotificationAvatars.Index?

    func update(bots: [WidgetBot]) {
        let wanted = Dictionary(bots.map { b in
            (b.id, NotificationAvatars.Entry(name: b.name,
                                             file: NotificationAvatars.fileName(botID: b.id,
                                                                                appearanceKey: Self.appearanceKey(b.mascot, seed: b.id))))
        }, uniquingKeysWith: { a, _ in a })
        let index = NotificationAvatars.Index(version: NotificationAvatars.renderVersion, bots: wanted)
        guard index != lastIndex else { return }
        let mascots = Dictionary(bots.map { ($0.id, $0.mascot) }, uniquingKeysWith: { a, _ in a })

        task?.cancel()
        task = Task { [weak self] in
            guard let folder = NotificationAvatars.folderURL else { return }
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var saved = index
            for (id, entry) in wanted.sorted(by: { $0.key < $1.key }) {
                guard !Task.isCancelled else { return }
                let url = folder.appending(path: entry.file)
                guard !FileManager.default.fileExists(atPath: url.path), let mascot = mascots[id] else { continue }
                // Eigenes Bild: erst laden. Klappt das nicht, bleibt der Eintrag weg und wird beim nächsten Mal erneut versucht.
                if let photo = mascot.photo, !(await ScoopPhotoCache.shared.ensure(photo)) {
                    saved.bots[id] = nil
                    continue
                }
                Self.render(mascot: mascot, seed: id, to: url)
                // Zwischen zwei Bildern die Oberfläche atmen lassen (Rendern läuft auf dem MainActor).
                await Task.yield()
            }
            guard !Task.isCancelled else { return }
            NotificationAvatars.saveIndex(saved)
            Self.removeStaleFiles(in: folder, keeping: Set(saved.bots.values.map(\.file)))
            self?.lastIndex = saved
        }
    }

    /// Alles, was das Aussehen bestimmt. Der Fell-Startwert ist die Bot-ID (wie in Seitenleiste und Chat).
    static func appearanceKey(_ m: Mascot, seed: String) -> String {
        if let photo = m.photo { return "photo|\(photo.id)|\(photo.version)" }  // eigenes Bild (v1.12)
        return "\(m.shape)|\(m.color.uppercased())|\(m.eyes)|\(m.accessory)\(m.styleKeySuffix)|\(seed)"
    }

    private static func render(mascot: Mascot, seed: String, to url: URL) {
        let side = CGFloat(NotificationAvatars.pixelSize) / 2
        let renderer = ImageRenderer(content: NotificationAvatarArtwork(mascot: mascot, seed: seed, side: side))
        renderer.scale = 2
        renderer.isOpaque = true
        guard let image = renderer.cgImage,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    private static func removeStaleFiles(in folder: URL, keeping keep: Set<String>) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in files where name.hasSuffix(".png") && !keep.contains(name) {
            try? FileManager.default.removeItem(at: folder.appending(path: name))
        }
    }
}

/// Bildaufbau für den runden Absender-Avatar: dunkle, leicht in der Körperfarbe getönte Fläche
/// (füllt das ganze Quadrat, das System schneidet rund aus) und das Maskottchen mittig, so klein,
/// dass Fell und Kopfschmuck innerhalb des Kreises bleiben.
struct NotificationAvatarArtwork: View {
    var mascot: Mascot
    var seed: String
    var side: CGFloat

    var body: some View {
        let tint = Color(hex: mascot.color)
        // Eigenes Bild: füllt das ganze Quadrat (das System schneidet rund aus)
        if let photo = mascot.photo,
           let image = ScoopPhotoCache.shared.image(for: photo, pixels: NotificationAvatars.pixelSize) {
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: side, height: side)
                .clipped()
        } else {
            mascotArtwork(tint: tint)
        }
    }

    private func mascotArtwork(tint: Color) -> some View {
        var plain = mascot
        plain.photo = nil
        return ZStack {
            Color(hex: "#1B1B1D")
            RadialGradient(colors: [tint.opacity(0.42), tint.opacity(0.12)],
                           center: UnitPoint(x: 0.35, y: 0.28), startRadius: 0, endRadius: side * 0.85)
            MascotView(mascot: plain, size: side * 0.8, seed: seed, animated: false, cached: false)
                .offset(y: side * 0.04)
        }
        .frame(width: side, height: side)
        .environment(\.theme, .nacht)
    }
}
