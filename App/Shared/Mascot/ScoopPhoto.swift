import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// MARK: - Eigenes Scoop-Bild (statt des gezeichneten Maskottchens)
//
// Der Server schickt in `mascot.photo` nur einen Verweis `{id, version}` (keine Bilddaten, auch nicht in
// Pushes/Live-Aktivitäten). Die App lädt das Bild einmal pro Version über `GET /api/bots/{id}/avatar`
// und legt es im App-Group-Container ab (`ScoopPhotos/<id>-<version>.img`). Widgets, Live-Aktivität und
// Mitteilungen lesen nur von dort.
//
// Zentrale Stelle für die Anzeige ist `MascotView`: Hat das Maskottchen ein `photo`, zeichnet es
// automatisch `ScoopPhotoSlot` (rundes Bild) statt Fell, Gesicht und Accessoire. Dadurch zeigen
// Seitenleiste, Chat, @-Liste, Befehlspalette, Profil, Gruppen, Widgets und Live-Aktivität das Bild,
// ohne dass jede Stelle einzeln verdrahtet ist.

/// Verweis auf ein eigenes Scoop-Bild (Server: `mascot.photo`).
nonisolated struct MascotPhoto: Codable, Hashable, Sendable {
    /// Bot-ID (`b_…`)
    var id: String
    /// Version (Millisekunden-Zeitstempel des Uploads). Neue Version → Bild neu laden.
    var version: Int
}

/// Zwischenspeicher für Scoop-Bilder: Dateien im App-Group-Container + verkleinerte Fassungen im Speicher.
@MainActor @Observable
final class ScoopPhotoCache {
    static let shared = ScoopPhotoCache()

    /// Zählt fertig geladene Bilder. Ansichten, die ein Bild lesen, beobachten diesen Wert und zeichnen danach neu.
    private(set) var revision = 0

    /// Lädt die Bilddaten (nur in der Haupt-App gesetzt, Widgets laden nichts nach).
    @ObservationIgnored var fetcher: ((MascotPhoto) async throws -> Data)?
    /// Wird nach jedem neu gespeicherten Bild aufgerufen (App: Widgets neu laden).
    @ObservationIgnored var onStored: ((MascotPhoto) -> Void)?

    @ObservationIgnored private var memory: [String: CGImage] = [:]
    @ObservationIgnored private var memoryOrder: [String] = []
    @ObservationIgnored private var inflight: [MascotPhoto: Task<Bool, Never>] = [:]
    @ObservationIgnored private var failedAt: [MascotPhoto: Date] = [:]

    #if WIDGET_EXTENSION
    private let memoryLimit = 24
    private let maxPixels = 256
    #else
    private let memoryLimit = 160
    private let maxPixels = 1024
    #endif

    // MARK: Dateien

    #if os(macOS)
    nonisolated static let appGroup = "MYXQKK3T2Z.com.ais.aisbot"
    #else
    nonisolated static let appGroup = "group.com.ais.aisbot"
    #endif

    nonisolated static var folderURL: URL? {
        let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        return base?.appending(path: "ScoopPhotos", directoryHint: .isDirectory)
    }

    nonisolated static func safeID(_ id: String) -> String {
        String(id.map { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" ? $0 : "_" })
    }

    nonisolated static func fileURL(_ photo: MascotPhoto) -> URL? {
        folderURL?.appending(path: "\(safeID(photo.id))-\(photo.version).img")
    }

    nonisolated static func hasFile(_ photo: MascotPhoto) -> Bool {
        guard let url = fileURL(photo) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Speichert Bilddaten für eine Version und entfernt ältere Versionen desselben Scoops.
    func store(_ data: Data, for photo: MascotPhoto) {
        guard let folder = Self.folderURL, let url = Self.fileURL(photo) else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        guard (try? data.write(to: url, options: .atomic)) != nil else { return }
        removeFiles(of: photo.id, keepVersion: photo.version)
        failedAt[photo] = nil
        revision += 1
        onStored?(photo)
    }

    /// Entfernt alle Dateien eines Scoops (z. B. nach „Zurück zum Maskottchen“ oder Löschen).
    func remove(botID: String) {
        removeFiles(of: botID, keepVersion: nil)
    }

    private func removeFiles(of botID: String, keepVersion: Int?) {
        let prefix = Self.safeID(botID) + "-"
        let keep = keepVersion.map { "\(prefix)\($0)" }
        if let folder = Self.folderURL,
           let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) {
            for name in names where name.hasPrefix(prefix) && name != keep.map({ "\($0).img" }) {
                try? FileManager.default.removeItem(at: folder.appending(path: name))
            }
        }
        // Speicher: Schlüssel `<id>-<version>@<pixel>`
        for key in Array(memory.keys) where key.hasPrefix(prefix) && !(keep.map { key.hasPrefix($0 + "@") } ?? false) {
            memory[key] = nil
        }
        memoryOrder.removeAll { memory[$0] == nil }
    }

    // MARK: Lesen

    /// Bild in passender Auflösung (Pixel der längsten Kante), `nil`, solange es noch nicht geladen ist.
    func image(for photo: MascotPhoto, pixels: Int) -> CGImage? {
        _ = revision  // Beobachtung: nach einem Download neu zeichnen
        let bucket = min(maxPixels, [64, 128, 256, 512, 1024].first { $0 >= pixels } ?? 1024)
        let key = "\(Self.safeID(photo.id))-\(photo.version)@\(bucket)"
        if let hit = memory[key] { return hit }
        guard let url = Self.fileURL(photo), let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: bucket,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        memory[key] = image
        memoryOrder.append(key)
        if memoryOrder.count > memoryLimit {
            memory[memoryOrder.removeFirst()] = nil
        }
        return image
    }

    /// true, wenn das Bild gleich nachgeladen wird (dann zeigt die Ansicht einen ruhigen Platzhalter statt des Maskottchens).
    func willLoad(_ photo: MascotPhoto) -> Bool {
        guard fetcher != nil else { return false }
        if let failed = failedAt[photo], Date().timeIntervalSince(failed) < 60 { return false }
        return true
    }

    // MARK: Laden

    /// Startet das Laden im Hintergrund (doppelte Anfragen werden zusammengefasst).
    func request(_ photo: MascotPhoto) {
        guard inflight[photo] == nil, !Self.hasFile(photo), willLoad(photo) else { return }
        Task { await ensure(photo) }
    }

    /// Stellt sicher, dass die Datei vorliegt (lädt sie bei Bedarf). Gibt false zurück, wenn das nicht ging.
    @discardableResult
    func ensure(_ photo: MascotPhoto) async -> Bool {
        if Self.hasFile(photo) { return true }
        if let running = inflight[photo] { return await running.value }
        guard let fetcher, willLoad(photo) else { return false }
        let task = Task { () -> Bool in
            guard let data = try? await fetcher(photo), !data.isEmpty,
                  CGImageSourceCreateWithData(data as CFData, nil) != nil else { return false }
            self.store(data, for: photo)
            return true
        }
        inflight[photo] = task
        let ok = await task.value
        inflight[photo] = nil
        if !ok { failedAt[photo] = Date(); revision += 1 }
        return ok
    }
}

// MARK: - Anzeige

/// Rundes Scoop-Bild in der Größe eines Maskottchens. Solange das Bild lädt, erscheint eine ruhige
/// Fläche in der Akzentfarbe; ist es nicht verfügbar (z. B. Widget ohne Datei), das Maskottchen (`fallback`).
struct ScoopPhotoSlot<Fallback: View>: View {
    var photo: MascotPhoto
    var size: CGFloat
    var tint: Color
    var mood: MascotMood = .idle
    var animated: Bool = true
    var showsGround: Bool = false
    @ViewBuilder var fallback: () -> Fallback

    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let cache = ScoopPhotoCache.shared
        let diameter = size * (showsGround ? 0.84 : 1)
        Group {
            if let image = cache.image(for: photo, pixels: Int((diameter * displayScale).rounded(.up))) {
                ScoopPhotoCircle(image: image, size: size, diameter: diameter, tint: tint, mood: mood,
                                 animated: animated, showsGround: showsGround)
            } else if cache.willLoad(photo) {
                Circle()
                    .fill(tint.opacity(0.22))
                    .overlay(Circle().strokeBorder(tint.opacity(0.35), lineWidth: max(0.5, diameter * 0.02)))
                    .frame(width: diameter, height: diameter)
                    .frame(width: size, height: size)
            } else {
                fallback()
            }
        }
        .task(id: photo) { cache.request(photo) }
        .accessibilityHidden(true)
    }
}

/// Das eigentliche runde Bild mit dezentem Rand. Arbeitet der Scoop, schimmert hinter dem Bild ein weiches,
/// pulsierendes Leuchten aus seinen eigenen Farben (statt Wackeln des Maskottchens); beim Sprechen pulsiert es leicht.
struct ScoopPhotoCircle: View {
    var image: CGImage
    var size: CGFloat
    var diameter: CGFloat
    var tint: Color
    var mood: MascotMood
    var animated: Bool
    var showsGround: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme

    private var live: Bool { animated && !reduceMotion && (mood == .working || mood == .speaking) }

    var body: some View {
        if live {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { ctx in
                content(time: ctx.date.timeIntervalSinceReferenceDate)
            }
        } else {
            content(time: nil)
        }
    }

    private func content(time: Double?) -> some View {
        let working = mood == .working || mood == .workingStill
        let pulse = (mood == .speaking && time != nil) ? 1 + 0.035 * abs(sin((time ?? 0) * 5.5)) : 1
        return ZStack {
            if showsGround {
                Ellipse()
                    .fill(theme.mascotGround)
                    .frame(width: size * 0.5, height: size * 0.075)
                    .blur(radius: size * 0.035)
                    .offset(y: size * 0.45)
            }
            Image(decorative: image, scale: 1)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: max(0.5, diameter * 0.01)))
                .scaleEffect(pulse)
                .background {
                    if working {
                        ScoopPhotoGlow(image: image, diameter: diameter, tint: tint, pulsing: !reduceMotion)
                    }
                }
                .offset(y: showsGround ? -size * 0.04 : 0)
        }
        .frame(width: size, height: size)
    }
}

/// Leuchten hinter dem Foto eines arbeitenden Scoops: das Bild selbst stark weichgezeichnet und gesättigt,
/// darunter ein Hauch Akzentfarbe. Pulsiert sanft (Opazität und Größe, läuft im Render-Server, kein Neuzeichnen
/// pro Bild); bei „Bewegung reduzieren“ leuchtet es ruhig.
struct ScoopPhotoGlow: View {
    var image: CGImage
    var diameter: CGFloat
    var tint: Color
    var pulsing: Bool

    var body: some View {
        let halo = ZStack {
            Circle()
                .fill(tint.opacity(0.55))
                .frame(width: diameter * 0.86, height: diameter * 0.86)
                .blur(radius: diameter * 0.2)
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: diameter, height: diameter)
                .clipShape(Circle())
                .saturation(1.5)
                .blur(radius: diameter * 0.15)
        }
        .compositingGroup()
        .allowsHitTesting(false)
        .accessibilityHidden(true)

        if pulsing {
            // Deutliches Atmen: fast aus ↔ voll und größer (vorher 0,5–0,75 / 1,08–1,14: man sah das Leuchten,
            // aber kaum das Pulsieren)
            halo.phaseAnimator([false, true]) { view, bright in
                view
                    .opacity(bright ? 1.0 : 0.12)
                    .scaleEffect(bright ? 1.24 : 1.0)
                    .brightness(bright ? 0.08 : 0)
            } animation: { _ in .easeInOut(duration: 1.25) }
        } else {
            halo.opacity(0.62).scaleEffect(1.11)
        }
    }
}

// MARK: - Bilddaten für den Upload

/// Bilder laden (richtig gedreht, verkleinert) und als quadratisches JPEG/PNG für den Server kodieren.
nonisolated enum ScoopPhotoCoding {
    /// Liest beliebige Bilddaten (JPEG, PNG, HEIC …), richtig gedreht und auf höchstens `maxPixels` verkleinert.
    static func image(from data: Data, maxPixels: Int = 2400) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Schneidet `rect` (Pixel im Bild) aus und skaliert auf höchstens `side` × `side`.
    static func crop(_ image: CGImage, to rect: CGRect, side: Int = 512) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let r = rect.integral
        let out = min(side, max(1, Int(r.width)))
        let alpha = hasAlpha(image)
        guard let ctx = CGContext(data: nil, width: out, height: out, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue
                                                    : CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        if !alpha {
            ctx.setFillColor(CGColor(gray: 0.1, alpha: 1))  // falls der Ausschnitt über den Rand ragt
            ctx.fill(CGRect(x: 0, y: 0, width: out, height: out))
        }
        // Quartz zählt y von unten: Bild so verschieben und skalieren, dass `r` genau die Fläche füllt.
        let k = CGFloat(out) / r.width
        let drawRect = CGRect(x: -r.minX * k, y: -(bounds.height - r.maxY) * k,
                              width: bounds.width * k, height: bounds.height * k)
        ctx.draw(image, in: drawRect)
        return ctx.makeImage()
    }

    /// JPEG (ohne Transparenz) bzw. PNG (mit Transparenz).
    static func encode(_ image: CGImage) -> Data? {
        let alpha = hasAlpha(image)
        let out = NSMutableData()
        let type = (alpha ? UTType.png : UTType.jpeg).identifier as CFString
        guard let dest = CGImageDestinationCreateWithData(out, type, 1, nil) else { return nil }
        let props: [CFString: Any] = alpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    /// MIME-Typ anhand der ersten Bytes (PNG-Signatur), sonst JPEG.
    static func mimeType(of data: Data) -> String {
        data.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }
}
