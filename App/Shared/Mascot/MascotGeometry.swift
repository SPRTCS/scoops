import CoreGraphics
import Foundation
import Synchronization

/// Reproduzierbarer Zufall (SplitMix64), damit das Fell pro Bot immer gleich aussieht.
nonisolated struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    init(string: String) {
        // FNV-1a (stabil über App-Starts, anders als Hasher)
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in string.utf8 { h ^= UInt64(b); h = h &* 0x100_0000_01b3 }
        self.init(seed: h)
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Gleichverteilt in 0..<1
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
}

/// Umriss und Ankerpunkte einer Maskottchen-Form in Einheitskoordinaten (0…1, y nach unten).
nonisolated struct MascotGeometry {
    var points: [CGPoint]          // geschlossener Umriss, gegen den Uhrzeigersinn auf dem Bildschirm
    var normals: [CGPoint]         // nach außen zeigende Einheitsnormalen
    var faceCenter: CGPoint
    var eyeSpacing: Double         // halber Augenabstand
    var eyeScale: Double
    var bounds: CGRect
    var headTop: CGPoint           // höchster Punkt über der Mitte (für Hüte)
    var tilt: Double               // leichte Neigung der Hüte (Radiant)

    /// Breite des Körpers auf Höhe y (links, rechts).
    func span(atY y: Double) -> (Double, Double) {
        var left = 1.0, right = 0.0
        let n = points.count
        for i in 0..<n {
            let a = points[i], b = points[(i + 1) % n]
            if (a.y - y) * (b.y - y) <= 0, a.y != b.y {
                let t = (y - a.y) / (b.y - a.y)
                let x = a.x + (b.x - a.x) * t
                left = min(left, x); right = max(right, x)
            }
        }
        if left > right { return (bounds.minX, bounds.maxX) }
        return (left, right)
    }

    private static let cache = Mutex<[String: MascotGeometry]>([:])

    /// Geometrie einer Form (zwischengespeichert). Unbekannte Formen fallen auf `bean` zurück.
    static func make(shape: String) -> MascotGeometry {
        if let hit = cache.withLock({ $0[shape] }) { return hit }
        let g = build(shape: shape)
        cache.withLock { $0[shape] = g }
        return g
    }

    private static func build(shape: String) -> MascotGeometry {
        let n = 240
        var pts: [CGPoint] = []
        var face = CGPoint(x: 0.5, y: 0.58)
        var spacing = 0.098
        var eyeScale = 1.0
        var tilt = 0.0

        func polar(cx: Double, cy: Double, rx: Double, ry: Double, _ r: (Double) -> Double,
                   warp: ((Double, Double, Double) -> (Double, Double))? = nil) {
            for i in 0..<n {
                let th = Double(i) / Double(n) * 2 * .pi
                let rr = r(th)
                var x = cos(th) * rr * rx
                var y = sin(th) * rr * ry
                if let warp { (x, y) = warp(x, y, th) }
                pts.append(CGPoint(x: cx + x, y: cy + y))
            }
        }

        switch shape {
        case "egg":
            polar(cx: 0.5, cy: 0.575, rx: 0.305, ry: 0.355, { _ in 1 }) { x, y, th in
                (x * (1 + 0.13 * sin(th)), y)
            }
            face = CGPoint(x: 0.5, y: 0.6)

        case "pear":
            polar(cx: 0.5, cy: 0.575, rx: 0.33, ry: 0.355, { _ in 1 }) { x, y, th in
                let s = sin(th)
                let taper = 0.74 + 0.26 * (s + 1) / 2
                let waist = 1 - 0.16 * exp(-pow(s + 0.35, 2) / 0.07)
                return (x * taper * waist, y)
            }
            face = CGPoint(x: 0.5, y: 0.655)
            spacing = 0.1

        case "cloud":
            polar(cx: 0.5, cy: 0.6, rx: 0.37, ry: 0.27, { th in
                let s = sin(th)
                let bumps = 0.5 + 0.5 * cos(7 * th + 0.4)
                let topWeight = max(0, -s * 0.9 + 0.25)
                return 1 + 0.085 * pow(bumps, 1.6) * min(1, topWeight)
            }) { x, y, th in
                let s = sin(th)
                return (x, s > 0 ? y * 0.86 : y)
            }
            face = CGPoint(x: 0.5, y: 0.6)
            spacing = 0.105

        case "blob":
            polar(cx: 0.5, cy: 0.585, rx: 0.335, ry: 0.315, { th in
                1 + 0.07 * sin(3 * th + 0.6) + 0.045 * cos(2 * th + 1.4) + 0.025 * sin(5 * th + 2.1)
            })
            face = CGPoint(x: 0.49, y: 0.58)

        case "star":
            // organischer Stern: Zacken unterschiedlich lang und leicht gebogen
            polar(cx: 0.5, cy: 0.585, rx: 0.39, ry: 0.385, { th in
                let bend = 0.12 * sin(th * 2 + 0.7)
                let c = cos(5 * (th + .pi / 2 + bend))
                let arm = 1 + 0.07 * sin(th * 3 + 1.1)
                return (0.70 + 0.30 * (c >= 0 ? pow(c, 0.85) : -pow(-c, 1.4))) * arm
            })
            face = CGPoint(x: 0.5, y: 0.6)
            spacing = 0.085
            eyeScale = 0.92

        case "drop":
            for i in 0..<n {
                let t = Double(i) / Double(n) * 2 * .pi
                let x = 0.335 * sin(t) * pow(abs(sin(t / 2)), 1.15)
                let y = -0.395 * cos(t)
                pts.append(CGPoint(x: 0.5 + x, y: 0.55 + y))
            }
            face = CGPoint(x: 0.5, y: 0.66)

        case "bun":
            polar(cx: 0.5, cy: 0.63, rx: 0.39, ry: 0.29, { _ in 1 }) { x, y, th in
                let s = sin(th), c = cos(th)
                if s > 0 {
                    // flacher Boden (Superellipse)
                    let e = 2.0 / 3.2
                    let sx = (c >= 0 ? 1 : -1) * pow(abs(c), e) * 0.39
                    let sy = pow(s, e) * 0.29 * 0.72
                    return (sx, sy)
                }
                return (x, y)
            }
            face = CGPoint(x: 0.5, y: 0.63)
            spacing = 0.108

        case "ghost":
            let cx = 0.5, top = 0.2, r = 0.3, bottom = 0.88
            let cyTop = top + r
            // Kuppel links → oben → rechts
            for i in 0...80 {
                let th = Double.pi + Double(i) / 80 * Double.pi
                pts.append(CGPoint(x: cx + cos(th) * r, y: cyTop + sin(th) * r))
            }
            // rechte Seite nach unten, leicht ausgestellt
            for i in 1...30 {
                let t = Double(i) / 30
                pts.append(CGPoint(x: cx + r + 0.03 * t * t, y: cyTop + (bottom - cyTop) * t))
            }
            // gewellter Saum von rechts nach links
            let w = r + 0.03
            for i in 1...100 {
                let t = Double(i) / 100
                let x = cx + w - 2 * w * t
                let y = bottom - 0.045 * (0.5 - 0.5 * cos(t * 2 * .pi * 3))
                pts.append(CGPoint(x: x, y: y))
            }
            for i in 1..<30 {
                let t = 1 - Double(i) / 30
                pts.append(CGPoint(x: cx - r - 0.03 * t * t, y: cyTop + (bottom - cyTop) * t))
            }
            // Gegen den Uhrzeigersinn ausrichten folgt unten automatisch
            face = CGPoint(x: 0.5, y: 0.52)
            spacing = 0.1

        case "flower":
            polar(cx: 0.5, cy: 0.585, rx: 0.37, ry: 0.37, { th in
                let c = abs(cos(3 * (th + .pi / 2)))
                return 0.8 + 0.2 * pow(c, 0.7)
            })
            face = CGPoint(x: 0.5, y: 0.6)
            spacing = 0.092

        // MARK: Symmetrische Formen (v1.1)

        case "icon_corner":
            // Nur fürs App-Symbol: exakter Kreis (sichtbar ist seine rechte obere Rundung)
            polar(cx: 0.5, cy: 0.5, rx: 0.4, ry: 0.4, { _ in 1 })
            face = CGPoint(x: 0.5, y: 0.5)

        case "circle":
            polar(cx: 0.5, cy: 0.575, rx: 0.35, ry: 0.35, { _ in 1 })
            face = CGPoint(x: 0.5, y: 0.585)

        case "oval_tall":
            polar(cx: 0.5, cy: 0.565, rx: 0.28, ry: 0.375, { _ in 1 })
            face = CGPoint(x: 0.5, y: 0.565)
            spacing = 0.092

        case "oval_wide":
            polar(cx: 0.5, cy: 0.6, rx: 0.39, ry: 0.28, { _ in 1 })
            face = CGPoint(x: 0.5, y: 0.6)
            spacing = 0.108

        case "square":
            pts = roundedPolygon([CGPoint(x: 0.17, y: 0.24), CGPoint(x: 0.83, y: 0.24),
                                  CGPoint(x: 0.83, y: 0.9), CGPoint(x: 0.17, y: 0.9)], radius: [0.13, 0.13, 0.13, 0.13])
            face = CGPoint(x: 0.5, y: 0.58)
            spacing = 0.105

        case "rect_tall":
            pts = roundedPolygon([CGPoint(x: 0.24, y: 0.17), CGPoint(x: 0.76, y: 0.17),
                                  CGPoint(x: 0.76, y: 0.93), CGPoint(x: 0.24, y: 0.93)], radius: [0.11, 0.11, 0.11, 0.11])
            face = CGPoint(x: 0.5, y: 0.53)
            spacing = 0.09

        case "rect_wide":
            pts = roundedPolygon([CGPoint(x: 0.12, y: 0.34), CGPoint(x: 0.88, y: 0.34),
                                  CGPoint(x: 0.88, y: 0.88), CGPoint(x: 0.12, y: 0.88)], radius: [0.11, 0.11, 0.11, 0.11])
            face = CGPoint(x: 0.5, y: 0.6)
            spacing = 0.11

        case "triangle":
            pts = roundedPolygon([CGPoint(x: 0.5, y: 0.15), CGPoint(x: 0.9, y: 0.88), CGPoint(x: 0.1, y: 0.88)],
                                 radius: [0.08, 0.1, 0.1])
            face = CGPoint(x: 0.5, y: 0.68)
            spacing = 0.088
            eyeScale = 0.92

        case "diamond":
            pts = roundedPolygon([CGPoint(x: 0.5, y: 0.14), CGPoint(x: 0.87, y: 0.555),
                                  CGPoint(x: 0.5, y: 0.97), CGPoint(x: 0.13, y: 0.555)], radius: [0.08, 0.09, 0.08, 0.09])
            face = CGPoint(x: 0.5, y: 0.56)
            spacing = 0.088
            eyeScale = 0.92

        case "hexagon":
            var v: [CGPoint] = []
            for i in 0..<6 {
                let a = Double(i) / 6 * 2 * .pi
                v.append(CGPoint(x: 0.5 + cos(a) * 0.385, y: 0.565 + sin(a) * 0.36))
            }
            pts = roundedPolygon(v, radius: Array(repeating: 0.075, count: 6))
            face = CGPoint(x: 0.5, y: 0.575)
            spacing = 0.1

        case "heart":
            for i in 0..<240 {
                let t = Double(i) / 240 * 2 * .pi
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                pts.append(CGPoint(x: 0.5 + x * 0.0225, y: 0.52 - y * 0.0225))
            }
            face = CGPoint(x: 0.5, y: 0.5)
            spacing = 0.1

        case "arrow":
            pts = roundedPolygon([CGPoint(x: 0.5, y: 0.12), CGPoint(x: 0.88, y: 0.5), CGPoint(x: 0.67, y: 0.5),
                                  CGPoint(x: 0.67, y: 0.93), CGPoint(x: 0.33, y: 0.93), CGPoint(x: 0.33, y: 0.5),
                                  CGPoint(x: 0.12, y: 0.5)],
                                 radius: [0.07, 0.06, 0.04, 0.08, 0.08, 0.04, 0.06])
            face = CGPoint(x: 0.5, y: 0.66)
            spacing = 0.07
            eyeScale = 0.82

        case "pill":
            pts = roundedPolygon([CGPoint(x: 0.27, y: 0.15), CGPoint(x: 0.73, y: 0.15),
                                  CGPoint(x: 0.73, y: 0.93), CGPoint(x: 0.27, y: 0.93)], radius: [0.229, 0.229, 0.229, 0.229])
            face = CGPoint(x: 0.5, y: 0.52)
            spacing = 0.085
            eyeScale = 0.95

        case "flower_round":
            // 6 runde Blütenblätter um eine Mitte: äußerer Rand der Kreisvereinigung
            let petals = (0..<6).map { i -> (CGPoint, Double) in
                let a = Double(i) / 6 * 2 * .pi - .pi / 2
                return (CGPoint(x: cos(a) * 0.255, y: sin(a) * 0.255), 0.135)
            } + [(CGPoint.zero, 0.215)]
            for i in 0..<360 {
                let th = Double(i) / 360 * 2 * .pi
                let ux = cos(th), uy = sin(th)
                var best = 0.0
                for (c, r) in petals {
                    let b = ux * c.x + uy * c.y
                    let disc = b * b - (c.x * c.x + c.y * c.y) + r * r
                    if disc >= 0 { best = max(best, b + sqrt(disc)) }
                }
                pts.append(CGPoint(x: 0.5 + ux * best, y: 0.575 + uy * best))
            }
            face = CGPoint(x: 0.5, y: 0.585)
            spacing = 0.09

        case "star_soft":
            var v: [CGPoint] = []
            var radii: [Double] = []
            for i in 0..<10 {
                let a = Double(i) / 10 * 2 * .pi - .pi / 2
                let outer = i % 2 == 0
                let r = outer ? 0.405 : 0.205
                v.append(CGPoint(x: 0.5 + cos(a) * r, y: 0.585 + sin(a) * r))
                radii.append(outer ? 0.075 : 0.05)
            }
            pts = roundedPolygon(v, radius: radii)
            face = CGPoint(x: 0.5, y: 0.6)
            spacing = 0.08
            eyeScale = 0.9

        default: // bean
            polar(cx: 0.5, cy: 0.575, rx: 0.29, ry: 0.36, { th in
                let dent = 0.075 * exp(-pow(angleDiff(th, .pi * 1.02), 2) / 0.2)
                return 1 - dent
            }) { x, y, th in
                // leichte Bohnen-Neigung
                let a = -0.16
                return (x * cos(a) - y * sin(a), x * sin(a) + y * cos(a))
            }
            face = CGPoint(x: 0.515, y: 0.57)
            spacing = 0.094
            tilt = -0.14
        }

        // Gleichmäßig verteilen (wichtig für gleichmäßiges Fell an Ecken und Kanten)
        pts = resample(pts, count: 240)

        // Ausrichtung prüfen (Shoelace) und Normalen berechnen
        var area = 0.0
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            area += a.x * b.y - b.x * a.y
        }
        if area < 0 { pts.reverse() }
        let count = pts.count
        var normals: [CGPoint] = []
        normals.reserveCapacity(count)
        for i in 0..<count {
            let p = pts[(i + count - 2) % count], q = pts[(i + 2) % count]
            var tx = q.x - p.x, ty = q.y - p.y
            let len = max(1e-9, sqrt(tx * tx + ty * ty))
            tx /= len; ty /= len
            // positive Fläche (y nach unten): außen liegt rechts der Laufrichtung
            normals.append(CGPoint(x: ty, y: -tx))
        }

        var minX = 1.0, minY = 1.0, maxX = 0.0, maxY = 0.0
        for p in pts { minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y) }
        let bounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Kopfoberkante nahe der Mitte
        var top = CGPoint(x: 0.5, y: maxY)
        for p in pts where abs(p.x - face.x) < 0.09 && p.y < top.y { top = CGPoint(x: face.x, y: p.y) }

        return MascotGeometry(points: pts, normals: normals, faceCenter: face, eyeSpacing: spacing,
                              eyeScale: eyeScale, bounds: bounds, headTop: top, tilt: tilt)
    }

    /// Polygon mit abgerundeten Ecken (konvex und konkav), dicht abgetastet.
    static func roundedPolygon(_ v: [CGPoint], radius: [Double]) -> [CGPoint] {
        var out: [CGPoint] = []
        let n = v.count
        for i in 0..<n {
            let p = v[(i + n - 1) % n], c = v[i], q = v[(i + 1) % n]
            var ax = p.x - c.x, ay = p.y - c.y
            var bx = q.x - c.x, by = q.y - c.y
            let la = hypot(ax, ay), lb = hypot(bx, by)
            ax /= la; ay /= la; bx /= lb; by /= lb
            let theta = acos(max(-1, min(1, ax * bx + ay * by)))
            let r = radius[i]
            let d = min(r / tan(theta / 2), min(la, lb) * 0.49)
            let rr = d * tan(theta / 2)
            let t1 = CGPoint(x: c.x + ax * d, y: c.y + ay * d)
            let t2 = CGPoint(x: c.x + bx * d, y: c.y + by * d)
            var mx = ax + bx, my = ay + by
            let lm = max(1e-9, hypot(mx, my)); mx /= lm; my /= lm
            let dist = rr / sin(theta / 2)
            let center = CGPoint(x: c.x + mx * dist, y: c.y + my * dist)
            let a1 = atan2(t1.y - center.y, t1.x - center.x)
            let a2 = atan2(t2.y - center.y, t2.x - center.x)
            var delta = a2 - a1
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            let steps = 14
            for k in 0...steps {
                let a = a1 + delta * Double(k) / Double(steps)
                out.append(CGPoint(x: center.x + cos(a) * rr, y: center.y + sin(a) * rr))
            }
        }
        return out
    }

    /// Verteilt die Punkte eines geschlossenen Umrisses gleichmäßig nach Bogenlänge.
    static func resample(_ pts: [CGPoint], count: Int) -> [CGPoint] {
        guard pts.count > 2 else { return pts }
        var cum: [Double] = [0]
        for i in 0..<pts.count {
            let a = pts[i], b = pts[(i + 1) % pts.count]
            cum.append(cum[cum.count - 1] + hypot(b.x - a.x, b.y - a.y))
        }
        let total = cum[cum.count - 1]
        guard total > 0 else { return pts }
        var out: [CGPoint] = []
        out.reserveCapacity(count)
        var seg = 0
        for k in 0..<count {
            let target = total * Double(k) / Double(count)
            while seg < pts.count - 1, cum[seg + 1] < target { seg += 1 }
            let a = pts[seg], b = pts[(seg + 1) % pts.count]
            let len = cum[seg + 1] - cum[seg]
            let t = len > 0 ? (target - cum[seg]) / len : 0
            out.append(CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
        return out
    }

    private static func angleDiff(_ a: Double, _ b: Double) -> Double {
        var d = (a - b).truncatingRemainder(dividingBy: 2 * .pi)
        if d > .pi { d -= 2 * .pi }
        if d < -.pi { d += 2 * .pi }
        return d
    }

    /// Umriss als Pfad in Punktkoordinaten.
    func path(size: CGFloat, inset: CGFloat = 0) -> CGPath {
        let p = CGMutablePath()
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        for (i, pt) in points.enumerated() {
            var x = pt.x, y = pt.y
            if inset != 0 {
                x -= normals[i].x * inset; y -= normals[i].y * inset
            }
            _ = c
            let q = CGPoint(x: x * size, y: y * size)
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.closeSubpath()
        return p
    }
}
