#if os(macOS)
import AppKit
import SwiftUI

/// Prüfblatt für den neuen Scoops-Stil (v1.31, Key Visual „B“): Nachbau der Key-Visual-Gruppe, neue Augen, Blick, Mund,
/// Größen der Seitenleiste bis Profil und zum Vergleich der klassische Stil. Wird von `AssetRenderer` als
/// `mascots-neu.png` geschrieben; `reference` ist optional das Key Visual (nicht im Repository).
struct MascotStyleSheet: View {
    var reference: NSImage? = nil

    /// Die sieben Figuren des Key Visuals, nachgebaut mit Editor-Optionen
    static let keyVisual: [(name: String, mascot: Mascot)] = [
        ("Stern, Kappe", Mascot(shape: "star_soft", color: "#43C62E", eyes: "dashes", accessory: "cap", mouth: "smile")),
        ("Ei, Barett", Mascot(shape: "egg", color: "#FBBA10", eyes: "relaxed", accessory: "beret", gaze: "right")),
        ("Dreieck, Krawatte", Mascot(shape: "triangle", color: "#1270E8", eyes: "dashes", accessory: "tie", mouth: "smile")),
        ("Bohne, Brille", Mascot(shape: "pill", color: "#8A2EDB", eyes: "focused", accessory: "glasses", gaze: "right")),
        ("Herz", Mascot(shape: "heart", color: "#F72A7A", eyes: "lashes", accessory: "none", gaze: "left", mouth: "smile")),
        ("Koralle, Kopfhörer", Mascot(shape: "egg", color: "#FA5438", eyes: "relaxed", accessory: "headphones", gaze: "left")),
        ("Creme, Krone", Mascot(shape: "circle", color: "#F1DDBB", eyes: "cat", accessory: "crown", gaze: "left", mouth: "smile")),
    ]

    private func label(_ s: String) -> some View {
        Text(s).font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
    }

    private func heading(_ s: String) -> some View {
        Text(s).font(.system(size: 20, weight: .semibold)).foregroundStyle(.white).padding(.top, 8)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Scoops – neuer Stil").font(.system(size: 30, weight: .bold)).foregroundStyle(.white)

            if let reference {
                heading("Referenz (Key Visual, Augen B)")
                Image(nsImage: reference)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 1500)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }

            heading("Nachbau in der App")
            HStack(alignment: .bottom, spacing: -34) {
                ForEach(Array(Self.keyVisual.enumerated()), id: \.offset) { i, f in
                    MascotView(mascot: f.mascot, size: 236, seed: "kv\(i)", animated: false, showsGround: true)
                }
            }
            HStack(spacing: 0) {
                ForEach(Self.keyVisual, id: \.name) { f in
                    label(f.name).frame(width: 202)
                }
            }

            heading("Augen")
            HStack(spacing: 12) {
                ForEach(Mascot.eyeStyles, id: \.self) { e in
                    VStack(spacing: 2) {
                        MascotView(mascot: Mascot(shape: "egg", color: "#FA5438", eyes: e, accessory: "none"),
                                   size: 150, seed: e, animated: false, showsGround: true)
                        label(Mascot.eyesName(e))
                    }
                }
            }

            heading("Blick und Mund")
            HStack(spacing: 12) {
                ForEach(Mascot.gazes, id: \.self) { g in
                    VStack(spacing: 2) {
                        MascotView(mascot: Mascot(shape: "circle", color: "#1270E8", eyes: "lashes", accessory: "none", gaze: g),
                                   size: 130, seed: "g", animated: false)
                        label("Blick " + Mascot.gazeName(g))
                    }
                }
                Spacer().frame(width: 30)
                ForEach(Mascot.mouths, id: \.self) { m in
                    VStack(spacing: 2) {
                        MascotView(mascot: Mascot(shape: "circle", color: "#8A2EDB", eyes: "relaxed", accessory: "none", gaze: "right", mouth: m),
                                   size: 130, seed: "m", animated: false)
                        label("Mund " + Mascot.mouthName(m))
                    }
                }
            }

            heading("Größen 24 · 36 · 58 · 104 · 160 (dunkel und hell) und Arbeits-Pose")
            ForEach([Theme.nacht, Theme.hell], id: \.kind) { theme in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach([0, 3, 4, 6], id: \.self) { i in
                        HStack(alignment: .bottom, spacing: 16) {
                            ForEach([24, 36, 58, 104, 160], id: \.self) { s in
                                MascotView(mascot: Self.keyVisual[i].mascot, size: CGFloat(s), seed: "kv\(i)", animated: false)
                            }
                            MascotView(mascot: Self.keyVisual[i].mascot, size: 160, mood: .workingStill, seed: "kv\(i)")
                        }
                    }
                }
                .padding(18)
                .background(theme.groupedBackground, in: RoundedRectangle(cornerRadius: 16))
                .environment(\.theme, theme)
            }

            heading("Nicht mehr angebotene Augen (gespeichert → gezeichnet)")
            HStack(spacing: 8) {
                ForEach(Array(EyeVariantsSheet.retired.enumerated()), id: \.offset) { i, e in
                    VStack(spacing: 2) {
                        MascotView(mascot: Mascot(shape: "egg", color: Mascot.palette[(i * 2 + 3) % Mascot.palette.count].hex,
                                                  eyes: e, accessory: "none"),
                                   size: 120, seed: e, animated: false, showsGround: true)
                        label("\(Mascot.eyesName(e)) → \(Mascot.eyesName(Mascot.retiredEyeStyles[e] ?? e))")
                    }
                }
            }
        }
        .padding(32)
        .background(Color(hex: "#0B0B0C"))
        .environment(\.theme, .nacht)
    }
}
/// Übersicht der Augenstile (2026-11): jeder Stil auf mehreren Formen und Farben groß, darunter als kleiner Avatar
/// (28–44 pt) auf dunklem und hellem Grund, dazu die Zuordnung nicht mehr angebotener Stile.
/// Wird von `AssetRenderer` als `augen-varianten.png` geschrieben (`AIS_RENDER_ONLY=eyes` nur diese).
struct EyeVariantsSheet: View {
    static let retired = ["skeptical", "calm", "sleepy", "dots", "ovals", "diamonds", "sparkle"]
    /// Formen und Farben je Spalte (Key-Visual-Farben plus zwei klassische)
    static let bodies: [(shape: String, color: String)] = [
        ("egg", "#FA5438"), ("circle", "#F1DDBB"), ("heart", "#F72A7A"), ("star_soft", "#43C62E"),
        ("pill", "#8A2EDB"), ("triangle", "#1270E8"), ("cloud", "#FBBA10"), ("square", "#22BFAE"),
    ]

    private func mascot(_ eyes: String, _ i: Int) -> Mascot {
        Mascot(shape: Self.bodies[i].shape, color: Self.bodies[i].color, eyes: eyes, accessory: "none")
    }

    private func text(_ s: String, size: CGFloat = 13, color: Color = .white.opacity(0.65)) -> some View {
        Text(s).font(.system(size: size, weight: size > 16 ? .semibold : .regular)).foregroundStyle(color)
    }

    private func smallRow(theme: Theme) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Mascot.eyeStyles, id: \.self) { e in
                HStack(spacing: 14) {
                    Text(Mascot.eyesName(e)).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textPrimary)
                        .frame(width: 96, alignment: .leading)
                    ForEach([44, 36, 32, 28], id: \.self) { s in
                        HStack(spacing: 6) {
                            ForEach(0..<4, id: \.self) { i in
                                MascotView(mascot: mascot(e, i * 2 % Self.bodies.count), size: CGFloat(s), seed: "s\(e)\(i)",
                                           animated: false)
                            }
                        }
                        .padding(.trailing, 14)
                    }
                }
            }
        }
        .padding(18)
        .background(theme.groupedBackground, in: RoundedRectangle(cornerRadius: 16))
        .environment(\.theme, theme)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            text("Scoops – Augenstile", size: 30, color: .white)
            text("Nur Wimpern und Katzenaugen haben Wimpern. Striche schauen immer geradeaus.", size: 15)

            text("Groß (120 pt) auf verschiedenen Formen und Farben", size: 20, color: .white)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Mascot.eyeStyles, id: \.self) { e in
                    HStack(spacing: 4) {
                        VStack(alignment: .leading, spacing: 2) {
                            text(Mascot.eyesName(e), size: 15, color: .white)
                            text(e, size: 12)
                        }
                        .fixedSize()
                        .frame(width: 110, alignment: .leading)
                        ForEach(0..<Self.bodies.count, id: \.self) { i in
                            MascotView(mascot: mascot(e, i), size: 120, seed: "b\(e)\(i)", animated: false)
                        }
                    }
                }
            }

            text("Klein (44 · 36 · 32 · 28 pt), dunkel und hell", size: 20, color: .white)
            HStack(alignment: .top, spacing: 16) {
                smallRow(theme: .nacht)
                smallRow(theme: .hell)
            }

            text("Blick (Wimpern, Katzenaugen, Verträumt, Ernst: links · geradeaus · rechts)", size: 20, color: .white)
            HStack(spacing: 18) {
                ForEach(["lashes", "cat", "relaxed", "focused"], id: \.self) { e in
                    HStack(spacing: 0) {
                        ForEach(Mascot.gazes, id: \.self) { g in
                            MascotView(mascot: Mascot(shape: "circle", color: "#1270E8", eyes: e, accessory: "none", gaze: g),
                                       size: 96, seed: "g", animated: false)
                        }
                    }
                }
            }

            text("Nicht mehr angeboten: gespeicherter Wert → gezeichneter Stil", size: 20, color: .white)
            HStack(spacing: 10) {
                ForEach(Array(Self.retired.enumerated()), id: \.offset) { i, e in
                    VStack(spacing: 2) {
                        MascotView(mascot: mascot(e, i), size: 110, seed: "r\(e)", animated: false)
                        text("\(e) → \(Mascot.retiredEyeStyles[e] ?? e)")
                        text("\(Mascot.eyesName(e)) → \(Mascot.eyesName(Mascot.retiredEyeStyles[e] ?? e))", size: 11)
                    }
                }
            }

            text("Key Visual nachgebaut", size: 20, color: .white)
            HStack(alignment: .bottom, spacing: -30) {
                ForEach(Array(MascotStyleSheet.keyVisual.enumerated()), id: \.offset) { i, f in
                    MascotView(mascot: f.mascot, size: 200, seed: "kv\(i)", animated: false, showsGround: true)
                }
            }
        }
        .padding(32)
        .background(Color(hex: "#0B0B0C"))
        .environment(\.theme, .nacht)
    }
}
#endif
