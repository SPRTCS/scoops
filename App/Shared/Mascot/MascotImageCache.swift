import SwiftUI

/// Zwischenspeicher für gerenderte Maskottchen (Fell als Bild statt tausender Canvas-Pfade pro Neuzeichnen).
/// Schlüssel: Maskottchen, Größe, Stimmung, Startwert, Bodenschatten/Theme und Bildschirm-Skalierung.
@MainActor
final class MascotImageCache {
    static let shared = MascotImageCache()

    private var images: [String: CGImage] = [:]
    private var order: [String] = []
    private let limit = 600

    func image(for key: String, render: () -> CGImage?) -> CGImage? {
        if let hit = images[key] { return hit }
        // Leere Renderings nie merken: Rendert iOS die App im Hintergrund (Start für Mitteilungen, Live-Aktivität,
        // Widgets), liefert ImageRenderer teils ein komplett durchsichtiges Bild. Einmal gespeichert, fehlten danach
        // dauerhaft die Körper der Scoops (nur Augen/Accessoires sichtbar, Gruppenbild unvollständig). Dann zeichnet
        // die Ansicht direkt (Canvas) und versucht es beim nächsten Mal erneut.
        guard let img = render(), !Self.isBlank(img) else { return nil }
        images[key] = img
        order.append(key)
        if order.count > limit {
            let drop = order.removeFirst()
            images[drop] = nil
        }
        return img
    }

    /// Ist das Bild praktisch leer (keine sichtbaren Pixel)? Prüft eine kleine verkleinerte Kopie.
    nonisolated static func isBlank(_ image: CGImage) -> Bool {
        let side = 24
        guard let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = ctx.data else { return false }
        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let px = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
        for i in stride(from: 3, to: side * side * 4, by: 4) where px[i] > 6 { return false }
        return true
    }

    static func render<V: View>(_ view: V, scale: CGFloat) -> CGImage? {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = false
        return renderer.cgImage
    }
}
