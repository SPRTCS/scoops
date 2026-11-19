import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Stimmung bzw. Pose eines Scoops.
enum MascotMood: Equatable, Sendable {
    case idle
    case working
    /// Statische Arbeits-Pose für Widgets (geneigt, Bewegungslinien, Funken).
    case workingStill
    /// Spricht (Sprachmodus): Mund geht auf und zu, leichtes Wippen.
    case speaking
    /// Hört zu (Sprachmodus): aufmerksam, leicht geneigt.
    case listening
}

/// Flauschiges Plüsch-Maskottchen, komplett in SwiftUI gezeichnet.
/// Aufbau: hinteres Fell → Körper mit Verlauf → Fellstruktur → vorderes Fell → Gesicht → Accessoire.
struct MascotView: View {
    var mascot: Mascot
    var size: CGFloat
    var mood: MascotMood = .idle
    /// Startwert für das zufällige Fell (Bot-ID), damit es stabil bleibt.
    var seed: String? = nil
    var animated: Bool = true
    var showsGround: Bool = false
    /// Gesicht verschieben (Einheiten der Maskottchengröße, z. B. (0.08, -0.08) = Blick nach rechts oben) und skalieren.
    /// Wird für die App-Symbole genutzt, bei denen der Körper angeschnitten ist.
    var faceShift: CGPoint = .zero
    var faceScale: CGFloat = 1
    /// Neigung des Gesichts in Grad (negativ = nach links gekippt, wirkt wie Blick nach rechts oben)
    var faceTilt: Double = 0

    /// false = immer live zeichnen (intern für das Rendern in den Zwischenspeicher)
    var cached: Bool = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    @Environment(\.displayScale) private var displayScale

    /// Widgets rendern direkt (eigener Prozess, knapper Speicher).
    #if WIDGET_EXTENSION
    static let cacheEnabled = false
    #else
    /// `-nocache` schaltet den Zwischenspeicher ab (nur für Vorher/Nachher-Messungen).
    static let cacheEnabled = !ProcessInfo.processInfo.arguments.contains("-nocache")
    #endif

    private var seedString: String {
        seed ?? "\(mascot.shape)|\(mascot.color)|\(mascot.eyes)|\(mascot.accessory)"
    }

    private var shouldAnimate: Bool { animated && !reduceMotion && mood != .workingStill }
    // Hinweis: .speaking/.listening animieren nur, wenn `animated` true ist.

    var body: some View {
        if let photo = mascot.photo {
            // Eigenes Bild (zentral für alle Stellen, auch Widgets und Live-Aktivität)
            ScoopPhotoSlot(photo: photo, size: size, tint: Color(hex: mascot.color), mood: mood, animated: animated,
                           showsGround: showsGround) { withoutPhoto }
        } else {
            mascotBody
        }
    }

    /// Rückfall, solange ein eigenes Bild nicht verfügbar ist: das gezeichnete Maskottchen.
    private var withoutPhoto: MascotView {
        var plain = self
        plain.mascot.photo = nil
        return plain
    }

    private var mascotBody: some View {
        Group {
            if shouldAnimate {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    content(time: context.date.timeIntervalSinceReferenceDate)
                }
            } else if cached && Self.cacheEnabled, let image = staticImage {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .frame(width: size * Self.overflow, height: size * Self.overflow)
            } else {
                content(time: nil)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    /// Statische Darstellung hat etwas Rand für Fell, Hüte und Funken außerhalb des Rahmens.
    static let overflow: CGFloat = 1.4

    private var staticImage: CGImage? {
        let key = "\(mascot.shape)|\(mascot.color)|\(mascot.eyes)|\(mascot.accessory)\(mascot.styleKeySuffix)|\(seedString)|\(size)|\(mood)|"
            + "\(showsGround ? theme.kind.rawValue : "-")|\(displayScale)|\(faceShift.x),\(faceShift.y),\(faceScale),\(faceTilt)"
        let pad = size * Self.overflow
        let view = MascotView(mascot: mascot, size: size, mood: mood, seed: seed, animated: false,
                              showsGround: showsGround, faceShift: faceShift, faceScale: faceScale,
                              faceTilt: faceTilt, cached: false)
            .frame(width: pad, height: pad)
            .environment(\.theme, theme)
        return MascotImageCache.shared.image(for: key) { MascotImageCache.render(view, scale: displayScale) }
    }

    @ViewBuilder
    private func content(time: Double?) -> some View {
        var rng = SeededRandom(string: seedString)
        let phase = rng.range(0, 10)
        let t = (time ?? 0) + phase
        let working = mood == .working
        let still = mood == .workingStill

        // Atmen, Hüpfen und Wackeln
        let breath = time == nil ? 0 : sin(t * 2.1) * 0.5 + 0.5
        let bounce = (working && time != nil) ? abs(sin(t * 5.2)) : 0
        let wiggle = (working && time != nil) ? sin(t * 2.6) * 5.0 : (still ? -9.0 : 0)
        let squash = working ? (1 - bounce) * 0.05 : 0
        let blink = time == nil ? 1 : MascotView.blinkAmount(t: t)
        let speaking = mood == .speaking && time != nil
        let mouth: Double? = speaking ? max(0, sin(t * 11) * 0.5 + sin(t * 7.3) * 0.5) : nil
        let listenTilt = mood == .listening ? sin(t * 1.3) * 3 + 4 : 0
        let speakBob = speaking ? abs(sin(t * 5.5)) * 0.02 : 0
        // Neue Augen: gelegentlicher Blick zur Mitte bzw. kurz zur Seite (nur animiert)
        let gaze = MascotView.animatedGaze(base: mascot.gazeValue, t: t, animate: time != nil && mascot.hasGaze)

        ZStack {
            if showsGround {
                Ellipse()
                    .fill(theme.mascotGround)
                    .frame(width: size * 0.5 * (1 - bounce * 0.18), height: size * 0.075)
                    .blur(radius: size * 0.035)
                    .offset(y: size * 0.42)
            }
            if still { MascotMotionMarks(color: RGB(hex: mascot.color), size: size) }

            // Kleine Avatare etwas größer zeichnen, damit der Körper die Fläche füllt.
            let draw = size * (size < 60 ? 1.16 : 1.0)
            ZStack {
                MascotBody(mascot: mascot, seed: seedString, size: draw).equatable()
                MascotFace(mascot: mascot, size: draw, blink: blink, working: working || still, mouthOpen: mouth,
                           gaze: gaze, faceShift: faceShift, faceScale: faceScale, faceTilt: faceTilt)
            }
            .frame(width: draw, height: draw)
            .offset(y: size < 60 ? -size * 0.04 : 0)
            .frame(width: size, height: size)
            .scaleEffect(x: 1 - 0.012 * breath + squash, y: 1 + 0.02 * breath - squash, anchor: .bottom)
            .offset(y: -bounce * size * 0.06 - speakBob * size)
            .rotationEffect(.degrees(wiggle + listenTilt), anchor: .bottom)
        }
        .frame(width: size, height: size)
    }

    /// Blickrichtung der neuen Augen über die Zeit: hält meist die eingestellte Richtung, schaut etwa alle 7 s für gut
    /// eine Sekunde zur Mitte (bei Blick geradeaus abwechselnd kurz zur Seite).
    static func animatedGaze(base: Double, t: Double, animate: Bool) -> Double {
        guard animate else { return base }
        let period = 7.3
        let local = t.truncatingRemainder(dividingBy: period)
        let cycle = Int(t / period)
        // weich hin (0,3 s), halten, weich zurück (0,3 s)
        let a: Double
        switch local {
        case ..<4.6: a = 0
        case ..<4.9: a = (local - 4.6) / 0.3
        case ..<6.0: a = 1
        case ..<6.3: a = 1 - (local - 6.0) / 0.3
        default: a = 0
        }
        let e = a * a * (3 - 2 * a)
        if base == 0 { return e * 0.6 * (cycle % 2 == 0 ? 1 : -1) }
        return base * (1 - 0.85 * e)
    }

    /// 1 = offen, 0 = zu. Blinzelt alle ~4 s für 0,16 s, gelegentlich doppelt.
    static func blinkAmount(t: Double) -> Double {
        let period = 4.3
        let local = t.truncatingRemainder(dividingBy: period)
        let cycle = Int(t / period)
        func closeness(_ start: Double) -> Double {
            let d = local - start
            guard d >= 0, d < 0.16 else { return 0 }
            return sin(d / 0.16 * .pi)
        }
        var c = closeness(0)
        if cycle % 3 == 0 { c = max(c, closeness(0.24)) }
        return 1 - c
    }
}

// MARK: - Körper mit Fell (teuer, deshalb Equatable und statisch)

struct MascotBody: View, Equatable {
    var mascot: Mascot
    var seed: String
    var size: CGFloat
    @Environment(\.displayScale) private var displayScale

    static func == (a: MascotBody, b: MascotBody) -> Bool {
        a.mascot == b.mascot && a.seed == b.seed && a.size == b.size
    }

    var body: some View {
        if MascotView.cacheEnabled, let img = cachedImage {
            Image(decorative: img, scale: displayScale)
                .resizable()
                .frame(width: size, height: size)
        } else {
            canvas
        }
    }

    private var canvas: some View {
        Canvas(rendersAsynchronously: false) { ctx, canvasSize in
            MascotPainter(mascot: mascot, seed: seed, size: canvasSize.width).drawBody(in: &ctx)
        }
        .frame(width: size, height: size)
    }

    private var cachedImage: CGImage? {
        let key = "body|\(mascot.shape)|\(mascot.color)|\(seed)|\(size)|\(displayScale)"
        return MascotImageCache.shared.image(for: key) { MascotImageCache.render(canvas, scale: displayScale) }
    }
}

struct MascotFace: View {
    var mascot: Mascot
    var size: CGFloat
    var blink: Double
    var working: Bool
    var mouthOpen: Double? = nil
    /// Blickrichtung der neuen Augen (-1 … 1), nil = eingestellte Richtung
    var gaze: Double? = nil
    var faceShift: CGPoint = .zero
    var faceScale: CGFloat = 1
    var faceTilt: Double = 0

    /// Rand um die Zeichenfläche, damit hohe Hüte und Ohren nicht am Rahmen abgeschnitten werden.
    static let overflow: CGFloat = 0.15

    var body: some View {
        // Rand nur mit Accessoire (ohne bleibt die Zeichnung, etwa im App-Symbol, pixelgleich zu vorher)
        let pad = mascot.accessory == "none" ? 0 : (size * Self.overflow).rounded(.up)
        Canvas { ctx, canvasSize in
            ctx.translateBy(x: pad, y: pad)
            let S = canvasSize.width - 2 * pad
            let p = MascotPainter(mascot: mascot, seed: "", size: S)
            var face = ctx
            if faceShift != .zero || faceScale != 1 || faceTilt != 0 {
                let fc = CGPoint(x: p.geo.faceCenter.x * S, y: p.geo.faceCenter.y * S)
                face.translateBy(x: fc.x + faceShift.x * S, y: fc.y + faceShift.y * S)
                face.scaleBy(x: faceScale, y: faceScale)
                face.rotate(by: .degrees(faceTilt))
                face.translateBy(x: -fc.x, y: -fc.y)
            }
            p.drawFace(in: &face, blink: blink, working: working, mouthOpen: mouthOpen, gaze: gaze ?? mascot.gazeValue)
            p.drawAccessory(in: &ctx)
        }
        .frame(width: size + 2 * pad, height: size + 2 * pad)
        .frame(width: size, height: size)
    }
}

/// Bewegungslinien und Funken für die statische Arbeits-Pose (Widgets).
struct MascotMotionMarks: View {
    var color: RGB
    var size: CGFloat

    var body: some View {
        Canvas { ctx, s in
            let S = s.width
            let line = color.mix(.white, 0.25).opacity(0.85).color
            for (i, y) in [0.42, 0.55, 0.68].enumerated() {
                var p = Path()
                let len = [0.1, 0.14, 0.09][i]
                p.move(to: CGPoint(x: S * (0.06), y: S * y))
                p.addLine(to: CGPoint(x: S * (0.06 + len), y: S * y))
                ctx.stroke(p, with: .color(line), style: StrokeStyle(lineWidth: max(1, S * 0.022), lineCap: .round))
            }
            let spark = RGB(hex: "#FFD84D").color
            for (cx, cy, r) in [(0.86, 0.2, 0.06), (0.93, 0.36, 0.035), (0.78, 0.08, 0.03)] {
                ctx.fill(MascotPainter.sparkle(center: CGPoint(x: S * cx, y: S * cy), radius: S * r), with: .color(spark))
            }
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Zeichnen

nonisolated struct MascotPainter {
    let mascot: Mascot
    let seed: String
    let S: CGFloat
    let geo: MascotGeometry
    let base: RGB
    let light: RGB
    let dark: RGB
    let lightCenter: CGPoint
    let lightRadius: Double

    init(mascot: Mascot, seed: String, size: CGFloat) {
        self.mascot = mascot
        self.seed = seed
        self.S = size
        self.geo = MascotGeometry.make(shape: mascot.shape)
        let b = RGB(hex: mascot.color)
        self.base = b
        if b.luminance > 0.82 {
            // Weiß: warme graue Schatten statt Schwarz
            light = RGB.white
            dark = b.mix(RGB(r: 0.62, g: 0.56, b: 0.52), 0.62)
        } else {
            light = b.mix(.white, b.luminance > 0.6 ? 0.42 : 0.36)
            // Schatten im gleichen Farbton, satter und dunkler (statt grau-matschig)
            dark = b.shaded(brightness: 0.66, saturationBoost: 0.12).mix(RGB(r: 0.08, g: 0.04, b: 0.14), 0.12)
        }
        let bb = geo.bounds
        lightCenter = CGPoint(x: bb.minX + bb.width * 0.32, y: bb.minY + bb.height * 0.22)
        lightRadius = Double(max(bb.width, bb.height)) * 1.0
    }

    private func pt(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: x * S, y: y * S) }
    private func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * S, y: p.y * S) }

    /// Farbe des Fells an einer Stelle – gleiche Formel wie der Körperverlauf.
    func shade(at p: CGPoint) -> RGB {
        let dx = p.x - lightCenter.x, dy = p.y - lightCenter.y
        let t = min(1, sqrt(dx * dx + dy * dy) / lightRadius)
        if t < 0.42 { return light.mix(base, t / 0.42) }
        return base.mix(dark, (t - 0.42) / 0.58)
    }

    // MARK: Körper

    func drawBody(in ctx: inout GraphicsContext) {
        var rng = SeededRandom(string: seed)
        let body = Path(geo.path(size: S))
        let small = S < 44
        // Fell wächst bei großen Größen langsamer mit, damit es weich statt stachelig wirkt.
        let furLen = S <= 200 ? Double(S) * 0.04 : 8 + Double(S) * 0.03
        let bb = geo.bounds

        // 0) weicher, dunkler Hof hinter dem Körper (Silhouette verwischen)
        if !small {
            var halo = ctx
            halo.addFilter(.blur(radius: furLen * 0.45))
            halo.fill(body, with: .color(dark.opacity(0.55).color))
        }

        // 1) hinteres Fell
        drawFurRing(in: &ctx, rng: &rng, lengthRange: (0.55, 1.0), inset: 0.35, len: furLen,
                    spacing: small ? 1.6 : 1.1, darken: 0.08, lighten: 0, width: 0.55)

        // 2) Körper mit Verlauf (hell oben links, dunkel unten rechts)
        let gradient = Gradient(stops: [
            .init(color: light.color, location: 0),
            .init(color: base.color, location: 0.42),
            .init(color: dark.color, location: 1),
        ])
        ctx.fill(body, with: .radialGradient(gradient, center: pt(lightCenter), startRadius: 0,
                                             endRadius: CGFloat(lightRadius) * S))

        // 3) weiche Innenschattierung + Glanz
        ctx.drawLayer { layer in
            layer.clip(to: body)
            var shadow = layer
            shadow.addFilter(.blur(radius: S * 0.07))
            let occl = Path(ellipseIn: CGRect(x: (bb.minX + bb.width * 0.25) * S, y: (bb.maxY - bb.height * 0.22) * S,
                                              width: bb.width * 0.95 * S, height: bb.height * 0.45 * S))
            shadow.fill(occl, with: .color(dark.mix(.black, 0.25).opacity(0.38).color))
            var glow = layer
            glow.addFilter(.blur(radius: S * 0.06))
            let gl = Path(ellipseIn: CGRect(x: (bb.minX + bb.width * 0.12) * S, y: (bb.minY + bb.height * 0.06) * S,
                                            width: bb.width * 0.42 * S, height: bb.height * 0.26 * S))
            glow.fill(gl, with: .color(Color.white.opacity(base.luminance > 0.82 ? 0.5 : 0.22)))
        }

        // 4) vorderes Fell über der Kante (helle Spitzen)
        drawFurRing(in: &ctx, rng: &rng, lengthRange: (0.3, 0.7), inset: 0.8, len: furLen,
                    spacing: small ? 1.9 : 1.0, darken: 0, lighten: 0.05, width: 0.62)

        if !small {
            // ein paar längere Büschel für den Plüsch-Look
            drawFurRing(in: &ctx, rng: &rng, lengthRange: (0.65, 1.05), inset: 0.6, len: furLen,
                        spacing: 5, darken: 0, lighten: 0.06, width: 0.6)
        }

        // 5) Fellstruktur (kurze Härchen entlang eines Fließfelds), auch über den Rand hinaus
        if !small {
            let count = Int(min(S * S * 0.028, 60_000))
            let c = geo.faceCenter
            let hairWidth = max(0.6, min(Double(S) * 0.006, 2.4))
            for _ in 0..<count {
                let u = CGPoint(x: rng.range(bb.minX, bb.maxX), y: rng.range(bb.minY, bb.maxY))
                guard body.contains(pt(u)) else { continue }
                var dx = u.x - c.x, dy = u.y - c.y + 0.12
                let l = max(0.001, sqrt(dx * dx + dy * dy)); dx /= l; dy /= l
                let ang = atan2(dy, dx) + rng.range(-0.5, 0.5)
                let len = furLen * rng.range(0.35, 0.7)
                let start = pt(u)
                let end = CGPoint(x: start.x + cos(ang) * len, y: start.y + sin(ang) * len)
                var hair = Path()
                hair.move(to: start); hair.addLine(to: end)
                let sh = shade(at: u)
                let tone = rng.unit() < 0.5 ? sh.mix(.white, 0.22) : sh.mix(dark.mix(.black, 0.3), 0.35)
                ctx.stroke(hair, with: .color(tone.opacity(0.3).color),
                           style: StrokeStyle(lineWidth: hairWidth, lineCap: .round))
            }
            // Härchen über dem Fellrand, damit kein glatter Saum entsteht
            let pts = geo.points, normals = geo.normals
            let edgeCount = Int(Double(pts.count) * Double(S) * 0.045)
            for _ in 0..<edgeCount {
                let i = Int(rng.unit() * Double(pts.count)) % pts.count
                let n = normals[i]
                let out = rng.range(-1.6, 0.35) * furLen
                let start = CGPoint(x: pts[i].x * S + n.x * out, y: pts[i].y * S + n.y * out)
                let ang = atan2(n.y, n.x) + rng.range(-0.6, 0.6)
                let len = furLen * rng.range(0.3, 0.65)
                var hair = Path()
                hair.move(to: start)
                hair.addLine(to: CGPoint(x: start.x + cos(ang) * len, y: start.y + sin(ang) * len))
                let sh = shade(at: pts[i])
                let tone = rng.unit() < 0.5 ? sh.mix(.white, 0.22) : sh.mix(dark.mix(.black, 0.3), 0.35)
                ctx.stroke(hair, with: .color(tone.opacity(0.32).color),
                           style: StrokeStyle(lineWidth: hairWidth, lineCap: .round))
            }
        }
    }

    /// Ring aus kurzen, spitz zulaufenden Fellbüscheln entlang des Umrisses.
    private func drawFurRing(in ctx: inout GraphicsContext, rng: inout SeededRandom, lengthRange: (Double, Double),
                             inset: Double, len: Double, spacing: Double, darken: Double, lighten: Double, width: Double) {
        let pts = geo.points, normals = geo.normals
        let n = pts.count
        // Umfang in Punkten
        var perimeter = 0.0
        for i in 0..<n {
            let a = pts[i], b = pts[(i + 1) % n]
            perimeter += hypot(a.x - b.x, a.y - b.y) * S
        }
        let strandSpacing = min(2.0, max(1.0, Double(S) * 0.0085)) * spacing
        let strands = max(24, Int(perimeter / strandSpacing))
        let offset = rng.unit()
        for k in 0..<strands {
            let f = (Double(k) + offset + rng.range(-0.3, 0.3)) / Double(strands)
            let idxF = f * Double(n)
            let i0 = (Int(floor(idxF)) % n + n) % n
            let i1 = (i0 + 1) % n
            let t = idxF - floor(idxF)
            let p = CGPoint(x: pts[i0].x + (pts[i1].x - pts[i0].x) * t, y: pts[i0].y + (pts[i1].y - pts[i0].y) * t)
            var nx = normals[i0].x + (normals[i1].x - normals[i0].x) * t
            var ny = normals[i0].y + (normals[i1].y - normals[i0].y) * t
            let nl = max(1e-6, hypot(nx, ny)); nx /= nl; ny /= nl
            // Fell fällt leicht nach unten
            let jitter = rng.range(-0.28, 0.28)
            let gravity = 0.18 * nx * (ny < 0.6 ? 1 : 0)
            let ang = atan2(ny, nx) + jitter + gravity
            let L = len * rng.range(lengthRange.0, lengthRange.1)
            let base = CGPoint(x: p.x * S - nx * L * inset, y: p.y * S - ny * L * inset)
            let tip = CGPoint(x: base.x + cos(ang) * L * (1 + inset), y: base.y + sin(ang) * L * (1 + inset))
            let w = min(L * width, 1.6 + Double(S) * 0.008)
            let px = -sin(ang), py = cos(ang)
            let curl = rng.range(-0.3, 0.3) * L
            var blade = Path()
            blade.move(to: CGPoint(x: base.x + px * w / 2, y: base.y + py * w / 2))
            blade.addQuadCurve(to: CGPoint(x: tip.x + px * curl, y: tip.y + py * curl),
                               control: CGPoint(x: base.x + (tip.x - base.x) * 0.55 + px * w * 0.45,
                                                y: base.y + (tip.y - base.y) * 0.55 + py * w * 0.45))
            blade.addQuadCurve(to: CGPoint(x: base.x - px * w / 2, y: base.y - py * w / 2),
                               control: CGPoint(x: base.x + (tip.x - base.x) * 0.55 - px * w * 0.45,
                                                y: base.y + (tip.y - base.y) * 0.55 - py * w * 0.45))
            blade.closeSubpath()
            var c = shade(at: p)
            if darken > 0 { c = c.mix(dark.mix(.black, 0.35), darken * rng.range(0.6, 1.4)) }
            if lighten > 0 { c = c.mix(.white, lighten * rng.range(0.5, 2)) }
            ctx.fill(blade, with: .color(c.color))
        }
    }

    // MARK: Gesicht

    func drawFace(in ctx: inout GraphicsContext, blink: Double, working: Bool, mouthOpen: Double? = nil, gaze: Double? = nil) {
        if mascot.hasModernEyes && !iconFace {
            drawModernFace(in: &ctx, blink: blink, working: working, mouthOpen: mouthOpen, gaze: gaze ?? mascot.gazeValue)
            return
        }
        let small = S < 44
        let fc = geo.faceCenter
        let (spacing, er, eyeY) = eyeLayout
        let ink = RGB(hex: "#1A1320")

        // Bäckchen
        if S >= 30 && !iconFace && mascot.showsCheeks {
            var cheeks = ctx
            cheeks.addFilter(.blur(radius: S * 0.018))
            let pink = RGB(hex: "#FF6F96").mix(base, 0.15)
            for side in [-1.0, 1.0] {
                let c = pt(fc.x + side * (spacing + 0.062), eyeY + 0.062)
                cheeks.fill(Path(ellipseIn: CGRect(x: c.x - S * 0.05, y: c.y - S * 0.027, width: S * 0.1, height: S * 0.054)),
                            with: .color(pink.opacity(0.55).color))
            }
        }

        // Augen
        let lookDown = working ? 0.012 : 0
        for side in [-1.0, 1.0] {
            let c = pt(fc.x + side * spacing, eyeY + lookDown)
            if iconFace {
                // App-Symbol (Grok-Stil): große Augen, das rechte (weiter entfernte) etwas schmaler → Blick nach rechts oben
                drawEye(in: &ctx, center: c, r: er * S * Self.iconEyeScale * (side > 0 ? 0.93 : 1), blink: blink, side: side, ink: ink,
                        squeeze: side > 0 ? Self.iconFarEyeSqueeze : 1)
            } else {
                drawEye(in: &ctx, center: c, r: er * S, blink: blink, side: side, ink: ink)
            }
        }

        // Mund
        if !small && !(iconFace && Self.iconHidesMouth) {
            let m = pt(fc.x, eyeY + 0.07 + (iconFace ? Self.iconMouthDrop : 0))
            if let open = mouthOpen {
                // Sprechen: ovaler Mund, Höhe folgt der Silbenbewegung
                let w = S * 0.046, h = S * (0.012 + 0.04 * open)
                ctx.fill(Path(ellipseIn: CGRect(x: m.x - w / 2, y: m.y - S * 0.006, width: w, height: h)),
                         with: .color(ink.mix(RGB(hex: "#5A1E2E"), 0.45).color))
            } else if working {
                let w = S * 0.03, h = S * 0.026
                ctx.fill(Path(ellipseIn: CGRect(x: m.x - w / 2, y: m.y - h / 2 + S * 0.004, width: w, height: h)),
                         with: .color(ink.mix(RGB(hex: "#5A1E2E"), 0.4).color))
            } else if mascot.mouthStyle != "smile" {
                drawRestingMouth(in: &ctx, at: m, gaze: 0, ink: ink, width: max(1, S * 0.014))
            } else {
                var mouth = Path()
                let w = S * 0.034
                mouth.move(to: CGPoint(x: m.x - w, y: m.y - S * 0.004))
                mouth.addQuadCurve(to: CGPoint(x: m.x + w, y: m.y - S * 0.004), control: CGPoint(x: m.x, y: m.y + S * 0.032))
                ctx.stroke(mouth, with: .color(ink.color), style: StrokeStyle(lineWidth: max(1, S * 0.014), lineCap: .round))
            }
        }
    }

    // MARK: Neue Augen (v1.31, Key-Visual-Stil)

    /// Lidstellung und Brauen eines Auges. Anteile beziehen sich auf die Augenhöhe bzw. den Augenradius.
    private struct EyePose {
        var lid: Double          // vom Oberlid verdeckter Anteil (Mitte), 0 = ganz offen
        var slant: Double        // Lid außen tiefer (+) bzw. höher (−)
        var lidArch: Double      // Wölbung des Oberlids (klein = gerade, „schwer“)
        var lower: Double        // Unterlid hebt sich (verengt)
        var browLift: Double     // Braue höher (+) bzw. tiefer (−)
        var browArch: Double     // Wölbung der Braue
        var browTilt: Double     // innen tiefer (+, entschlossen) bzw. höher (−, fragend)
        var browWeight: Double   // Dicke der Braue (Anteil des Augenradius)
        var lashes: Bool = false // Lidstrich mit Schwung und Wimpern am äußeren Winkel
    }

    /// Fünf klar verschiedene Stile (2026-11, Vorbild Key Visual): nur Wimpern und Katzenaugen haben Wimpern.
    private func eyePose(side: Double, gaze: Double) -> EyePose {
        switch mascot.drawnEyes {
        case "lashes": // Herz: waagerecht, weit offen, Schwung und Wimpern außen, feine hohe Brauen
            return EyePose(lid: 0.1, slant: 0, lidArch: 0.24, lower: 0, browLift: 0.32, browArch: 0.5, browTilt: -0.08,
                           browWeight: 0.26, lashes: true)
        case "cat": // Creme: mandelförmig, außen hochgezogen (eigene Form in `drawCatEye`)
            return EyePose(lid: 0, slant: 0, lidArch: 0, lower: 0, browLift: 0.3, browArch: 0.45, browTilt: 0.0,
                           browWeight: 0.26, lashes: true)
        case "focused": // Violett: offen, aber gerades, leicht gesenktes Lid, Unterlid hebt sich; kräftige, gerade Brauen tief
            return EyePose(lid: 0.24, slant: -0.03, lidArch: 0.07, lower: 0.12, browLift: -0.12, browArch: 0.03, browTilt: 0.2,
                           browWeight: 0.5)
        case "dashes": // Stern, Dreieck: nur Striche, feine Bögen darüber
            return EyePose(lid: 0, slant: 0, lidArch: 0, lower: 0, browLift: 0, browArch: 0.4, browTilt: 0, browWeight: 0.3)
        default: // relaxed, Gelb/Koralle: Oberlid hängt bis über die Pupillenmitte, fast gerade; gerade Brauen mit Abstand
            return EyePose(lid: 0.5, slant: 0.05, lidArch: 0.03, lower: 0, browLift: 0.62, browArch: 0.06, browTilt: -0.04,
                           browWeight: 0.4)
        }
    }

    /// Augenmaße der neuen Augen (Punkte): Halbachsen der Augenform
    private func modernEyeRadii(_ r: CGFloat) -> (rx: CGFloat, ry: CGFloat) {
        S < 44 ? (r * 1.5, r * 1.4) : (r * 1.6, r * 1.45)
    }
    private func drawModernFace(in ctx: inout GraphicsContext, blink: Double, working: Bool, mouthOpen: Double?, gaze rawGaze: Double) {
        let small = S < 44
        let fc = geo.faceCenter
        let (spacing, er, eyeY) = eyeLayout
        let ink = RGB(hex: "#1A1320")
        let gaze = working ? rawGaze * 0.35 : rawGaze

        if S >= 30 && mascot.showsCheeks {
            var cheeks = ctx
            cheeks.addFilter(.blur(radius: S * 0.018))
            let pink = RGB(hex: "#FF6F96").mix(base, 0.15)
            for side in [-1.0, 1.0] {
                let c = pt(fc.x + side * (spacing + 0.066), eyeY + 0.07)
                cheeks.fill(Path(ellipseIn: CGRect(x: c.x - S * 0.05, y: c.y - S * 0.027, width: S * 0.1, height: S * 0.054)),
                            with: .color(pink.opacity(0.5).color))
            }
        }

        for side in [-1.0, 1.0] {
            let c = pt(fc.x + side * spacing, eyeY)
            drawModernEye(in: &ctx, center: c, r: er * S, side: side, pose: eyePose(side: side, gaze: rawGaze),
                          gaze: gaze, blink: blink, lookDown: working, ink: ink)
        }

        if !small {
            let m = pt(fc.x + gaze * 0.008, eyeY + 0.108)
            if let open = mouthOpen {
                let w = S * 0.042, h = S * (0.01 + 0.036 * open)
                ctx.fill(Path(ellipseIn: CGRect(x: m.x - w / 2, y: m.y - S * 0.006, width: w, height: h)),
                         with: .color(ink.mix(RGB(hex: "#5A1E2E"), 0.45).color))
            } else if working {
                // konzentriert: kurzer, gerader Mund
                var p = Path()
                p.move(to: CGPoint(x: m.x - S * 0.018, y: m.y + S * 0.004))
                p.addLine(to: CGPoint(x: m.x + S * 0.018, y: m.y + S * 0.002))
                ctx.stroke(p, with: .color(ink.color), style: StrokeStyle(lineWidth: max(1, S * 0.011), lineCap: .round))
            } else {
                drawRestingMouth(in: &ctx, at: m, gaze: gaze, ink: ink, width: max(1, S * 0.0115))
            }
        }
    }

    /// Ruhender Mund: schief (Mundwinkel zur Blickseite hoch), dezentes Lächeln oder neutral.
    private func drawRestingMouth(in ctx: inout GraphicsContext, at m: CGPoint, gaze: Double, ink: RGB, width: CGFloat) {
        var p = Path()
        let d: CGFloat = gaze < -0.05 ? -1 : 1
        switch mascot.mouthStyle {
        case "neutral":
            let w = S * 0.022
            p.move(to: CGPoint(x: m.x - w, y: m.y + S * 0.004))
            p.addLine(to: CGPoint(x: m.x + w, y: m.y + S * 0.001))
        case "smirk":
            let w = S * 0.03
            p.move(to: CGPoint(x: m.x - d * w * 0.95, y: m.y - S * 0.001))
            p.addQuadCurve(to: CGPoint(x: m.x + d * w * 1.05, y: m.y - S * 0.013),
                           control: CGPoint(x: m.x + d * w * 0.15, y: m.y + S * 0.021))
        default: // dezentes Lächeln
            let w = S * 0.03
            p.move(to: CGPoint(x: m.x - w, y: m.y - S * 0.006))
            p.addQuadCurve(to: CGPoint(x: m.x + w, y: m.y - S * 0.006), control: CGPoint(x: m.x, y: m.y + S * 0.022))
        }
        ctx.stroke(p, with: .color(ink.color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    private func drawModernEye(in ctx: inout GraphicsContext, center c: CGPoint, r: CGFloat, side: Double, pose: EyePose,
                               gaze: Double, blink: Double, lookDown: Bool, ink: RGB) {
        switch mascot.drawnEyes {
        case "dashes":
            drawDashEye(in: &ctx, center: c, r: r, side: side, pose: pose, blink: blink, lookDown: lookDown, ink: ink)
            return
        case "cat":
            drawCatEye(in: &ctx, center: c, r: r, side: side, pose: pose, gaze: gaze, blink: blink, lookDown: lookDown, ink: ink)
            return
        default:
            break
        }
        let small = S < 44
        let (rx, ry) = modernEyeRadii(r)
        let outer = CGFloat(side)   // +1: äußerer Augenwinkel rechts
        let lw = max(small ? 1.0 : 1.2, r * (pose.lashes ? 0.4 : 0.36))
        // Lid schließt beim Blinzeln ganz
        let lid = CGFloat(pose.lid + (1 - pose.lid) * (1 - max(0, min(1, blink))))
        let h = ry * 2
        let lidMid = c.y - ry + h * lid
        let xIn = c.x - outer * rx * 1.04, xOut = c.x + outer * rx * 1.06
        let yIn = lidMid + h * 0.15 - h * CGFloat(pose.slant) * 0.5
        let yOut = lidMid + h * 0.15 + h * CGFloat(pose.slant)
        let lidCtl = CGPoint(x: c.x + outer * rx * 0.08, y: lidMid - h * CGFloat(max(pose.lidArch, 0.02)))
        var lidLine = Path()
        lidLine.move(to: CGPoint(x: xIn, y: yIn))
        lidLine.addQuadCurve(to: CGPoint(x: xOut, y: yOut), control: lidCtl)

        if lid < 0.97 {
            let eyeShape = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry, width: rx * 2, height: ry * 2))
            // sichtbarer Bereich: unter dem Oberlid, über dem (evtl. gehobenen) Unterlid
            var open = lidLine
            open.addLine(to: CGPoint(x: xOut, y: c.y + ry * 3))
            open.addLine(to: CGPoint(x: xIn, y: c.y + ry * 3))
            open.closeSubpath()
            var layer = ctx
            layer.clip(to: eyeShape)
            layer.clip(to: open)
            if pose.lower > 0 {
                let low = c.y + ry - h * CGFloat(pose.lower)
                var under = Path()
                under.move(to: CGPoint(x: c.x - rx * 1.2, y: c.y - ry * 3))
                under.addLine(to: CGPoint(x: c.x + rx * 1.2, y: c.y - ry * 3))
                under.addLine(to: CGPoint(x: c.x + rx * 1.2, y: low + ry * 0.12))
                under.addQuadCurve(to: CGPoint(x: c.x - rx * 1.2, y: low + ry * 0.12), control: CGPoint(x: c.x, y: low - ry * 0.1))
                under.closeSubpath()
                layer.clip(to: under)
            }
            // Halb geschlossen: Pupille sitzt tiefer und stößt oben ans Lid
            let drop: CGFloat = pose.lid >= 0.4 ? 0.3 : 0.12
            fillEyeball(in: &layer, center: c, rx: rx, ry: ry, lidY: lidMid, gaze: gaze, drop: drop, lookDown: lookDown,
                        glint: lid < 0.8, ink: ink)
            // feine Kontur unten (lesbar auch auf hellem Fell)
            if !small {
                layer.stroke(eyeShape, with: .color(ink.opacity(0.28).color), lineWidth: max(0.6, r * 0.09))
            }
        }

        // Oberlid: kräftige dunkle Linie, zur Mitte dicker; endet am Augenwinkel (ohne Schwung, außer bei Wimpern)
        ctx.stroke(lidLine, with: .color(ink.color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        if !small {
            Self.fillTapered(in: &ctx, from: CGPoint(x: xIn + outer * rx * 0.12, y: yIn - h * 0.03),
                             control: CGPoint(x: lidCtl.x, y: lidCtl.y - lw * 0.2),
                             to: CGPoint(x: xOut - outer * rx * 0.12, y: yOut - h * 0.03), width: lw * 0.9, color: ink.color)
        }
        if pose.lashes {
            // Lidstrich-Schwung am äußeren Winkel, waagerecht nach außen und leicht hoch, dazu zwei Wimpern
            let tip = CGPoint(x: xOut + outer * r * 0.62, y: yOut - r * 0.42)
            Self.fillTapered(in: &ctx, from: CGPoint(x: xOut - outer * rx * 0.25, y: yOut - lw * 0.3),
                             control: CGPoint(x: xOut + outer * r * 0.3, y: yOut - r * 0.02),
                             to: tip, width: lw * (small ? 0.75 : 0.6), color: ink.color)
            if S >= 30 {
                let count = small ? 1 : 2
                for k in 0..<count {
                    let f = CGFloat(small ? 0.8 : [0.62, 0.84][k])
                    let x = (1 - f) * (1 - f) * xIn + 2 * (1 - f) * f * lidCtl.x + f * f * xOut
                    let y = (1 - f) * (1 - f) * yIn + 2 * (1 - f) * f * lidCtl.y + f * f * yOut
                    let len = r * (0.42 + 0.08 * CGFloat(k))
                    var lash = Path()
                    lash.move(to: CGPoint(x: x, y: y - lw * 0.3))
                    lash.addQuadCurve(to: CGPoint(x: x + outer * len * 0.75, y: y - len),
                                      control: CGPoint(x: x + outer * len * 0.1, y: y - len * 0.7))
                    ctx.stroke(lash, with: .color(ink.color), style: StrokeStyle(lineWidth: max(0.8, lw * 0.42), lineCap: .round))
                }
            }
        }

        // Braue (Ernst auch klein: die kräftige gerade Braue ist sein Erkennungszeichen)
        let openLid = c.y - ry + h * CGFloat(pose.lid)
        drawBrow(in: &ctx, center: c, r: r, rx: rx, side: side, pose: pose, top: openLid, ink: ink)
    }

    /// Augapfel mit großer, dunkler Pupille zur Blickseite und Glanzpunkt; `ctx` ist bereits auf die Augenform geclippt.
    private func fillEyeball(in layer: inout GraphicsContext, center c: CGPoint, rx: CGFloat, ry: CGFloat, lidY: CGFloat,
                             gaze: Double, drop: CGFloat, lookDown: Bool, glint: Bool, ink: RGB) {
        let small = S < 44
        let bounds = CGRect(x: c.x - rx * 1.3, y: c.y - ry * 1.3, width: rx * 2.6, height: ry * 2.6)
        layer.fill(Path(bounds), with: .linearGradient(Gradient(stops: [
            .init(color: RGB(hex: "#D9D2DA").color, location: 0),
            .init(color: RGB(hex: "#FBF9F6").color, location: 0.55),
            .init(color: RGB(hex: "#EEE9EC").color, location: 1),
        ]), startPoint: CGPoint(x: c.x, y: lidY), endPoint: CGPoint(x: c.x, y: c.y + ry)))
        let pr = ry * (small ? 0.8 : 0.72)
        let travel = max(0, rx - pr * 0.92)
        let pc = CGPoint(x: c.x + CGFloat(gaze) * travel, y: c.y + ry * (lookDown ? max(0.3, drop) : drop))
        let pupil = Path(ellipseIn: CGRect(x: pc.x - pr, y: pc.y - pr, width: pr * 2, height: pr * 2))
        layer.fill(pupil, with: .radialGradient(Gradient(colors: [RGB(hex: "#3A2C44").color, ink.color]),
                                                center: CGPoint(x: pc.x - pr * 0.2, y: pc.y + pr * 0.35),
                                                startRadius: 0, endRadius: pr * 1.1))
        // Glanzpunkt oben links in der Pupille, immer unter dem Lid sichtbar
        let gr = max(small ? 0.55 : 0.8, pr * 0.28)
        let gy = max(pc.y - pr * 0.38, lidY + gr * 1.3)
        if glint && gy + gr < c.y + ry {
            layer.fill(Path(ellipseIn: CGRect(x: pc.x - pr * 0.36 - gr, y: gy - gr, width: gr * 2, height: gr * 2)),
                       with: .color(.white.opacity(0.95)))
        }
    }

    /// Katzenaugen: mandelförmig, äußerer Winkel deutlich höher, kräftiger Lidstrich mit langem Schwung, Wimpern.
    private func drawCatEye(in ctx: inout GraphicsContext, center c: CGPoint, r: CGFloat, side: Double, pose: EyePose,
                            gaze: Double, blink: Double, lookDown: Bool, ink: RGB) {
        let small = S < 44
        let (rx0, ry0) = modernEyeRadii(r)
        let rx = rx0 * 1.06, ry = ry0 * 1.0
        let outer = CGFloat(side)
        let lw = max(small ? 1.1 : 1.3, r * 0.42)
        let close = CGFloat(1 - max(0, min(1, blink)))
        let pIn = CGPoint(x: c.x - outer * rx * 1.0, y: c.y + ry * 0.3)
        let pOut = CGPoint(x: c.x + outer * rx * 1.04, y: c.y - ry * 0.42)
        let lowCtl = CGPoint(x: c.x + outer * rx * 0.05, y: c.y + ry * 1.12)
        let upOpen = CGPoint(x: c.x - outer * rx * 0.2, y: c.y - ry * 1.42)
        // Blinzeln: Oberlid legt sich auf das Unterlid
        let upCtl = CGPoint(x: upOpen.x + (lowCtl.x - upOpen.x) * close * 0.92, y: upOpen.y + (lowCtl.y - upOpen.y) * close * 0.92)
        var upper = Path()
        upper.move(to: pIn)
        upper.addQuadCurve(to: pOut, control: upCtl)
        var almond = upper
        almond.addQuadCurve(to: pIn, control: lowCtl)
        almond.closeSubpath()

        if close < 0.85 {
            var layer = ctx
            layer.clip(to: almond)
            let top = 0.25 * pIn.y + 0.5 * upCtl.y + 0.25 * pOut.y
            fillEyeball(in: &layer, center: CGPoint(x: c.x, y: c.y + ry * 0.04), rx: rx * 0.86, ry: ry, lidY: top,
                        gaze: gaze, drop: 0.08, lookDown: lookDown, glint: close < 0.5, ink: ink)
        }
        // Unterlid fein, Oberlid kräftig
        var lower = Path()
        lower.move(to: pOut)
        lower.addQuadCurve(to: pIn, control: lowCtl)
        if !small {
            ctx.stroke(lower, with: .color(ink.opacity(0.55).color), style: StrokeStyle(lineWidth: max(0.7, r * 0.12), lineCap: .round))
        }
        ctx.stroke(upper, with: .color(ink.color), style: StrokeStyle(lineWidth: lw, lineCap: .round, lineJoin: .round))
        // langer Lidstrich-Schwung schräg nach außen oben
        let tip = CGPoint(x: pOut.x + outer * r * 0.9, y: pOut.y - r * 0.62)
        Self.fillTapered(in: &ctx, from: CGPoint(x: pOut.x - outer * rx * 0.55, y: pOut.y - ry * 0.05),
                         control: CGPoint(x: pOut.x + outer * r * 0.2, y: pOut.y - r * 0.12),
                         to: tip, width: lw * (small ? 0.8 : 0.7), color: ink.color)
        if S >= 44 {
            for (f, len) in [(0.5, 0.38), (0.72, 0.44)] as [(CGFloat, CGFloat)] {
                let x = (1 - f) * (1 - f) * pIn.x + 2 * (1 - f) * f * upCtl.x + f * f * pOut.x
                let y = (1 - f) * (1 - f) * pIn.y + 2 * (1 - f) * f * upCtl.y + f * f * pOut.y
                var lash = Path()
                lash.move(to: CGPoint(x: x, y: y - lw * 0.3))
                lash.addQuadCurve(to: CGPoint(x: x + outer * r * len * 0.8, y: y - r * len),
                                  control: CGPoint(x: x + outer * r * len * 0.1, y: y - r * len * 0.7))
                ctx.stroke(lash, with: .color(ink.color), style: StrokeStyle(lineWidth: max(0.8, lw * 0.4), lineCap: .round))
            }
        }
        drawBrow(in: &ctx, center: c, r: r, rx: rx, side: side, pose: pose, top: c.y - ry * 0.95, ink: ink)
    }

    /// Zwei kurze, senkrechte, abgerundete Striche ohne Lid und Wimpern (Blick immer geradeaus).
    private func drawDashEye(in ctx: inout GraphicsContext, center c: CGPoint, r: CGFloat, side: Double, pose: EyePose,
                             blink: Double, lookDown: Bool, ink: RGB) {
        let small = S < 44
        let w = max(small ? 2.0 : 2.4, r * (small ? 0.95 : 0.9))
        let fullH = r * (small ? 2.5 : 2.75)
        let h = max(w, fullH * CGFloat(max(0.12, min(1, blink))))
        let cy = c.y + (lookDown ? r * 0.15 : 0) - r * 0.05
        let rect = CGRect(x: c.x - w / 2, y: cy - h / 2, width: w, height: h)
        let bar = Path(roundedRect: rect, cornerRadius: w / 2, style: .continuous)
        ctx.fill(bar, with: .linearGradient(Gradient(colors: [RGB(hex: "#3E3048").color, ink.color]),
                                            startPoint: CGPoint(x: c.x, y: rect.minY), endPoint: CGPoint(x: c.x, y: rect.maxY)))
        if !small && h > fullH * 0.6 {
            // dezenter Glanz oben (wie die glatten Knopfaugen im Key Visual)
            let gw = w * 0.32, gh = h * 0.2
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - w * 0.22 - gw / 2, y: rect.minY + h * 0.1, width: gw, height: gh)),
                     with: .color(.white.opacity(0.5)))
        }
        drawBrow(in: &ctx, center: c, r: r, rx: r * 1.15, side: side, pose: pose, top: cy - fullH / 2 - r * 0.15, ink: ink)
    }

    /// Braue knapp über `top` (Oberkante des offenen Auges). Klein (Seitenleiste) weggelassen, außer beim ernsten Blick.
    private func drawBrow(in ctx: inout GraphicsContext, center c: CGPoint, r: CGFloat, rx: CGFloat, side: Double,
                          pose: EyePose, top: CGFloat, ink: RGB) {
        let small = S < 44
        let serious = mascot.drawnEyes == "focused"
        guard !small || (serious && S >= 26) else { return }
        let outer = CGFloat(side)
        let bw = rx * (serious ? 1.0 : 0.92)
        let by = top - r * 0.82 - r * CGFloat(pose.browLift) * 0.8
        let bxIn = c.x - outer * bw * 0.92, bxOut = c.x + outer * bw * 1.05
        let byIn = by + r * CGFloat(pose.browTilt), byOut = by - r * CGFloat(pose.browTilt) * 0.4
        let browWidth = max(small ? 1.3 : 1.2, r * CGFloat(pose.browWeight))
        Self.fillTapered(in: &ctx, from: CGPoint(x: bxIn, y: byIn),
                         control: CGPoint(x: c.x + outer * bw * 0.12, y: min(byIn, byOut) - r * CGFloat(pose.browArch)),
                         to: CGPoint(x: bxOut, y: byOut), width: browWidth, color: ink.opacity(0.92).color)
    }
    /// Spitz zulaufender Strich (Braue): in der Mitte `width` dick, an den Enden schmal und rund.
    static func fillTapered(in ctx: inout GraphicsContext, from a: CGPoint, control c: CGPoint, to b: CGPoint,
                            width: CGFloat, color: Color) {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = max(0.001, hypot(dx, dy))
        let n = CGPoint(x: -dy / len * width, y: dx / len * width)
        var p = Path()
        p.move(to: a)
        p.addQuadCurve(to: b, control: CGPoint(x: c.x - n.x, y: c.y - n.y))
        p.addQuadCurve(to: a, control: CGPoint(x: c.x + n.x, y: c.y + n.y))
        p.closeSubpath()
        ctx.fill(p, with: .color(color))
        var spine = Path()
        spine.move(to: a)
        spine.addQuadCurve(to: b, control: c)
        ctx.stroke(spine, with: .color(color), style: StrokeStyle(lineWidth: width * 0.4, lineCap: .round))
    }

    /// Gesicht des App-Symbols (Form „icon_corner“)
    private var iconFace: Bool { mascot.shape == "icon_corner" }
    /// Klassischer Augenstil: Das App-Symbol behält seine Knopfaugen, sonst gilt die Zuordnung `drawnEyes`.
    private var classicEyes: String { iconFace ? mascot.eyes : mascot.drawnEyes }
    static let iconEyeScale: CGFloat = 1.42
    static let iconFarEyeSqueeze: CGFloat = 0.78
    static let iconMouthDrop: Double = 0.12
    static let iconHidesMouth = false

    private func drawEye(in ctx: inout GraphicsContext, center c: CGPoint, r: CGFloat, blink: Double, side: Double, ink: RGB,
                         squeeze: CGFloat = 1) {
        let lw = max(1.1, r * 0.48)
        switch classicEyes {
        case "happy":
            var p = Path()
            p.move(to: CGPoint(x: c.x - r * 1.05, y: c.y + r * 0.35))
            p.addQuadCurve(to: CGPoint(x: c.x + r * 1.05, y: c.y + r * 0.35), control: CGPoint(x: c.x, y: c.y - r * 1.25))
            ctx.stroke(p, with: .color(ink.color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            return
        case "sleepy":
            // geschlossene, entspannte Augen (‿) mit kleinen Wimpern
            var p = Path()
            p.move(to: CGPoint(x: c.x - r * 1.0, y: c.y - r * 0.15))
            p.addQuadCurve(to: CGPoint(x: c.x + r * 1.0, y: c.y - r * 0.15), control: CGPoint(x: c.x, y: c.y + r * 1.05))
            ctx.stroke(p, with: .color(ink.color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
            if S >= 60 {
                var lash = Path()
                let ox = c.x + side * r * 1.0, oy = c.y - r * 0.15
                lash.move(to: CGPoint(x: ox, y: oy))
                lash.addLine(to: CGPoint(x: ox + side * r * 0.35, y: oy - r * 0.32))
                ctx.stroke(lash, with: .color(ink.color), style: StrokeStyle(lineWidth: lw * 0.7, lineCap: .round))
            }
            return
        default:
            break
        }

        let open = max(0.08, blink)
        if open < 0.2 {
            var line = Path()
            line.move(to: CGPoint(x: c.x - r, y: c.y)); line.addLine(to: CGPoint(x: c.x + r, y: c.y))
            ctx.stroke(line, with: .color(ink.color), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
            return
        }

        var eye: Path
        var rx = r, ry = r
        switch classicEyes {
        case "ovals":
            rx = r * 0.78 * squeeze; ry = r * 1.22
            eye = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry * open, width: 2 * rx, height: 2 * ry * open))
        case "diamonds":
            rx = r * 1.1; ry = r * 1.2
            let h = ry * open
            eye = Path(roundedRect: CGRect(x: -rx * 0.72, y: -rx * 0.72, width: rx * 1.44, height: rx * 1.44), cornerRadius: rx * 0.32)
                .applying(CGAffineTransform(rotationAngle: .pi / 4))
                .applying(CGAffineTransform(scaleX: 1, y: h / ry))
                .offsetBy(dx: c.x, dy: c.y)
        case "sparkle":
            rx = r * 1.22; ry = r * 1.28
            eye = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry * open, width: 2 * rx, height: 2 * ry * open))
        default: // dots
            rx = r * 1.0 * squeeze; ry = r * 1.06
            eye = Path(ellipseIn: CGRect(x: c.x - rx, y: c.y - ry * open, width: 2 * rx, height: 2 * ry * open))
        }

        // glänzendes, dunkles Knopfauge
        let g = Gradient(colors: [RGB(hex: "#3E3048").color, ink.color])
        ctx.fill(eye, with: .linearGradient(g, startPoint: CGPoint(x: c.x, y: c.y + ry), endPoint: CGPoint(x: c.x, y: c.y - ry * 0.2)))
        guard open > 0.5 else { return }
        if classicEyes == "sparkle" {
            ctx.fill(Self.sparkle(center: CGPoint(x: c.x - rx * 0.28, y: c.y - ry * 0.3), radius: rx * 0.62), with: .color(.white))
            let d = rx * 0.2
            ctx.fill(Path(ellipseIn: CGRect(x: c.x + rx * 0.32 - d / 2, y: c.y + ry * 0.32 - d / 2, width: d, height: d)),
                     with: .color(.white.opacity(0.85)))
        } else {
            let h1 = max(1.0, min(rx, ry) * 0.62)
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - rx * 0.42 - h1 / 2, y: c.y - ry * 0.4 - h1 / 2, width: h1, height: h1)),
                     with: .color(.white.opacity(0.95)))
            if S >= 40 {
                let h2 = min(rx, ry) * 0.24
                ctx.fill(Path(ellipseIn: CGRect(x: c.x + rx * 0.3 - h2 / 2, y: c.y + ry * 0.36 - h2 / 2, width: h2, height: h2)),
                         with: .color(.white.opacity(0.7)))
            }
        }
    }

    /// Vierzackiger Funke.
    static func sparkle(center c: CGPoint, radius r: CGFloat) -> Path {
        var p = Path()
        let k = r * 0.28
        p.move(to: CGPoint(x: c.x, y: c.y - r))
        p.addQuadCurve(to: CGPoint(x: c.x + r, y: c.y), control: CGPoint(x: c.x + k, y: c.y - k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y + r), control: CGPoint(x: c.x + k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x - r, y: c.y), control: CGPoint(x: c.x - k, y: c.y + k))
        p.addQuadCurve(to: CGPoint(x: c.x, y: c.y - r), control: CGPoint(x: c.x - k, y: c.y - k))
        p.closeSubpath()
        return p
    }

    // MARK: Accessoires

    /// Kontrastfarbe für Mütze, Fliege usw. (Komplementärton, kräftig).
    private var accent: RGB {
        #if canImport(UIKit)
        let ui = UIColor(red: base.r, green: base.g, blue: base.b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        ui.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        #else
        let ns = NSColor(srgbRed: base.r, green: base.g, blue: base.b, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, v: CGFloat = 0, a: CGFloat = 0
        ns.getHue(&h, saturation: &s, brightness: &v, alpha: &a)
        #endif
        if s < 0.15 { return RGB(hex: "#E5484D") } // Weiß/Grau → Rot
        let nh = (h + 0.5).truncatingRemainder(dividingBy: 1)
        #if canImport(UIKit)
        let out = UIColor(hue: nh, saturation: 0.62, brightness: 0.88, alpha: 1)
        var r: CGFloat = 0, gg: CGFloat = 0, b: CGFloat = 0
        out.getRed(&r, green: &gg, blue: &b, alpha: &a)
        #else
        let out = NSColor(hue: nh, saturation: 0.62, brightness: 0.88, alpha: 1).usingColorSpace(.sRGB) ?? .red
        let r = out.redComponent, gg = out.greenComponent, b = out.blueComponent
        #endif
        return RGB(r: r, g: gg, b: b)
    }

    // MARK: Accessoire-Anker

    /// Wo ein Hut aufliegt: Mitte der Auflagelinie (Einheiten), Neigung der Kopflinie und Größe passend zur Kopfbreite.
    struct HatSeat {
        var x: Double
        var y: Double
        var angle: Double
        var scale: Double
    }

    /// Augenlage wie in `drawFace` (bei kleinen Größen weiter auseinander und größer).
    private var eyeLayout: (spacing: Double, radius: Double, y: Double) {
        let sizeBoost = S < 34 ? 1.3 : (S < 60 ? 1.12 : 1.0)
        // Neue Augen sind breiter und stehen etwas weiter auseinander
        let modern = mascot.hasModernEyes && !iconFace
        let dashes = modern && mascot.drawnEyes == "dashes"
        let spread = modern ? (dashes ? (S < 34 ? 1.06 : 1.08) : (S < 34 ? 1.14 : 1.25)) : 1.0
        let grow = modern ? (S < 34 ? 1.04 : 1.1) : 1.0
        return (geo.eyeSpacing * (S < 34 ? 1.12 : 1.06) * spread, 0.05 * geo.eyeScale * sizeBoost * grow, Double(geo.faceCenter.y) - 0.01)
    }

    /// Index des höchsten Umrisspunkts über `x` (nur obere Körperhälfte), nil wenn der Körper dort nicht ist.
    private func topIndex(atX x: Double) -> Int? {
        let limit = Double(geo.faceCenter.y)
        var best: Int? = nil
        var bestY = Double.infinity
        for (i, p) in geo.points.enumerated() {
            let py = Double(p.y)
            if py < limit, py < bestY, abs(Double(p.x) - x) < 0.012 { best = i; bestY = py }
        }
        return best
    }

    /// Auflage für einen Hut der Breite `w`: Median der Kopfoberkante unter der Krempe. Schmale Spitzen (Stern, Dreieck,
    /// Tropfen) werden so überdeckt, Kerben (Herz) überbrückt; nie tiefer als knapp über den Augen.
    func hatSeat(width w: Double) -> HatSeat {
        let fc = geo.faceCenter
        let cx = Double(fc.x)
        var tops: [Double] = [], left: [Double] = [], right: [Double] = []
        let n = 16
        for i in 0...n {
            let x = cx - w / 2 + w * Double(i) / Double(n)
            guard let k = topIndex(atX: x) else { continue }
            let y = Double(geo.points[k].y)
            tops.append(y)
            if i <= 5 { left.append(y) } else if i >= n - 5 { right.append(y) }
        }
        guard !tops.isEmpty else { return HatSeat(x: cx, y: Double(geo.headTop.y), angle: geo.tilt, scale: 1) }
        tops.sort()
        var y = min(tops[tops.count / 2], tops[0] + 0.085)
        y = min(y, Double(fc.y) - 0.21)
        var angle = geo.tilt
        if !left.isEmpty, !right.isEmpty {
            let l = left.reduce(0, +) / Double(left.count), r = right.reduce(0, +) / Double(right.count)
            angle = max(-0.2, min(0.2, atan2(r - l, w * 0.7) * 0.55))
        }
        let (sl, sr) = geo.span(atY: y + 0.08)
        let scale = max(0.8, min(1.15, Double(sr - sl) / 0.47))
        return HatSeat(x: cx, y: y, angle: angle, scale: scale)
    }

    /// Verkleinert hohe Hüte, damit die Spitze höchstens 0,05 über den Rahmen ragt (sonst schneidet der Bildcache ab).
    private func fitted(_ seat: HatSeat, sink: Double, height: Double) -> HatSeat {
        var s = seat
        let room = seat.y + sink + 0.05
        if height * s.scale > room { s.scale = max(0.55, room / height) }
        return s
    }

    /// Zeichenebene für Hüte: Ursprung auf der Auflage (um `sink` ins Fell abgesenkt), gedreht und skaliert.
    private func hatLayer(_ ctx: GraphicsContext, _ seat: HatSeat, sink: Double, extraAngle: Double = 0, dx: Double = 0) -> GraphicsContext {
        var l = ctx
        l.translateBy(x: CGFloat(seat.x + dx) * S, y: CGFloat(seat.y + sink) * S)
        l.rotate(by: .radians(seat.angle + extraAngle))
        l.scaleBy(x: seat.scale, y: seat.scale)
        return l
    }

    /// Punkt auf der Kopfoberkante über `x` und Richtung nach außen (Normale, mit `upBias` nach oben gezogen).
    private func headPoint(atX x: Double, upBias: Double) -> (p: CGPoint, angle: Double) {
        guard let i = topIndex(atX: x) else { return (CGPoint(x: x, y: geo.headTop.y), -.pi / 2) }
        let nrm = geo.normals[i]
        var dx = Double(nrm.x), dy = Double(nrm.y) - upBias
        let len = max(1e-6, hypot(dx, dy)); dx /= len; dy /= len
        return (geo.points[i], atan2(dy, dx))
    }

    /// Lokaler Punkt (Einheiten × Größe), für Zeichenebenen mit eigenem Ursprung.
    private func lp(_ x: Double, _ y: Double) -> CGPoint { CGPoint(x: CGFloat(x) * S, y: CGFloat(y) * S) }
    private func un(_ v: Double) -> CGFloat { CGFloat(v) * S }
    private func lrect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
        CGRect(x: un(x), y: un(y), width: un(w), height: un(h))
    }
    private func soft(_ c: RGB, light: Double = 0.25, dark: Double = 0.28) -> Gradient {
        Gradient(colors: [c.mix(.white, light).color, c.mix(.black, dark).color])
    }

    /// Bügel hinter dem Kopf: nur außerhalb des (leicht eingerückten) Umrisses sichtbar, liegt also auf dem Fell auf.
    private func strokeBehindHead(_ ctx: GraphicsContext, _ path: Path, color: RGB, width: CGFloat) {
        var behind = ctx
        behind.clip(to: Path(geo.path(size: S, inset: 0.035)), options: .inverse)
        behind.stroke(path, with: .color(color.color), style: StrokeStyle(lineWidth: width, lineCap: .round))
    }

    /// Seitenpunkte für Kopfhörer/Headset auf Augenhöhe (bei Sternen nicht an den Zackenspitzen).
    private func earSides(atY y: Double) -> (Double, Double) {
        var (l, r) = geo.span(atY: y)
        let clamp: Double? = ["star": 0.27, "star_soft": 0.25][mascot.shape]
        if let clamp {
            l = max(l, geo.faceCenter.x - clamp)
            r = min(r, geo.faceCenter.x + clamp)
        }
        return (Double(l), Double(r))
    }

    // MARK: Accessoires

    func drawAccessory(in ctx: inout GraphicsContext) {
        let fc = geo.faceCenter
        let cx = Double(fc.x)
        let ink = RGB(hex: "#22202A")
        let reddish = base.r > 0.75 && base.g < 0.5
        let detail = S >= 60   // Nähte, Rippen, Glanzpunkte erst ab mittlerer Größe
        switch mascot.accessory {

        // MARK: Kopf
        case "beret":
            // Flach und bauschig, leicht zur rechten Seite geneigt und dort etwas tiefer, kleiner Zipfel oben.
            let c = reddish ? RGB(hex: "#2E3A66") : RGB(hex: "#D63B4E")
            // Neuer Stil: größer und bauschiger, sitzt satt auf dem Kopf (Key Visual)
            let bold = mascot.hasModernEyes
            var beretSeat = hatSeat(width: bold ? 0.36 : 0.3)
            if bold { beretSeat.scale *= 1.34 }
            let sinkB = bold ? 0.085 : 0.05
            let seat = fitted(beretSeat, sink: sinkB, height: bold ? 0.24 : 0.21)
            var l = hatLayer(ctx, seat, sink: sinkB, extraAngle: 0.13, dx: 0.015)
            if bold { l.scaleBy(x: 1, y: 1.16) }
            // Band, liegt auf dem Kopf
            l.fill(Path(roundedRect: lrect(-0.15, -0.03, 0.3, 0.042), cornerRadius: un(0.021)), with: .color(c.mix(.black, 0.45).color))
            // weicher Teller, rechts weiter überstehend; Unterkante hängt leicht durch
            var puff = Path()
            puff.move(to: lp(-0.235, -0.07))
            puff.addCurve(to: lp(0.28, -0.058), control1: lp(-0.235, -0.19), control2: lp(0.25, -0.2))
            puff.addCurve(to: lp(-0.235, -0.07), control1: lp(0.25, 0.0), control2: lp(-0.205, 0.005))
            puff.closeSubpath()
            l.fill(puff, with: .linearGradient(Gradient(stops: [
                .init(color: c.mix(.white, 0.3).color, location: 0),
                .init(color: c.color, location: 0.5),
                .init(color: c.mix(.black, 0.3).color, location: 1),
            ]), startPoint: lp(-0.08, -0.17), endPoint: lp(0.04, -0.01)))
            if detail {
                var fold = Path()
                fold.move(to: lp(-0.2, -0.055))
                fold.addQuadCurve(to: lp(0.24, -0.045), control: lp(0.02, -0.005))
                l.stroke(fold, with: .color(c.mix(.black, 0.35).opacity(0.5).color), style: StrokeStyle(lineWidth: un(0.008), lineCap: .round))
                l.fill(Path(ellipseIn: lrect(-0.15, -0.15, 0.17, 0.04)), with: .color(.white.opacity(0.18)))
            }
            var stem = Path()
            stem.move(to: lp(0.01, -0.148))
            stem.addQuadCurve(to: lp(-0.006, -0.192), control: lp(0.022, -0.172))
            l.stroke(stem, with: .color(c.mix(.black, 0.3).color), style: StrokeStyle(lineWidth: max(1.2, un(0.024)), lineCap: .round))

        case "cap":
            let c = accent
            // Neuer Stil: größere, höhere Kappe, tiefer aufgesetzt
            let bold = mascot.hasModernEyes
            var capSeat = hatSeat(width: bold ? 0.36 : 0.3)
            if bold { capSeat.scale *= 1.3 }
            let sinkC = bold ? 0.085 : 0.06
            let seat = bold ? fitted(capSeat, sink: sinkC, height: 0.2) : capSeat
            let l = hatLayer(ctx, seat, sink: sinkC)
            let w = 0.34 * S, h = (bold ? 0.17 : 0.15) * S
            var dome = Path()
            dome.move(to: CGPoint(x: -w / 2, y: 0))
            dome.addCurve(to: CGPoint(x: w / 2, y: 0), control1: CGPoint(x: -w / 2, y: -h * 1.25), control2: CGPoint(x: w / 2, y: -h * 1.25))
            dome.closeSubpath()
            l.fill(dome, with: .linearGradient(Gradient(colors: [c.mix(.white, 0.25).color, c.mix(.black, 0.2).color]),
                                               startPoint: CGPoint(x: -w / 3, y: -h), endPoint: CGPoint(x: w / 3, y: 0)))
            let brim = Path(ellipseIn: CGRect(x: -w * 0.1, y: -h * 0.16, width: w * 0.85, height: h * 0.34))
            l.fill(brim, with: .color(c.mix(.black, 0.3).color))
            let button = S * 0.03
            l.fill(Path(ellipseIn: CGRect(x: -button / 2, y: -h * 0.94 - button / 2, width: button, height: button)),
                   with: .color(c.mix(.black, 0.25).color))
            var seam = Path()
            seam.move(to: CGPoint(x: 0, y: -h * 0.92)); seam.addQuadCurve(to: CGPoint(x: -w * 0.08, y: -h * 0.05), control: CGPoint(x: -w * 0.1, y: -h * 0.6))
            l.stroke(seam, with: .color(c.mix(.black, 0.3).opacity(0.6).color), lineWidth: max(0.6, S * 0.006))

        case "beanie":
            // Wollmütze mit Umschlag und Bommel, tiefer über den Kopf gezogen
            let c = accent
            let seat = fitted(hatSeat(width: 0.36), sink: 0.075, height: 0.27)
            let l = hatLayer(ctx, seat, sink: 0.075)
            var dome = Path()
            dome.move(to: lp(-0.19, -0.02))
            dome.addCurve(to: lp(0.19, -0.02), control1: lp(-0.19, -0.225), control2: lp(0.19, -0.225))
            dome.closeSubpath()
            l.fill(dome, with: .linearGradient(soft(c, light: 0.22, dark: 0.22), startPoint: lp(-0.12, -0.18), endPoint: lp(0.14, 0)))
            if detail {
                for k in [-2.0, -1.0, 0.0, 1.0, 2.0] {
                    var rib = Path()
                    rib.move(to: lp(k * 0.068, -0.035))
                    rib.addQuadCurve(to: lp(k * 0.03, -0.165), control: lp(k * 0.066, -0.12))
                    l.stroke(rib, with: .color(c.mix(.black, 0.35).opacity(0.35).color), lineWidth: max(0.6, un(0.007)))
                }
            }
            let cuff = Path(roundedRect: lrect(-0.205, -0.055, 0.41, 0.078), cornerRadius: un(0.036))
            l.fill(cuff, with: .linearGradient(soft(c.mix(.white, 0.08), light: 0.18, dark: 0.18), startPoint: lp(0, -0.055), endPoint: lp(0, 0.023)))
            if detail {
                var ribs = Path()
                for k in stride(from: -0.18, through: 0.18, by: 0.03) {
                    ribs.move(to: lp(k, -0.045)); ribs.addLine(to: lp(k, 0.013))
                }
                l.stroke(ribs, with: .color(c.mix(.black, 0.4).opacity(0.28).color), lineWidth: max(0.6, un(0.006)))
            }
            let pom = c.mix(.white, 0.55)
            for i in 0..<7 {
                let a = Double(i) / 7 * 2 * .pi
                l.fill(Path(ellipseIn: lrect(cos(a) * 0.03 - 0.028, -0.19 + sin(a) * 0.03 - 0.028, 0.056, 0.056)), with: .color(pom.mix(c, 0.12).color))
            }
            l.fill(Path(ellipseIn: lrect(-0.04, -0.235, 0.08, 0.08)),
                   with: .radialGradient(Gradient(colors: [pom.mix(.white, 0.4).color, pom.color]), center: lp(-0.015, -0.21),
                                         startRadius: 0, endRadius: un(0.05)))

        case "tophat":
            let felt = RGB(hex: "#2B2833")
            let seat = fitted(hatSeat(width: 0.3), sink: 0.04, height: 0.3)
            let l = hatLayer(ctx, seat, sink: 0.04, extraAngle: 0.09, dx: 0.01)
            l.fill(Path(ellipseIn: lrect(-0.205, -0.042, 0.41, 0.07)),
                   with: .linearGradient(soft(felt, light: 0.3, dark: 0.3), startPoint: lp(0, -0.042), endPoint: lp(0, 0.028)))
            var crown = Path()
            crown.move(to: lp(-0.118, -0.01))
            crown.addLine(to: lp(-0.132, -0.25))
            crown.addLine(to: lp(0.132, -0.25))
            crown.addLine(to: lp(0.118, -0.01))
            crown.closeSubpath()
            l.fill(crown, with: .linearGradient(Gradient(colors: [felt.mix(.white, 0.24).color, felt.color, felt.mix(.black, 0.4).color]),
                                                startPoint: lp(-0.13, 0), endPoint: lp(0.13, 0)))
            var band = Path()
            band.move(to: lp(-0.122, -0.078)); band.addLine(to: lp(0.122, -0.078))
            band.addLine(to: lp(0.119, -0.03)); band.addLine(to: lp(-0.119, -0.03)); band.closeSubpath()
            l.fill(band, with: .linearGradient(soft(accent, light: 0.15, dark: 0.25), startPoint: lp(0, -0.078), endPoint: lp(0, -0.03)))
            l.fill(Path(ellipseIn: lrect(-0.132, -0.27, 0.264, 0.04)), with: .color(felt.mix(.white, 0.3).color))
            if detail {
                l.fill(Path(roundedRect: lrect(-0.1, -0.235, 0.022, 0.14), cornerRadius: un(0.011)), with: .color(.white.opacity(0.13)))
            }

        case "cowboy":
            let c = (base.r > 0.55 && base.g > 0.3 && base.g < 0.78 && base.b < 0.45) ? RGB(hex: "#4A3F4E") : RGB(hex: "#C68B52")
            let seat = fitted(hatSeat(width: 0.34), sink: 0.045, height: 0.22)
            let l = hatLayer(ctx, seat, sink: 0.045, extraAngle: 0.07)
            var crown = Path()
            crown.move(to: lp(-0.115, -0.02))
            crown.addLine(to: lp(-0.108, -0.15))
            crown.addQuadCurve(to: lp(0, -0.168), control: lp(-0.06, -0.212))
            crown.addQuadCurve(to: lp(0.108, -0.15), control: lp(0.06, -0.212))
            crown.addLine(to: lp(0.115, -0.02))
            crown.closeSubpath()
            l.fill(crown, with: .linearGradient(soft(c, light: 0.22, dark: 0.25), startPoint: lp(-0.12, -0.18), endPoint: lp(0.12, 0)))
            l.fill(Path(lrect(-0.113, -0.066, 0.226, 0.032)), with: .color(c.mix(.black, 0.5).color))
            var brim = Path()
            brim.move(to: lp(-0.27, -0.078))
            brim.addQuadCurve(to: lp(0.27, -0.078), control: lp(0, 0.085))
            brim.addQuadCurve(to: lp(-0.27, -0.078), control: lp(0, -0.005))
            brim.closeSubpath()
            l.fill(brim, with: .linearGradient(soft(c, light: 0.15, dark: 0.3), startPoint: lp(0, -0.05), endPoint: lp(0, 0.04)))

        case "partyhat":
            let c = accent
            let seat = fitted(hatSeat(width: 0.22), sink: 0.035, height: 0.32)
            let l = hatLayer(ctx, seat, sink: 0.035, extraAngle: 0.2, dx: 0.02)
            var cone = Path()
            cone.move(to: lp(-0.105, 0))
            cone.addLine(to: lp(0, -0.268))
            cone.addLine(to: lp(0.105, 0))
            cone.addQuadCurve(to: lp(-0.105, 0), control: lp(0, 0.03))
            cone.closeSubpath()
            l.fill(cone, with: .linearGradient(soft(c, light: 0.3, dark: 0.22), startPoint: lp(-0.1, -0.1), endPoint: lp(0.1, -0.05)))
            let stripe = c.luminance > 0.7 ? RGB(hex: "#E5484D") : RGB(hex: "#FFF1B8")
            l.drawLayer { s in
                s.clip(to: cone)
                var lines = Path()
                for y0 in [-0.02, -0.1, -0.18] {
                    lines.move(to: lp(-0.15, y0 + 0.04)); lines.addLine(to: lp(0.15, y0 - 0.05))
                }
                s.stroke(lines, with: .color(stripe.opacity(0.9).color), lineWidth: un(0.028))
            }
            l.fill(Path(ellipseIn: lrect(-0.115, -0.022, 0.23, 0.042)), with: .color(RGB(hex: "#FFF7EA").color))
            l.fill(Path(ellipseIn: lrect(-0.036, -0.31, 0.072, 0.072)),
                   with: .radialGradient(Gradient(colors: [RGB(hex: "#FFF7D1").color, RGB(hex: "#FFC93C").color]),
                                         center: lp(-0.012, -0.29), startRadius: 0, endRadius: un(0.045)))

        case "wizard":
            let bluish = base.b > base.r && base.b > base.g
            let c = bluish ? RGB(hex: "#1F6F63") : RGB(hex: "#4338A8")
            let seat = fitted(hatSeat(width: 0.32), sink: 0.04, height: 0.35)
            let l = hatLayer(ctx, seat, sink: 0.04, extraAngle: -0.05)
            l.fill(Path(ellipseIn: lrect(-0.228, -0.038, 0.456, 0.068)),
                   with: .linearGradient(soft(c, light: 0.18, dark: 0.35), startPoint: lp(0, -0.038), endPoint: lp(0, 0.03)))
            var cone = Path()
            cone.move(to: lp(-0.125, -0.008))
            cone.addQuadCurve(to: lp(0.13, -0.335), control: lp(-0.07, -0.25))
            cone.addQuadCurve(to: lp(0.125, -0.008), control: lp(0.01, -0.17))
            cone.closeSubpath()
            l.fill(cone, with: .linearGradient(soft(c, light: 0.28, dark: 0.25), startPoint: lp(-0.1, -0.2), endPoint: lp(0.12, -0.02)))
            let gold = RGB(hex: "#FFD84D")
            l.drawLayer { s in
                s.clip(to: cone)
                s.fill(Path(lrect(-0.2, -0.062, 0.4, 0.032)), with: .color(gold.mix(.black, 0.08).color))
            }
            l.fill(Self.sparkle(center: lp(-0.035, -0.135), radius: un(0.034)), with: .color(gold.color))
            l.fill(Self.sparkle(center: lp(0.035, -0.215), radius: un(0.022)), with: .color(gold.color))

        case "crown":
            let seat = hatSeat(width: 0.2)
            let l = hatLayer(ctx, seat, sink: 0.045, extraAngle: 0.08)
            let w = 0.24 * S, h = 0.13 * S
            var crown = Path()
            crown.move(to: CGPoint(x: -w / 2, y: 0))
            crown.addLine(to: CGPoint(x: -w / 2, y: -h * 0.8))
            crown.addLine(to: CGPoint(x: -w / 4, y: -h * 0.38))
            crown.addLine(to: CGPoint(x: 0, y: -h))
            crown.addLine(to: CGPoint(x: w / 4, y: -h * 0.38))
            crown.addLine(to: CGPoint(x: w / 2, y: -h * 0.8))
            crown.addLine(to: CGPoint(x: w / 2, y: 0))
            crown.closeSubpath()
            let gold = Gradient(colors: [RGB(hex: "#FFF0A0").color, RGB(hex: "#FFC93C").color, RGB(hex: "#D99500").color])
            l.fill(crown, with: .linearGradient(gold, startPoint: CGPoint(x: -w / 2, y: -h), endPoint: CGPoint(x: w / 2, y: 0)))
            l.stroke(crown, with: .color(RGB(hex: "#B97A00").opacity(0.6).color),
                     style: StrokeStyle(lineWidth: max(0.5, S * 0.006), lineJoin: .round))
            let b = S * 0.026
            for x in [-w / 2, 0, w / 2] {
                let y = x == 0 ? -h : -h * 0.8
                l.fill(Path(ellipseIn: CGRect(x: x - b / 2, y: y - b / 2, width: b, height: b)), with: .color(RGB(hex: "#FFE27A").color))
            }
            let gem = S * 0.03
            l.fill(Path(ellipseIn: CGRect(x: -gem / 2, y: -h * 0.42 - gem / 2, width: gem, height: gem)), with: .color(RGB(hex: "#FF4D6D").color))

        case "halo":
            // Heiligenschein schwebt bewusst über dem Kopf
            let seat = hatSeat(width: 0.28)
            var l = ctx
            l.translateBy(x: CGFloat(seat.x) * S, y: CGFloat(max(0.045, seat.y - 0.075)) * S)
            l.rotate(by: .radians(seat.angle))
            l.scaleBy(x: seat.scale, y: seat.scale)
            let ring = Path(ellipseIn: lrect(-0.15, -0.04, 0.3, 0.08))
            l.stroke(ring, with: .color(RGB(hex: "#FFD84D").opacity(0.3).color), lineWidth: un(0.06))
            l.stroke(ring, with: .linearGradient(Gradient(colors: [RGB(hex: "#FFF4B0").color, RGB(hex: "#FFC93C").color, RGB(hex: "#E0A100").color]),
                                                 startPoint: lp(-0.15, -0.04), endPoint: lp(0.15, 0.04)),
                     lineWidth: max(1.2, un(0.026)))

        case "flower":
            let x = min(Double(geo.bounds.maxX) - 0.08, cx + 0.17)
            let hp = headPoint(atX: x, upBias: 0.6)
            let nx = cos(hp.angle), ny = sin(hp.angle)
            let c = CGPoint(x: (Double(hp.p.x) - nx * 0.035) * S, y: (Double(hp.p.y) - ny * 0.035) * S)
            let pr = 0.05 * S
            let petal = RGB(hex: "#FFF7F0")
            for i in 0..<5 {
                let a = Double(i) / 5 * 2 * .pi - .pi / 2
                let p = CGPoint(x: c.x + cos(a) * pr, y: c.y + sin(a) * pr)
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - pr * 0.72, y: p.y - pr * 0.72, width: pr * 1.44, height: pr * 1.44)),
                         with: .color(petal.mix(RGB(hex: "#FFC7D8"), base.luminance > 0.8 ? 0.6 : 0.15).color))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - pr * 0.6, y: c.y - pr * 0.6, width: pr * 1.2, height: pr * 1.2)),
                     with: .radialGradient(Gradient(colors: [RGB(hex: "#FFE27A").color, RGB(hex: "#F2A900").color]),
                                           center: CGPoint(x: c.x - pr * 0.2, y: c.y - pr * 0.2), startRadius: 0, endRadius: pr * 0.8))

        case "hair_bow":
            // Haarschleife seitlich oben, wie eine Haarspange
            let c = reddish ? RGB(hex: "#3BB3A0") : RGB(hex: "#FF4F8B")
            let x = min(Double(geo.bounds.maxX) - 0.1, cx + 0.15)
            let hp = headPoint(atX: x, upBias: 0.8)
            var l = ctx
            l.translateBy(x: (Double(hp.p.x) - cos(hp.angle) * 0.02) * S, y: (Double(hp.p.y) - sin(hp.angle) * 0.02) * S)
            l.rotate(by: .radians(hp.angle + .pi / 2 + 0.2))
            l.scaleBy(x: 1.45, y: 1.45)
            for side in [-1.0, 1.0] {
                var tail = Path()
                tail.move(to: lp(side * 0.008, 0.005))
                tail.addLine(to: lp(side * 0.05, 0.085))
                tail.addLine(to: lp(side * 0.026, 0.078))
                tail.addLine(to: lp(side * 0.018, 0.092))
                tail.addLine(to: lp(-side * 0.01, 0.01))
                tail.closeSubpath()
                l.fill(tail, with: .color(c.mix(.black, 0.22).color))
            }
            for side in [-1.0, 1.0] {
                var loop = Path()
                loop.move(to: .zero)
                loop.addCurve(to: .zero, control1: lp(side * 0.13, -0.095), control2: lp(side * 0.135, 0.075))
                l.fill(loop, with: .linearGradient(soft(c, light: 0.28, dark: 0.2), startPoint: lp(0, -0.06), endPoint: lp(0, 0.05)))
            }
            l.fill(Path(roundedRect: lrect(-0.024, -0.026, 0.048, 0.052), cornerRadius: un(0.018)), with: .color(c.mix(.black, 0.15).color))

        case "cat_ears", "horns":
            let horns = mascot.accessory == "horns"
            let seat = hatSeat(width: 0.3)
            let (sl, sr) = geo.span(atY: seat.y + 0.06)
            let off = min(horns ? 0.15 : 0.18, max(0.09, Double(sr - sl) / 2 * (horns ? 0.5 : 0.62)))
            let hornColor = reddish ? RGB(hex: "#3A2433") : RGB(hex: "#E8414B")
            for side in [-1.0, 1.0] {
                let hp = headPoint(atX: seat.x + side * off, upBias: horns ? 1.2 : 1.4)
                var l = ctx
                l.translateBy(x: hp.p.x * S, y: hp.p.y * S)
                l.rotate(by: .radians(hp.angle + .pi / 2 + (horns ? 0 : side * 0.1)))
                let k = horns ? seat.scale * 1.15 : seat.scale
                l.scaleBy(x: k * side, y: k)
                if horns {
                    var horn = Path()
                    horn.move(to: lp(-0.038, 0.032))
                    horn.addQuadCurve(to: lp(0.032, -0.105), control: lp(-0.045, -0.06))
                    horn.addQuadCurve(to: lp(0.038, 0.032), control: lp(0.032, -0.03))
                    horn.closeSubpath()
                    l.fill(horn, with: .linearGradient(soft(hornColor, light: 0.3, dark: 0.3), startPoint: lp(-0.03, -0.08), endPoint: lp(0.04, 0.03)))
                } else {
                    let fur = shade(at: hp.p)
                    var ear = Path()
                    ear.move(to: lp(-0.078, 0.04))
                    ear.addQuadCurve(to: lp(0.004, -0.128), control: lp(-0.062, -0.06))
                    ear.addQuadCurve(to: lp(0.078, 0.04), control: lp(0.058, -0.05))
                    ear.addQuadCurve(to: lp(-0.078, 0.04), control: lp(0, 0.06))
                    ear.closeSubpath()
                    l.fill(ear, with: .linearGradient(Gradient(colors: [fur.mix(.white, 0.14).color, fur.color]),
                                                      startPoint: lp(0, -0.12), endPoint: lp(0, 0.04)))
                    var inner = Path()
                    inner.move(to: lp(-0.042, 0.022))
                    inner.addQuadCurve(to: lp(0.002, -0.088), control: lp(-0.036, -0.04))
                    inner.addQuadCurve(to: lp(0.042, 0.022), control: lp(0.032, -0.034))
                    inner.closeSubpath()
                    l.fill(inner, with: .color(RGB(hex: "#FF9DB8").mix(fur, 0.25).color))
                }
            }

        case "bunny_ears":
            let seat = fitted(hatSeat(width: 0.24), sink: 0.02, height: 0.3)
            for side in [-1.0, 1.0] {
                let hp = headPoint(atX: seat.x + side * 0.075 * seat.scale, upBias: 3)
                let fur = shade(at: hp.p)
                var l = ctx
                l.translateBy(x: hp.p.x * S, y: hp.p.y * S)
                l.rotate(by: .radians(hp.angle + .pi / 2 + side * 0.16))
                l.scaleBy(x: seat.scale, y: seat.scale)
                var ear = Path()
                ear.move(to: lp(-0.046, 0.035))
                ear.addCurve(to: lp(0, -0.27), control1: lp(-0.064, -0.1), control2: lp(-0.058, -0.27))
                ear.addCurve(to: lp(0.046, 0.035), control1: lp(0.058, -0.27), control2: lp(0.064, -0.1))
                ear.closeSubpath()
                l.fill(ear, with: .linearGradient(Gradient(colors: [fur.mix(.white, 0.16).color, fur.color]),
                                                  startPoint: lp(0, -0.26), endPoint: lp(0, 0.03)))
                var inner = Path()
                inner.move(to: lp(-0.022, 0.0))
                inner.addCurve(to: lp(0, -0.215), control1: lp(-0.034, -0.08), control2: lp(-0.03, -0.215))
                inner.addCurve(to: lp(0.022, 0.0), control1: lp(0.03, -0.215), control2: lp(0.034, -0.08))
                inner.closeSubpath()
                l.fill(inner, with: .color(RGB(hex: "#FF9DB8").mix(fur, 0.2).color))
            }

        case "headphones", "headset":
            let headset = mascot.accessory == "headset"
            let (sp, _, ey) = eyeLayout
            let y = ey - 0.01
            let (l, r) = earSides(atY: y)
            // Neuer Stil: kräftiger Bügel in Muschelfarbe, größere Muscheln (Key Visual)
            let bold = mascot.hasModernEyes
            let cushion = accent
            let band = bold && !headset ? cushion.mix(.black, 0.18) : RGB(hex: "#2A2830")
            let topY = Double(hatSeat(width: 0.3).y) - 0.03
            var arc = Path()
            let cupScale = bold ? 1.3 : 1.0
            let cupW = (headset ? 0.06 : 0.075) * cupScale * S, cupH = (headset ? 0.1 : 0.15) * cupScale * S
            arc.move(to: CGPoint(x: (l + 0.01) * S, y: y * S - cupH * 0.3))
            arc.addCurve(to: CGPoint(x: (r - 0.01) * S, y: y * S - cupH * 0.3),
                         control1: CGPoint(x: (l - 0.02) * S, y: (topY - 0.06) * S),
                         control2: CGPoint(x: (r + 0.02) * S, y: (topY - 0.06) * S))
            strokeBehindHead(ctx, arc, color: band, width: max(1.5, S * (headset ? 0.022 : 0.03) * (bold ? 1.5 : 1)))
            if headset {
                // Mikrofonarm vom linken Hörer zum Mund
                let start = CGPoint(x: l * S + cupW * 0.1, y: y * S + cupH * 0.2)
                let end = CGPoint(x: (cx - sp * 0.55) * S, y: (ey + 0.085) * S)
                var boom = Path()
                boom.move(to: start)
                boom.addQuadCurve(to: end, control: CGPoint(x: start.x + S * 0.01, y: end.y + S * 0.01))
                ctx.stroke(boom, with: .color(band.color), style: StrokeStyle(lineWidth: max(1, S * 0.016), lineCap: .round))
                let m = S * 0.026
                ctx.fill(Path(roundedRect: CGRect(x: end.x - m * 0.7, y: end.y - m * 0.55, width: m * 1.6, height: m * 1.1), cornerRadius: m * 0.55),
                         with: .color(band.mix(.white, 0.12).color))
            }
            for (x, side) in [(l, -1.0), (r, 1.0)] {
                let ccx = x * S + side * cupW * 0.15
                let rect = CGRect(x: ccx - cupW / 2, y: y * S - cupH / 2, width: cupW, height: cupH)
                ctx.fill(Path(roundedRect: rect, cornerRadius: cupW * 0.45),
                         with: .linearGradient(Gradient(colors: [cushion.mix(.white, 0.2).color, cushion.mix(.black, 0.3).color]),
                                               startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                let inner = rect.insetBy(dx: cupW * 0.22, dy: cupH * 0.18).offsetBy(dx: side * cupW * 0.12, dy: 0)
                ctx.fill(Path(roundedRect: inner, cornerRadius: cupW * 0.3), with: .color(band.opacity(0.85).color))
            }

        // MARK: Gesicht
        case "glasses" where mascot.hasModernEyes:
            // Eckige, schmale Fassung wie im Key Visual (passt zu den gezeichneten Augen)
            let (sp, er, ey) = eyeLayout
            let (rx, ry) = modernEyeRadii(er * S)
            let hw = min(un(sp - 0.012), rx * 1.24), hh = ry * 0.98
            let y = ey * S + ry * 0.04
            let lw = max(1.1, S * 0.018)
            let frame = ink.mix(base, 0.18)
            for side in [-1.0, 1.0] {
                let ex = (cx + side * sp) * S
                let rect = CGRect(x: ex - hw, y: y - hh, width: hw * 2, height: hh * 2)
                let lens = Path(roundedRect: rect, cornerRadius: hh * 0.42, style: .continuous)
                ctx.fill(lens, with: .color(.white.opacity(0.1)))
                ctx.stroke(lens, with: .color(frame.color), lineWidth: lw)
                if detail {
                    var glint = Path()
                    glint.move(to: CGPoint(x: rect.minX + hw * 0.3, y: rect.minY + hh * 0.75))
                    glint.addLine(to: CGPoint(x: rect.minX + hw * 0.62, y: rect.minY + hh * 0.3))
                    ctx.stroke(glint, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: lw * 0.8, lineCap: .round))
                }
                // Bügel zum Kopfrand
                let (l, r) = geo.span(atY: ey - 0.02)
                let edge = (side > 0 ? r - 0.015 : l + 0.015) * S
                let start = side > 0 ? rect.maxX : rect.minX
                if (edge - start) * side > 2 {
                    var temple = Path()
                    temple.move(to: CGPoint(x: start, y: rect.minY + hh * 0.45))
                    temple.addLine(to: CGPoint(x: edge, y: rect.minY + hh * 0.3))
                    ctx.stroke(temple, with: .color(frame.color), style: StrokeStyle(lineWidth: lw, lineCap: .round))
                }
            }
            var bridge = Path()
            let lx = (cx - sp) * S + hw, rx2 = (cx + sp) * S - hw
            bridge.move(to: CGPoint(x: lx, y: y - hh * 0.35))
            bridge.addQuadCurve(to: CGPoint(x: rx2, y: y - hh * 0.35), control: CGPoint(x: (lx + rx2) / 2, y: y - hh * 0.75))
            ctx.stroke(bridge, with: .color(frame.color), lineWidth: lw)

        case "glasses":
            let (sp, er, ey) = eyeLayout
            let r = min(sp - 0.012, max(0.07, er * 1.45)) * S
            let y = ey * S
            let lw = max(1, S * 0.016)
            var bridge = Path()
            for side in [-1.0, 1.0] {
                let ex = (cx + side * sp) * S
                let lens = Path(ellipseIn: CGRect(x: ex - r, y: y - r, width: 2 * r, height: 2 * r))
                ctx.fill(lens, with: .color(.white.opacity(0.14)))
                ctx.stroke(lens, with: .color(ink.color), lineWidth: lw)
                var glint = Path()
                glint.addArc(center: CGPoint(x: ex, y: y), radius: r * 0.7, startAngle: .degrees(200), endAngle: .degrees(245), clockwise: false)
                ctx.stroke(glint, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: lw * 0.7, lineCap: .round))
            }
            let lx = (cx - sp) * S + r, rx = (cx + sp) * S - r
            bridge.move(to: CGPoint(x: lx, y: y))
            bridge.addQuadCurve(to: CGPoint(x: rx, y: y), control: CGPoint(x: (lx + rx) / 2, y: y - r * 0.4))
            ctx.stroke(bridge, with: .color(ink.color), lineWidth: lw)

        case "sunglasses":
            let (sp, er, ey) = eyeLayout
            let w = min(sp * 2 - 0.03, max(0.15, er * 3.1)), h = max(0.105, er * 2.2)
            let lw = max(1, S * 0.014)
            for side in [-1.0, 1.0] {
                let ex = cx + side * sp
                let rect = lrect(ex - w / 2, ey - h * 0.45, w, h)
                var lens = Path()
                // leicht nach unten außen gezogene Gläser
                lens.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY))
                lens.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.minY))
                lens.addQuadCurve(to: CGPoint(x: rect.midX + side * rect.width * 0.28, y: rect.maxY),
                                  control: CGPoint(x: side > 0 ? rect.maxX + rect.width * 0.08 : rect.maxX, y: rect.minY + rect.height * 0.6))
                lens.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY),
                                  control: CGPoint(x: side > 0 ? rect.minX : rect.minX - rect.width * 0.08, y: rect.maxY + rect.height * 0.15))
                lens.closeSubpath()
                ctx.fill(lens, with: .linearGradient(Gradient(colors: [RGB(hex: "#3B3448").color, RGB(hex: "#0E0C13").color]),
                                                     startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
                ctx.stroke(lens, with: .color(ink.color), style: StrokeStyle(lineWidth: lw, lineJoin: .round))
                if S >= 40 {
                    var glint = Path()
                    glint.move(to: CGPoint(x: rect.minX + rect.width * 0.28, y: rect.minY + rect.height * 0.62))
                    glint.addLine(to: CGPoint(x: rect.minX + rect.width * 0.5, y: rect.minY + rect.height * 0.2))
                    ctx.stroke(glint, with: .color(.white.opacity(0.5)), style: StrokeStyle(lineWidth: lw * 1.1, lineCap: .round))
                }
            }
            var bridge = Path()
            bridge.move(to: lp(cx - sp + w / 2 - 0.01, ey - h * 0.3))
            bridge.addQuadCurve(to: lp(cx + sp - w / 2 + 0.01, ey - h * 0.3), control: lp(cx, ey - h * 0.5))
            ctx.stroke(bridge, with: .color(ink.color), style: StrokeStyle(lineWidth: lw * 1.3, lineCap: .round))

        case "monocle":
            let (sp, er, ey) = eyeLayout
            let r = min(sp - 0.01, max(0.068, er * 1.5))
            let c = lp(cx + sp, ey)
            let gold = RGB(hex: "#E2B13C")
            let lens = Path(ellipseIn: CGRect(x: c.x - un(r), y: c.y - un(r), width: un(2 * r), height: un(2 * r)))
            ctx.fill(lens, with: .color(.white.opacity(0.16)))
            var chain = Path()
            chain.move(to: CGPoint(x: c.x + un(r * 0.72), y: c.y + un(r * 0.72)))
            let endX = min(Double(geo.bounds.maxX) - 0.05, cx + sp + 0.12)
            chain.addQuadCurve(to: lp(endX, ey + 0.2), control: lp(cx + sp + r + 0.09, ey + 0.05))
            ctx.stroke(chain, with: .color(gold.mix(.black, 0.1).color),
                       style: StrokeStyle(lineWidth: max(0.8, un(0.009)), lineCap: .round, dash: detail ? [un(0.004), un(0.016)] : []))
            ctx.stroke(lens, with: .color(ink.opacity(0.55).color), lineWidth: max(1.8, un(0.03)))
            ctx.stroke(lens, with: .linearGradient(Gradient(colors: [RGB(hex: "#FFE9A3").color, gold.mix(.black, 0.2).color]),
                                                   startPoint: CGPoint(x: c.x - un(r), y: c.y - un(r)), endPoint: CGPoint(x: c.x + un(r), y: c.y + un(r))),
                       lineWidth: max(1.2, un(0.017)))
            var glint = Path()
            glint.addArc(center: c, radius: un(r * 0.68), startAngle: .degrees(200), endAngle: .degrees(245), clockwise: false)
            ctx.stroke(glint, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: max(0.8, un(0.011)), lineCap: .round))

        // MARK: Hals
        case "bowtie":
            let c = accent
            let center = pt(fc.x, min(geo.bounds.maxY - 0.07, fc.y + 0.155))
            let w = 0.1 * S, h = 0.075 * S
            for side in [-1.0, 1.0] {
                var wing = Path()
                wing.move(to: center)
                wing.addQuadCurve(to: CGPoint(x: center.x + side * w, y: center.y - h / 2),
                                  control: CGPoint(x: center.x + side * w * 0.5, y: center.y - h * 0.55))
                wing.addQuadCurve(to: CGPoint(x: center.x + side * w, y: center.y + h / 2),
                                  control: CGPoint(x: center.x + side * w * 1.18, y: center.y))
                wing.addQuadCurve(to: center, control: CGPoint(x: center.x + side * w * 0.5, y: center.y + h * 0.55))
                ctx.fill(wing, with: .linearGradient(Gradient(colors: [c.mix(.white, 0.2).color, c.mix(.black, 0.25).color]),
                                                     startPoint: CGPoint(x: center.x, y: center.y - h / 2),
                                                     endPoint: CGPoint(x: center.x, y: center.y + h / 2)))
                if detail {
                    for (dx, dy) in [(0.62, -0.18), (0.8, 0.22)] {
                        let d = S * 0.012
                        ctx.fill(Path(ellipseIn: CGRect(x: center.x + side * w * dx - d / 2, y: center.y + h * dy - d / 2, width: d, height: d)),
                                 with: .color(.white.opacity(0.75)))
                    }
                }
            }
            let k = S * 0.034
            ctx.fill(Path(roundedRect: CGRect(x: center.x - k / 2, y: center.y - k * 0.6, width: k, height: k * 1.2), cornerRadius: k * 0.3),
                     with: .color(c.mix(.black, 0.3).color))

        case "tie":
            let c = accent
            let maxY = Double(geo.bounds.maxY)
            let yk = max(Double(fc.y) + 0.125, min(maxY - 0.17, Double(fc.y) + 0.145))
            let len = max(0.1, min(0.19, maxY + 0.02 - yk))
            var blade = Path()
            blade.move(to: lp(cx - 0.02, yk + 0.018))
            blade.addLine(to: lp(cx + 0.02, yk + 0.018))
            blade.addLine(to: lp(cx + 0.047, yk + len - 0.042))
            blade.addLine(to: lp(cx, yk + len))
            blade.addLine(to: lp(cx - 0.047, yk + len - 0.042))
            blade.closeSubpath()
            ctx.fill(blade, with: .linearGradient(soft(c, light: 0.22, dark: 0.22), startPoint: lp(cx - 0.05, yk), endPoint: lp(cx + 0.05, yk + len)))
            if detail {
                var stripes = ctx
                stripes.clip(to: blade)
                var lines = Path()
                for k in stride(from: 0.04, through: len, by: 0.045) {
                    lines.move(to: lp(cx - 0.06, yk + k)); lines.addLine(to: lp(cx + 0.06, yk + k - 0.05))
                }
                stripes.stroke(lines, with: .color(.white.opacity(0.3)), lineWidth: un(0.012))
            }
            var knot = Path()
            knot.move(to: lp(cx - 0.034, yk - 0.024))
            knot.addLine(to: lp(cx + 0.034, yk - 0.024))
            knot.addLine(to: lp(cx + 0.021, yk + 0.024))
            knot.addLine(to: lp(cx - 0.021, yk + 0.024))
            knot.closeSubpath()
            ctx.fill(knot, with: .color(c.mix(.black, 0.25).color))
            ctx.stroke(knot, with: .color(c.mix(.black, 0.25).color), style: StrokeStyle(lineWidth: un(0.01), lineJoin: .round))

        case "scarf":
            let c = accent
            let maxY = Double(geo.bounds.maxY)
            let y0 = max(Double(fc.y) + 0.13, min(maxY - 0.1, Double(fc.y) + 0.155))
            let (l0, r0) = geo.span(atY: y0)
            let left = Double(l0) - 0.012, right = Double(r0) + 0.012, mid = (left + right) / 2
            let th = 0.072, sag = 0.032
            var band = Path()
            band.move(to: lp(left, y0 - th / 2))
            band.addQuadCurve(to: lp(right, y0 - th / 2), control: lp(mid, y0 - th / 2 + sag * 2))
            band.addQuadCurve(to: lp(right, y0 + th / 2), control: lp(right + 0.022, y0))
            band.addQuadCurve(to: lp(left, y0 + th / 2), control: lp(mid, y0 + th / 2 + sag * 2))
            band.addQuadCurve(to: lp(left, y0 - th / 2), control: lp(left - 0.022, y0))
            band.closeSubpath()
            ctx.fill(band, with: .linearGradient(soft(c, light: 0.22, dark: 0.22), startPoint: lp(mid, y0 - th / 2), endPoint: lp(mid, y0 + th / 2 + sag)))
            // herabhängendes Ende mit Streifen
            let tx = mid + (right - mid) * 0.42
            let top = y0 + sag * 0.8
            let bottom = min(maxY + 0.035, top + 0.17)
            var tail = Path()
            tail.move(to: lp(tx - 0.044, top))
            tail.addLine(to: lp(tx + 0.04, top))
            tail.addLine(to: lp(tx + 0.056, bottom))
            tail.addLine(to: lp(tx - 0.03, bottom))
            tail.closeSubpath()
            ctx.fill(tail, with: .linearGradient(soft(c, light: 0.12, dark: 0.3), startPoint: lp(tx, top), endPoint: lp(tx, bottom)))
            var stripes = ctx
            stripes.clip(to: tail)
            for yy in [bottom - 0.05, bottom - 0.085] {
                stripes.fill(Path(lrect(tx - 0.08, yy, 0.16, 0.016)), with: .color(RGB(hex: "#FFF7EA").opacity(0.85).color))
            }
            if detail {
                var fringe = Path()
                for k in 0..<5 {
                    let fx = tx - 0.026 + Double(k) * 0.019
                    fringe.move(to: lp(fx, bottom)); fringe.addLine(to: lp(fx + 0.003, bottom + 0.022))
                }
                ctx.stroke(fringe, with: .color(c.mix(.black, 0.2).color), style: StrokeStyle(lineWidth: un(0.008), lineCap: .round))
            }
            ctx.fill(Path(roundedRect: lrect(tx - 0.05, y0 - th / 2 + sag * 0.9, 0.1, th), cornerRadius: un(0.03)),
                     with: .linearGradient(soft(c, light: 0.08, dark: 0.32), startPoint: lp(tx, y0 - th / 2 + sag), endPoint: lp(tx, y0 + th / 2 + sag)))

        default:
            break
        }
    }
}

