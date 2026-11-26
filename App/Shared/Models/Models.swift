import Foundation

// MARK: - Datenmodelle laut docs/API.md (JSON snake_case, Decoder nutzt .convertFromSnakeCase)

nonisolated struct Mascot: Codable, Hashable, Sendable {
    var shape: String
    var color: String
    var eyes: String
    var accessory: String
    /// Eigenes Bild statt Maskottchen (v1.12, vom Server abgeleitet, wird beim Speichern ignoriert).
    /// `MascotView` zeigt dann automatisch das runde Bild, siehe `ScoopPhoto.swift`.
    var photo: MascotPhoto? = nil
    /// Blickrichtung der neuen Augen (v1.31): "left", "center", "right". nil = Standard des Augenstils.
    /// Ältere App-Versionen ignorieren das Feld.
    var gaze: String? = nil
    /// Mund (v1.31): "smirk" (schief), "smile" (Lächeln), "neutral". nil = passend zu den Augen.
    var mouth: String? = nil
    /// Rote Wangen (v1.31). nil = automatisch: an bei klassischen Augen, aus bei den neuen.
    var cheeks: Bool? = nil

    /// Organische „Figuren“
    static let organicShapes = ["bean", "pear", "cloud", "egg", "blob", "star", "drop", "bun", "ghost", "flower"]
    /// Symmetrische „Formen“ (v1.1)
    static let geometricShapes = ["circle", "oval_tall", "oval_wide", "square", "rect_tall", "rect_wide", "triangle",
                                  "diamond", "hexagon", "heart", "arrow", "pill", "flower_round", "star_soft"]
    static let shapes = organicShapes + geometricShapes
    /// Neue, gezeichnete Augen (v1.31, Key-Visual-Stil, ab 2026-11 klar unterscheidbar): Wimpern (waagerecht, Lidschwung),
    /// Katzenaugen (mandelförmig, schräg), halb geschlossen („relaxed“), ernst („focused“) und senkrechte Striche.
    /// Nur Wimpern und Katzenaugen haben Wimpern. Ältere App-Versionen kennen „cat“ und „dashes“ nicht und zeichnen
    /// Punktaugen (`default`-Fall in `MascotPainter.drawEye`).
    static let modernEyeStyles = ["lashes", "cat", "relaxed", "focused", "dashes"]
    /// Verbliebene klassische Augen: nur „Zufrieden“ (geschlossene Bögen) bringt neben den neuen echte Vielfalt.
    static let classicEyeStyles = ["happy"]
    /// Auswahl im Editor (eine Gruppe „Augen“, neue vorne) und für Übersichten.
    static let eyeStyles = modernEyeStyles + classicEyeStyles
    /// Nicht mehr angebotene Augen und der Stil, mit dem sie gezeichnet werden. Nur eine Zuordnung beim Zeichnen:
    /// Der gespeicherte Wert bleibt, bis der Scoop im Editor einen neuen Stil bekommt.
    static let retiredEyeStyles: [String: String] = [
        "skeptical": "relaxed", "calm": "relaxed", "sleepy": "relaxed",   // Lid tief → halb geschlossen
        "dots": "dashes", "ovals": "dashes", "diamonds": "dashes",       // dunkle Knopfaugen → Striche
        "sparkle": "lashes",                                              // große, glänzende Augen → Wimpern
    ]
    static let gazes = ["left", "center", "right"]
    static let mouths = ["smirk", "smile", "neutral"]
    /// Accessoires, die die Zufallsfunktion wählt (erwachsen bzw. produktiv, höchstens eins)
    static let calmAccessories = ["glasses", "headphones", "beret", "cap", "headset", "beanie", "sunglasses", "tie", "scarf"]
    static let accessories = ["none", "beret", "bowtie", "glasses", "headphones", "cap", "flower", "crown",
                              // Build 12
                              "beanie", "tophat", "cowboy", "partyhat", "wizard", "halo", "hair_bow", "cat_ears",
                              "bunny_ears", "horns", "headset", "sunglasses", "monocle", "tie", "scarf"]
    /// Gruppen für die Auswahl im Maskottchen-Editor (jedes Accessoire genau einmal).
    static var accessoryGroups: [(title: String, items: [String])] { [
        (String(localized: "Kopf", comment: "Accessoire-Gruppe im Maskottchen-Editor"),
         ["none", "beret", "cap", "beanie", "tophat", "cowboy", "partyhat", "wizard", "crown", "halo",
          "flower", "hair_bow", "cat_ears", "bunny_ears", "horns", "headphones", "headset"]),
        (String(localized: "Gesicht", comment: "Accessoire-Gruppe im Maskottchen-Editor"), ["glasses", "sunglasses", "monocle"]),
        (String(localized: "Hals", comment: "Accessoire-Gruppe im Maskottchen-Editor"), ["bowtie", "tie", "scarf"]),
    ] }

    /// Satte Key-Visual-Farben (v1.31), im Editor in der ersten Reihe: Grün, Gelb, Blau, Violett, Pink, Koralle, Creme.
    static var boldPalette: [(name: String, hex: String)] { [
        (String(localized: "Grün", comment: "Farbe des Maskottchens"), "#43C62E"),
        (String(localized: "Gelb", comment: "Farbe des Maskottchens"), "#FBBA10"),
        (String(localized: "Blau", comment: "Farbe des Maskottchens"), "#1270E8"),
        (String(localized: "Violett", comment: "Farbe des Maskottchens"), "#8A2EDB"),
        (String(localized: "Pink", comment: "Farbe des Maskottchens"), "#F72A7A"),
        (String(localized: "Koralle", comment: "Farbe des Maskottchens"), "#FA5438"),
        (String(localized: "Creme", comment: "Farbe des Maskottchens"), "#F1DDBB"),
    ] }
    /// Klassische Farbpalette des Anlege-Dialogs (Reihenfolge wie im Design, Indizes werden in den Einstellungen genutzt).
    static var palette: [(name: String, hex: String)] { [
        (String(localized: "Weiß", comment: "Farbe des Maskottchens"), "#F3EFE7"),
        (String(localized: "Braun", comment: "Farbe des Maskottchens"), "#A87452"),
        (String(localized: "Rot", comment: "Farbe des Maskottchens"), "#F2484E"),
        (String(localized: "Orange", comment: "Farbe des Maskottchens"), "#FF7A30"),
        (String(localized: "Bernstein", comment: "Farbe des Maskottchens"), "#FFB524"),
        (String(localized: "Grün", comment: "Farbe des Maskottchens"), "#34C46C"),
        (String(localized: "Türkis", comment: "Farbe des Maskottchens"), "#22BFAE"),
        (String(localized: "Blau", comment: "Farbe des Maskottchens"), "#3D84F5"),
        (String(localized: "Violett", comment: "Farbe des Maskottchens"), "#8B5CF6"),
        (String(localized: "Pink", comment: "Farbe des Maskottchens"), "#FF5FA8"),
        (String(localized: "Grau", comment: "Farbe des Maskottchens"), "#9C9CA3"),
    ] }

    /// Namen (übersetzt) für Auswahl und Übersichten.
    static func shapeName(_ s: String) -> String {
        switch s {
        case "bean": String(localized: "Bohne", comment: "Form des Maskottchens")
        case "pear": String(localized: "Birne", comment: "Form des Maskottchens")
        case "cloud": String(localized: "Wolke", comment: "Form des Maskottchens")
        case "egg": String(localized: "Ei", comment: "Form des Maskottchens")
        case "blob": String(localized: "Klecks", comment: "Form des Maskottchens")
        case "star": String(localized: "Stern", comment: "Form des Maskottchens")
        case "drop": String(localized: "Tropfen", comment: "Form des Maskottchens")
        case "bun": String(localized: "Brötchen", comment: "Form des Maskottchens")
        case "ghost": String(localized: "Gespenst", comment: "Form des Maskottchens")
        case "flower": String(localized: "Blume", comment: "Form bzw. Accessoire des Maskottchens")
        case "circle": String(localized: "Kreis", comment: "Form des Maskottchens")
        case "oval_tall": String(localized: "Oval hoch", comment: "Form des Maskottchens")
        case "oval_wide": String(localized: "Oval quer", comment: "Form des Maskottchens")
        case "square": String(localized: "Quadrat", comment: "Form des Maskottchens")
        case "rect_tall": String(localized: "Rechteck hoch", comment: "Form des Maskottchens")
        case "rect_wide": String(localized: "Rechteck quer", comment: "Form des Maskottchens")
        case "triangle": String(localized: "Dreieck", comment: "Form des Maskottchens")
        case "diamond": String(localized: "Raute", comment: "Form des Maskottchens")
        case "hexagon": String(localized: "Sechseck", comment: "Form des Maskottchens")
        case "heart": String(localized: "Herz", comment: "Form des Maskottchens")
        case "arrow": String(localized: "Pfeil", comment: "Form des Maskottchens")
        case "pill": String(localized: "Kapsel", comment: "Form des Maskottchens")
        case "flower_round": String(localized: "Runde Blume", comment: "Form des Maskottchens")
        case "star_soft": String(localized: "Stern rund", comment: "Form des Maskottchens")
        default: s
        }
    }

    static func eyesName(_ s: String) -> String {
        switch s {
        case "lashes": String(localized: "Wimpern", comment: "Augenstil des Maskottchens")
        case "cat": String(localized: "Katzenaugen", comment: "Augenstil des Maskottchens")
        case "relaxed": String(localized: "Verträumt", comment: "Augenstil des Maskottchens")
        case "focused": String(localized: "Ernst", comment: "Augenstil des Maskottchens")
        case "dashes": String(localized: "Striche", comment: "Augenstil des Maskottchens")
        case "happy": String(localized: "Zufrieden", comment: "Augenstil des Maskottchens")
        // nicht mehr angeboten (Zuordnung siehe `retiredEyeStyles`)
        case "skeptical": String(localized: "Skeptisch", comment: "Augenstil des Maskottchens")
        case "calm": String(localized: "Ruhig", comment: "Augenstil des Maskottchens")
        case "dots": String(localized: "Punkte", comment: "Augenstil des Maskottchens")
        case "ovals": String(localized: "Ovale", comment: "Augenstil des Maskottchens")
        case "diamonds": String(localized: "Rauten", comment: "Augenstil des Maskottchens")
        case "sleepy": String(localized: "Verschlafen", comment: "Augenstil des Maskottchens")
        case "sparkle": String(localized: "Funkeln", comment: "Augenstil des Maskottchens")
        default: s
        }
    }

    static func gazeName(_ s: String) -> String {
        switch s {
        // Eigener Schlüssel: „Links“ gibt es auch als Dateityp (Weblinks)
        case "left": String(localized: "mascot.gaze.left", defaultValue: "Links", comment: "Blickrichtung des Maskottchens")
        case "center": String(localized: "Geradeaus", comment: "Blickrichtung des Maskottchens")
        case "right": String(localized: "Rechts", comment: "Blickrichtung des Maskottchens")
        default: s
        }
    }
    static func mouthName(_ s: String) -> String {
        switch s {
        case "smirk": String(localized: "Schief", comment: "Mund des Maskottchens")
        case "smile": String(localized: "Lächeln", comment: "Mund des Maskottchens")
        case "neutral": String(localized: "Neutral", comment: "Mund des Maskottchens")
        default: s
        }
    }

    /// Augenstil, mit dem gezeichnet wird (nicht mehr angebotene Stile → Nachfolger). Der Editor zeigt ihn als gewählt.
    var drawnEyes: String { Mascot.retiredEyeStyles[eyes] ?? eyes }
    /// Neue Augen (Oberlid, Pupille, Brauen bzw. Striche)?
    var hasModernEyes: Bool { Mascot.modernEyeStyles.contains(drawnEyes) }
    /// Hat der Augenstil eine Blickrichtung? (Striche schauen immer geradeaus)
    var hasGaze: Bool { hasModernEyes && drawnEyes != "dashes" }
    /// Wirksame Blickrichtung (-1 links … 1 rechts), Standard je Augenstil.
    var gazeValue: Double {
        guard hasGaze else { return 0 }
        switch gaze ?? defaultGaze {
        case "left": return -1
        case "right": return 1
        default: return 0
        }
    }
    var defaultGaze: String {
        // wie im Key Visual: Herz und Creme schauen nach links, Gelb nach rechts, Violett und die Striche geradeaus
        switch drawnEyes {
        case "lashes", "cat": return "left"
        case "focused", "dashes": return "center"
        default: return "right"
        }
    }
    /// Wirksamer Mund: neue Augen schief, Striche und klassische Augen mit dezentem Lächeln.
    var mouthStyle: String { mouth ?? (hasModernEyes && drawnEyes != "dashes" ? "smirk" : "smile") }
    /// Wirksame Wangen: standardmäßig aus (erwachsener Stil), im Editor zuschaltbar.
    var showsCheeks: Bool { cheeks ?? false }
    /// Teil für Bild-Schlüssel: leer bei alten Scoops (Schlüssel bleiben gleich), sonst die neuen Felder.
    var styleKeySuffix: String {
        gaze == nil && mouth == nil && cheeks == nil ? "" : "|\(gaze ?? "-")|\(mouth ?? "-")|\(cheeks.map { $0 ? "1" : "0" } ?? "-")"
    }

    static func accessoryName(_ s: String) -> String {
        switch s {
        case "none": String(localized: "Ohne", comment: "Accessoire des Maskottchens")
        case "beret": String(localized: "Baskenmütze", comment: "Accessoire des Maskottchens")
        case "bowtie": String(localized: "Fliege", comment: "Accessoire des Maskottchens")
        case "glasses": String(localized: "Brille", comment: "Accessoire des Maskottchens")
        case "headphones": String(localized: "Kopfhörer", comment: "Accessoire des Maskottchens")
        case "cap": String(localized: "Kappe", comment: "Accessoire des Maskottchens")
        case "flower": String(localized: "Blume", comment: "Form bzw. Accessoire des Maskottchens")
        case "crown": String(localized: "Krone", comment: "Accessoire des Maskottchens")
        case "beanie": String(localized: "Bommelmütze", comment: "Accessoire des Maskottchens")
        case "tophat": String(localized: "Zylinder", comment: "Accessoire des Maskottchens")
        case "cowboy": String(localized: "Cowboyhut", comment: "Accessoire des Maskottchens")
        case "partyhat": String(localized: "Partyhut", comment: "Accessoire des Maskottchens")
        case "wizard": String(localized: "Zauberhut", comment: "Accessoire des Maskottchens")
        case "halo": String(localized: "Heiligenschein", comment: "Accessoire des Maskottchens")
        case "hair_bow": String(localized: "Haarschleife", comment: "Accessoire des Maskottchens")
        case "cat_ears": String(localized: "Katzenohren", comment: "Accessoire des Maskottchens")
        case "bunny_ears": String(localized: "Hasenohren", comment: "Accessoire des Maskottchens")
        case "horns": String(localized: "Hörnchen", comment: "Accessoire des Maskottchens")
        case "headset": String(localized: "Headset", comment: "Accessoire des Maskottchens")
        case "sunglasses": String(localized: "Sonnenbrille", comment: "Accessoire des Maskottchens")
        case "monocle": String(localized: "Monokel", comment: "Accessoire des Maskottchens")
        case "tie": String(localized: "Krawatte", comment: "Accessoire des Maskottchens")
        case "scarf": String(localized: "Schal", comment: "Accessoire des Maskottchens")
        default: s
        }
    }

    static let `default` = Mascot(shape: "bean", color: "#8B5CF6", eyes: "dots", accessory: "none")
    /// Marken-Scoop (App-Icon, Onboarding, Platzhalter): gelber Kreis, Punktaugen, ohne Accessoire.
    static let brand = Mascot(shape: "circle", color: "#FFC83D", eyes: "dots", accessory: "none")
}

nonisolated struct Bot: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var label: String?
    var mascot: Mascot
    var character: String?
    var model: String?
    var escalationModel: String?
    var pinned: Bool
    var section: String?
    var createdAt: Date?
    var lastMessage: Message?
    var unread: Int
    var busy: Bool
    /// Stimme zum Vorlesen (AVSpeechSynthesisVoice.identifier), v1.1
    var voice: String?
    /// Haupt-Scoop mit Initiative (v1.4)
    var primary: Bool = false
    /// Rechner, an dem der Scoop arbeitet (v1.11, Scoops Connect). `"vm"` = eingebauter Bot-Rechner.
    var computerNode: String = ComputerNode.builtinID
    /// Geteilte Scoops (docs/sharing.md): Personen, mit denen der Admin den Scoop teilt (nur im JSON des Admins)
    var shared: BotShareSummary?
    /// Werkzeuge für Läufe von Gästen (nur Admin)
    var guestTools: GuestTools?
    /// Tageslimit pro Gast in $ (nur Admin)
    var guestBudget: Double?
    /// Sicht eines Gasts: eigene Rolle, Rechner-Stufe, Admin (nur im JSON für Gäste)
    var access: BotAccess?
    /// v1.21: Schalter „Darf andere Scoops prüfen“ (gespeichert, nur Admin)
    var canReview: Bool = false
    /// v1.21: Aufsicht wirksam (Haupt-Scoop oder Schalter; aus, solange der Scoop geteilt ist)
    var reviewer: Bool = false
    /// Wartet auf den Nutzer (offene Freigabe oder Aufgabe mit Rückfrage/Freigabe), Server 1.26.1: rotes „?“
    var waiting: Bool = false
    /// v1.29: Rechner-Zugriff (Rechte-Modus und Standard-Bereich, nur im JSON des Admins)
    var computerAccess: ScoopAccess?
    /// App 1.3: Stummschaltung für mich (docs/ruhe.md, pro Person). `nil` = der Server kann es noch nicht.
    var mute: ChatMute?

    init(id: String, name: String, label: String? = nil, mascot: Mascot, character: String? = nil,
         model: String? = nil, escalationModel: String? = nil, pinned: Bool = false, section: String? = nil,
         createdAt: Date? = nil, lastMessage: Message? = nil, unread: Int = 0, busy: Bool = false, voice: String? = nil,
         primary: Bool = false, computerNode: String = ComputerNode.builtinID) {
        self.primary = primary
        self.computerNode = computerNode
        self.id = id; self.name = name; self.label = label; self.mascot = mascot; self.character = character
        self.model = model; self.escalationModel = escalationModel; self.pinned = pinned; self.section = section
        self.createdAt = createdAt; self.lastMessage = lastMessage; self.unread = unread; self.busy = busy
        self.voice = voice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        mascot = (try? c.decode(Mascot.self, forKey: .mascot)) ?? .default
        character = try c.decodeIfPresent(String.self, forKey: .character)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        escalationModel = try c.decodeIfPresent(String.self, forKey: .escalationModel)
        pinned = (try c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        section = try c.decodeIfPresent(String.self, forKey: .section)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastMessage = try c.decodeIfPresent(Message.self, forKey: .lastMessage)
        unread = (try c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
        busy = (try c.decodeIfPresent(Bool.self, forKey: .busy)) ?? false
        voice = try? c.decodeIfPresent(String.self, forKey: .voice)
        primary = ((try? c.decodeIfPresent(Bool.self, forKey: .primary)) ?? nil) ?? false
        computerNode = ((try? c.decodeIfPresent(String.self, forKey: .computerNode)) ?? nil) ?? ComputerNode.builtinID
        shared = try? c.decodeIfPresent(BotShareSummary.self, forKey: .shared)
        guestTools = try? c.decodeIfPresent(GuestTools.self, forKey: .guestTools)
        guestBudget = try? c.decodeIfPresent(Double.self, forKey: .guestBudget)
        access = try? c.decodeIfPresent(BotAccess.self, forKey: .access)
        canReview = ((try? c.decodeIfPresent(Bool.self, forKey: .canReview)) ?? nil) ?? false
        reviewer = ((try? c.decodeIfPresent(Bool.self, forKey: .reviewer)) ?? nil) ?? false
        waiting = ((try? c.decodeIfPresent(Bool.self, forKey: .waiting)) ?? nil) ?? false
        computerAccess = try? c.decodeIfPresent(ScoopAccess.self, forKey: .computerAccess)
        mute = try? c.decodeIfPresent(ChatMute.self, forKey: .mute)
    }

    /// Gerade stummgeschaltet (keine Mitteilungen aus diesem Chat)
    var isMuted: Bool { mute?.isActive() ?? false }

    /// Mit anderen geteilt (Admin-Sicht)
    var isSharedByMe: Bool { (shared?.count ?? 0) > 0 }

    /// „Name · Label“ wie in der Seitenleiste.
    var title: String {
        if let label, !label.isEmpty { return "\(name) · \(label)" }
        return name
    }

    var trimmedSection: String? {
        guard let s = section?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}

nonisolated enum MessageRole: String, Codable, Sendable {
    case user, bot, event, status, approval
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = MessageRole(rawValue: raw) ?? .unknown
    }
}

/// Alle bekannten `meta`-Felder; unbekannte werden ignoriert.
nonisolated struct MessageMeta: Codable, Hashable, Sendable {
    // event
    var icon: String?
    // status
    var runId: String?
    var state: String?
    var lines: [String]?
    var usesComputer: Bool?
    var model: String?
    var costUsd: Double?
    var startedAt: Date?
    var finishedAt: Date?
    // approval
    var approvalId: String?
    var title: String?
    var details: String?
    /// Art der Freigabe, z. B. "call" (Anruf über Lucy)
    var kind: String?
    /// Fähigkeit zu einem Ereignis „Fähigkeit gespeichert: …“ (falls der Server sie mitschickt)
    var skillId: String?
    /// Link zu einem Ereignis (z. B. T3-Thread, v1.5)
    var url: String?
    var t3ThreadId: String?
    // v1.1: Gruppen, Bibliothek, Sprache
    var authorId: String?
    var fileId: String?
    var fileIds: [String]?
    var voice: Bool?
    // v1.9: Mail-Karte, Reaktionen, Scoops schreiben Scoops
    var mail: MailDraft?
    /// `{akteur: emoji}`, Akteur `"user"` oder Scoop-ID
    var reactions: [String: String]?
    /// Nachricht eines anderen Scoops in diesem Einzelchat
    var peer: Bool?
    /// Ereignis „An Tina: …“ (dieser Scoop hat einem anderen geschrieben)
    var peerOut: Bool?
    var targetId: String?
    var silent: Bool?
    // v1.10: Tresor-Formular, abgebrochene Läufe
    /// Login für den Tresor (`kind == "vault"`)
    var vault: VaultForm?
    /// Lauf wurde durch einen Server-Neustart abgebrochen (`state == "stopped"`)
    var interrupted: Bool?
    /// Im Live-Sprechmodus gesprochen (GPT-Live-1), v1.13
    var live: Bool?
    // Geteilte Scoops: Absender einer Nachricht von Menschen (Konto-ID und Name, docs/sharing.md)
    var authorUserId: String?
    var authorName: String?
    /// `admin` | `read` | `write` | `edit`
    var authorRole: String?
    /// Gast-Ansicht einer Freigabe (ohne Knöpfe, Titel „Wartet auf Freigabe durch …“)
    var guestView: Bool?
    /// Admin-Ansicht: Freigabe aus dem Lauf eines Gasts (`requested_by`)
    var requestedBy: RequestedBy?

    nonisolated struct RequestedBy: Codable, Hashable, Sendable {
        var userId: String?
        var name: String?
    }
    /// Lauf wartet auf eine Freigabe des Admins (Gast-Sicht), optional vom Server
    var ownerName: String?
    /// v1.15: Antwort auf eine bestimmte Nachricht (Zitat oben in der Blase)
    var replyTo: ReplyRef?
    /// App 1.3: Nachricht wurde nachträglich bearbeitet (`PATCH /api/messages/{id}`)
    var edited: EditInfo?

    nonisolated struct EditInfo: Codable, Hashable, Sendable {
        var at: Date?
        /// `replaced` = der Scoop hat neu geantwortet, `corrected` = Korrektur als neuer Auftrag; fehlt, solange offen
        var mode: String?
    }
    /// v1.19: Statuskarte einer Hintergrund-Aufgabe (Aufgabenmodus, docs/aufgaben.md)
    var task: TaskInfo?
    /// v1.19: Ereignis/Nachricht gehört zu einer Aufgabe
    var taskId: String?
    /// v1.20: Freigabe kann dauerhaft erlaubt werden („Immer erlauben“) und gilt dann für `alwaysLabel`
    var canAlways: Bool?
    var alwaysLabel: String?
    /// v1.20: Freigabe wurde mit „Immer erlauben“ erteilt
    var always: Bool?
    /// v1.20: Ereignis „Automatisch freigegeben: …“ (Dauerfreigabe, keine Karte)
    var autoApproved: Bool?
    var standingId: String?
    /// v1.22: Termin und Modell aus dem Aufgaben-Chip („/aufgabe …“)
    var taskOptions: TaskOptions?
    /// v1.27: Geteilter Scoop, „@Person“: Nachricht nur an diese Person(en), der Scoop antwortet nicht
    var toPeople: [String]?
    /// v1.21: Verbesserung für einen anderen Scoop (`kind == "scoop_update"`, Aufsicht)
    var scoopUpdate: ScoopUpdate?
    /// v1.35: Sichere Eingabe in der Freigabe-Karte (Token, Umgebungswerte eigener MCP-Server). Die Werte gehen nur mit
    /// der Entscheidung an den Server (`edits.secrets`), nie in den Chat.
    var secretFields: [SecretField]?
    /// v1.35: Ereignis „Bei … anmelden“ (`kind == "mcp_login"`) bzw. Bezug auf einen eigenen MCP-Server
    var mcpServerId: String?
    var mcpServerName: String?
    /// Begrüßung des Start-Scoops einer neuen Server-Installation (`meta.welcome`, docs/sprache.md): sprachunabhängiges
    /// Merkmal statt Textvergleich (siehe `OnboardingLogic.isFreshServer`)
    var welcome: Bool?

    nonisolated struct SecretField: Codable, Hashable, Sendable, Identifiable {
        var key: String
        var label: String
        var id: String { key }
    }

    nonisolated struct TaskInfo: Codable, Hashable, Sendable {
        var id: String
        var title: String?
        /// queued | running | waiting | done | failed | stopped | limit
        var state: String?
        var engine: String?
        /// letzter Zwischenstand
        var note: String?
        var budgetUsd: Double?
        var maxMinutes: Int?
        /// frage | freigabe | scoop (wartet auf die Antwort eines anderen Scoops)
        var waitingKind: String?
        var waitingFor: String?
    }

    init(icon: String? = nil, runId: String? = nil, state: String? = nil, lines: [String]? = nil,
         usesComputer: Bool? = nil, model: String? = nil, costUsd: Double? = nil, startedAt: Date? = nil,
         finishedAt: Date? = nil, approvalId: String? = nil, title: String? = nil, details: String? = nil,
         authorId: String? = nil, fileId: String? = nil, fileIds: [String]? = nil, voice: Bool? = nil,
         kind: String? = nil, url: String? = nil) {
        self.kind = kind
        self.url = url
        self.icon = icon; self.runId = runId; self.state = state; self.lines = lines
        self.usesComputer = usesComputer; self.model = model; self.costUsd = costUsd
        self.startedAt = startedAt; self.finishedAt = finishedAt
        self.approvalId = approvalId; self.title = title; self.details = details
        self.authorId = authorId; self.fileId = fileId; self.fileIds = fileIds; self.voice = voice
    }

    // Tolerant: einzelne Felder mit falschem Typ brechen nicht die ganze Nachricht.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        icon = try? c.decodeIfPresent(String.self, forKey: .icon)
        runId = try? c.decodeIfPresent(String.self, forKey: .runId)
        state = try? c.decodeIfPresent(String.self, forKey: .state)
        lines = try? c.decodeIfPresent([String].self, forKey: .lines)
        usesComputer = try? c.decodeIfPresent(Bool.self, forKey: .usesComputer)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        costUsd = try? c.decodeIfPresent(Double.self, forKey: .costUsd)
        startedAt = try? c.decodeIfPresent(Date.self, forKey: .startedAt)
        finishedAt = try? c.decodeIfPresent(Date.self, forKey: .finishedAt)
        approvalId = try? c.decodeIfPresent(String.self, forKey: .approvalId)
        title = try? c.decodeIfPresent(String.self, forKey: .title)
        details = try? c.decodeIfPresent(String.self, forKey: .details)
        kind = try? c.decodeIfPresent(String.self, forKey: .kind)
        skillId = try? c.decodeIfPresent(String.self, forKey: .skillId)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        t3ThreadId = try? c.decodeIfPresent(String.self, forKey: .t3ThreadId)
        authorId = try? c.decodeIfPresent(String.self, forKey: .authorId)
        fileId = try? c.decodeIfPresent(String.self, forKey: .fileId)
        fileIds = try? c.decodeIfPresent([String].self, forKey: .fileIds)
        voice = try? c.decodeIfPresent(Bool.self, forKey: .voice)
        mail = try? c.decodeIfPresent(MailDraft.self, forKey: .mail)
        reactions = try? c.decodeIfPresent([String: String].self, forKey: .reactions)
        peer = try? c.decodeIfPresent(Bool.self, forKey: .peer)
        peerOut = try? c.decodeIfPresent(Bool.self, forKey: .peerOut)
        targetId = try? c.decodeIfPresent(String.self, forKey: .targetId)
        silent = try? c.decodeIfPresent(Bool.self, forKey: .silent)
        vault = try? c.decodeIfPresent(VaultForm.self, forKey: .vault)
        interrupted = try? c.decodeIfPresent(Bool.self, forKey: .interrupted)
        live = try? c.decodeIfPresent(Bool.self, forKey: .live)
        authorUserId = try? c.decodeIfPresent(String.self, forKey: .authorUserId)
        authorName = try? c.decodeIfPresent(String.self, forKey: .authorName)
        authorRole = try? c.decodeIfPresent(String.self, forKey: .authorRole)
        guestView = try? c.decodeIfPresent(Bool.self, forKey: .guestView)
        requestedBy = try? c.decodeIfPresent(RequestedBy.self, forKey: .requestedBy)
        ownerName = try? c.decodeIfPresent(String.self, forKey: .ownerName)
        replyTo = try? c.decodeIfPresent(ReplyRef.self, forKey: .replyTo)
        edited = try? c.decodeIfPresent(EditInfo.self, forKey: .edited)
        task = try? c.decodeIfPresent(TaskInfo.self, forKey: .task)
        taskOptions = try? c.decodeIfPresent(TaskOptions.self, forKey: .taskOptions)
        toPeople = try? c.decodeIfPresent([String].self, forKey: .toPeople)
        taskId = try? c.decodeIfPresent(String.self, forKey: .taskId)
        canAlways = try? c.decodeIfPresent(Bool.self, forKey: .canAlways)
        alwaysLabel = try? c.decodeIfPresent(String.self, forKey: .alwaysLabel)
        always = try? c.decodeIfPresent(Bool.self, forKey: .always)
        autoApproved = try? c.decodeIfPresent(Bool.self, forKey: .autoApproved)
        standingId = try? c.decodeIfPresent(String.self, forKey: .standingId)
        scoopUpdate = try? c.decodeIfPresent(ScoopUpdate.self, forKey: .scoopUpdate)
        secretFields = try? c.decodeIfPresent([SecretField].self, forKey: .secretFields)
        mcpServerId = try? c.decodeIfPresent(String.self, forKey: .mcpServerId)
        mcpServerName = try? c.decodeIfPresent(String.self, forKey: .mcpServerName)
        welcome = try? c.decodeIfPresent(Bool.self, forKey: .welcome)
    }
}

/// v1.21: Vorschlag eines Scoops mit Aufsicht für einen anderen Scoop (`meta.scoop_update`, docs/aufsicht.md).
/// Wird erst nach „Freigeben“ angewendet; nie „Immer erlauben“.
nonisolated struct ScoopUpdate: Codable, Hashable, Sendable {
    var targetId: String?
    var targetName: String
    var targetLabel: String?
    /// faehigkeit | gedaechtnis | anweisungen | routine_modell
    var art: String
    /// z. B. „Neue Fähigkeit „Wochenbericht““
    var label: String?
    var reason: String?
    var before: String?
    var after: String
    /// Text darf vor dem Freigeben bearbeitet werden (`edits.after`)
    var editable: Bool
    /// pending | applied | declined | failed
    var status: String
    var error: String?
    var edited: Bool?
    var skillName: String?
    var routineTitle: String?
    /// anweisungen: ergaenzen | ersetzen
    var mode: String?

    init(targetId: String? = nil, targetName: String, targetLabel: String? = nil, art: String, label: String? = nil,
         reason: String? = nil, before: String? = nil, after: String, editable: Bool = true, status: String = "pending") {
        self.targetId = targetId; self.targetName = targetName; self.targetLabel = targetLabel; self.art = art
        self.label = label; self.reason = reason; self.before = before; self.after = after; self.editable = editable
        self.status = status
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        targetId = try? c.decodeIfPresent(String.self, forKey: .targetId)
        targetName = ((try? c.decodeIfPresent(String.self, forKey: .targetName)) ?? nil) ?? "Scoop"
        targetLabel = try? c.decodeIfPresent(String.self, forKey: .targetLabel)
        art = ((try? c.decodeIfPresent(String.self, forKey: .art)) ?? nil) ?? ""
        label = try? c.decodeIfPresent(String.self, forKey: .label)
        reason = try? c.decodeIfPresent(String.self, forKey: .reason)
        before = try? c.decodeIfPresent(String.self, forKey: .before)
        after = ((try? c.decodeIfPresent(String.self, forKey: .after)) ?? nil) ?? ""
        editable = ((try? c.decodeIfPresent(Bool.self, forKey: .editable)) ?? nil) ?? false
        status = ((try? c.decodeIfPresent(String.self, forKey: .status)) ?? nil) ?? "pending"
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        edited = try? c.decodeIfPresent(Bool.self, forKey: .edited)
        skillName = try? c.decodeIfPresent(String.self, forKey: .skillName)
        routineTitle = try? c.decodeIfPresent(String.self, forKey: .routineTitle)
        mode = try? c.decodeIfPresent(String.self, forKey: .mode)
    }

    /// Lesbare Art der Änderung
    var artTitle: String {
        switch art {
        case "faehigkeit": String(localized: "Fähigkeit")
        case "gedaechtnis": String(localized: "Gedächtnis")
        case "anweisungen": String(localized: "Anweisungen", comment: "Art einer Scoop-Änderung: Anweisungen (Prompt)")
        case "routine_modell": String(localized: "Routine-Modell")
        default: String(localized: "Änderung")
        }
    }

    var artIcon: String {
        switch art {
        case "faehigkeit": "wand.and.stars"
        case "gedaechtnis": "brain.head.profile"
        case "anweisungen": "text.quote"
        case "routine_modell": "cpu"
        default: "sparkles"
        }
    }
}

/// v1.22: Optionen des Aufgaben-Chips im Eingabefeld (geplanter Start, Modell; `nil` = sofort bzw. wie Scoop).
nonisolated struct TaskOptions: Codable, Hashable, Sendable {
    var model: String?
    var scheduledAt: Date?
    /// Nur sammeln (Board-Spalte „Offen“, Server 1.23)
    var backlog: Bool?
    /// v1.29: Bereich am Mac nur für diese Aufgabe (`nil` = wie Scoop)
    var access: TaskAccessChoice?

    var isEmpty: Bool { model == nil && scheduledAt == nil && backlog != true && access == nil }
}

// MARK: - Rechner-Zugriff (Server 1.29, docs/rechnerzugriff.md)

/// Rechte-Modus und Standard-Bereich eines Scoops (`computer_access` im Bot-JSON des Admins).
nonisolated struct ScoopAccess: Codable, Hashable, Sendable {
    var mode: String = AccessMode.auto.rawValue
    var scope: String = AccessScope.workspace.rawValue
    var folders: [String] = []
    var modeLabel: String?
    var scopeLabel: String?

    init(mode: String = AccessMode.auto.rawValue, scope: String = AccessScope.workspace.rawValue, folders: [String] = []) {
        self.mode = mode; self.scope = scope; self.folders = folders
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = ((try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil) ?? AccessMode.auto.rawValue
        scope = ((try? c.decodeIfPresent(String.self, forKey: .scope)) ?? nil) ?? AccessScope.workspace.rawValue
        folders = ((try? c.decodeIfPresent([String].self, forKey: .folders)) ?? nil) ?? []
        modeLabel = (try? c.decodeIfPresent(String.self, forKey: .modeLabel)) ?? nil
        scopeLabel = (try? c.decodeIfPresent(String.self, forKey: .scopeLabel)) ?? nil
    }

    var accessMode: AccessMode { AccessMode(rawValue: mode) ?? .auto }
    var accessScope: AccessScope { AccessScope(rawValue: scope) ?? .workspace }

    /// „Projektordner (App, Website)“
    var scopeText: String { accessScope.text(folders: folders) }
}

/// Wie viel ein Scoop am Rechner ohne Rückfrage darf (Bezeichnungen genau so wie auf dem Server).
nonisolated enum AccessMode: String, CaseIterable, Identifiable, Sendable {
    case ask, auto, full

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ask: String(localized: "Immer genehmigen")
        case .auto: String(localized: "Automatisch", comment: "Rechner-Zugriffsmodus")
        case .full: String(localized: "Vollzugriff")
        }
    }

    var icon: String {
        switch self {
        case .ask: "hand.raised"
        case .auto: "wand.and.stars"
        case .full: "bolt.shield"
        }
    }

    var detail: String {
        switch self {
        case .ask: String(localized: "Lesen ist frei. Alles, was etwas verändert, fragt vorher mit einer Freigabe-Karte.")
        case .auto: String(localized: "Arbeitet im Bereich frei. Riskantes fragt vorher: Löschen außerhalb, git push, Installationen, sudo, Systemeinstellungen, Uploads.")
        case .full: String(localized: "Keine Rückfragen für lokale Arbeit am Rechner. sudo und Passwörter nie ohne dich.")
        }
    }
}

/// Wo ein Scoop am Mac arbeiten darf.
nonisolated enum AccessScope: String, CaseIterable, Identifiable, Sendable {
    case workspace, projects, home

    var id: String { rawValue }

    var title: String {
        switch self {
        case .workspace: String(localized: "Nur Arbeitsordner")
        case .projects: String(localized: "Projektordner")
        case .home: String(localized: "Überall")
        }
    }

    var icon: String {
        switch self {
        case .workspace: "folder"
        case .projects: "folder.badge.gearshape"
        case .home: "house"
        }
    }

    var detail: String {
        switch self {
        case .workspace: String(localized: "Nur sein Ordner im Arbeitsordner.")
        case .projects: String(localized: "Zusätzlich die gewählten Ordner, mit deinem echten Home (Git, SSH, gh funktionieren).")
        case .home: String(localized: "Dein ganzes Home, mit deinem echten Home und PATH.")
        }
    }

    func text(folders: [String]) -> String {
        guard self == .projects, !folders.isEmpty else { return title }
        let names = folders.prefix(2).map { ($0 as NSString).lastPathComponent }
        return "\(title) (\(names.joined(separator: ", "))\(folders.count > 2 ? " …" : ""))"
    }
}

/// Gewählter Bereich einer Aufgabe (`access` bei POST/PATCH /api/tasks und in den Eingabefeld-Optionen).
/// Leer (`scope == nil`) heißt „wie Scoop“.
nonisolated struct TaskAccessChoice: Codable, Hashable, Sendable {
    var scope: String?
    var folders: [String]?

    static let sameAsScoop = TaskAccessChoice(scope: nil, folders: nil)

    var accessScope: AccessScope? { scope.flatMap(AccessScope.init(rawValue:)) }
}

/// Login-Formular einer Freigabe mit `meta.kind == "vault"` (v1.10). Das Passwort kommt nie vom Server.
nonisolated struct VaultForm: Codable, Hashable, Sendable {
    var title: String
    var url: String?
    var domain: String?
    var username: String?
    /// pending | saved | declined
    var status: String
    var vaultId: String?

    init(title: String, url: String? = nil, domain: String? = nil, username: String? = nil,
         status: String = "pending", vaultId: String? = nil) {
        self.title = title; self.url = url; self.domain = domain; self.username = username
        self.status = status; self.vaultId = vaultId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = (try? c.decodeIfPresent(String.self, forKey: .title)) ?? "Login"
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        domain = try? c.decodeIfPresent(String.self, forKey: .domain)
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "pending"
        vaultId = try? c.decodeIfPresent(String.self, forKey: .vaultId)
    }

    /// Anzeige der Webseite: Domain, sonst Host der URL
    var site: String? {
        if let domain, !domain.isEmpty { return domain }
        return url.flatMap { URL(string: $0)?.host() }
    }
}

/// Eingaben der Tresor-Karte beim Speichern (`edits`). Das Passwort wird nur hier und nur einmal übertragen.
nonisolated struct VaultEdits: Encodable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var username: String?
    var password: String

    /// Nie das Passwort ausgeben (auch nicht versehentlich über `print`/Logs)
    var description: String { "VaultEdits(username: \(username ?? "–"), password: •••)" }
    var debugDescription: String { description }
}

/// Mail-Entwurf einer Freigabe mit `meta.kind == "mail"` (v1.9).
nonisolated struct MailDraft: Codable, Hashable, Sendable {
    var app: String?
    /// Name (alias) des Gmail-Kontos
    var account: String?
    var accountEmail: String?
    var to: [String]
    var cc: [String]
    var subject: String
    var body: String
    /// gesetzt = Antwort in einem bestehenden Verlauf (Betreff nur Anzeige)
    var threadId: String?
    /// draft | sending | sent | failed | discarded
    var status: String
    var error: String?
    var sentAt: Date?

    var isReply: Bool { threadId != nil }

    init(app: String? = "gmail", account: String?, accountEmail: String?, to: [String], cc: [String] = [],
         subject: String, body: String, threadId: String? = nil, status: String = "draft",
         error: String? = nil, sentAt: Date? = nil) {
        self.app = app; self.account = account; self.accountEmail = accountEmail; self.to = to; self.cc = cc
        self.subject = subject; self.body = body; self.threadId = threadId; self.status = status
        self.error = error; self.sentAt = sentAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        account = try? c.decodeIfPresent(String.self, forKey: .account)
        accountEmail = try? c.decodeIfPresent(String.self, forKey: .accountEmail)
        to = (try? c.decodeIfPresent([String].self, forKey: .to)) ?? []
        cc = (try? c.decodeIfPresent([String].self, forKey: .cc)) ?? []
        subject = (try? c.decodeIfPresent(String.self, forKey: .subject)) ?? ""
        body = (try? c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        threadId = try? c.decodeIfPresent(String.self, forKey: .threadId)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "draft"
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        sentAt = try? c.decodeIfPresent(Date.self, forKey: .sentAt)
    }
}

/// Bezug einer Antwort (`meta.reply_to`, API v1.15): zitierte Nachricht desselben Chats.
nonisolated struct ReplyRef: Codable, Hashable, Sendable {
    var id: String
    /// `user` oder `bot`
    var role: String?
    /// Scoop-ID bzw. Konto-ID der Person (optional)
    var authorId: String?
    var authorName: String?
    /// Einzeiliger Auszug (≤ 200 Zeichen)
    var text: String?

    init(id: String, role: String? = nil, authorId: String? = nil, authorName: String? = nil, text: String? = nil) {
        self.id = id; self.role = role; self.authorId = authorId; self.authorName = authorName; self.text = text
    }
}

nonisolated struct Message: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var botId: String
    var role: MessageRole
    var text: String
    var createdAt: Date
    var meta: MessageMeta
    /// Nur lokal: optimistisch angezeigte Nachricht, die noch gesendet wird bzw. fehlgeschlagen ist.
    var localState: LocalState?

    nonisolated enum LocalState: String, Codable, Hashable, Sendable { case sending, failed }

    private enum CodingKeys: String, CodingKey { case id, botId, role, text, createdAt, meta, authorUserId, authorName }

    init(id: String, botId: String, role: MessageRole, text: String, createdAt: Date, meta: MessageMeta = MessageMeta()) {
        self.id = id; self.botId = botId; self.role = role; self.text = text; self.createdAt = createdAt; self.meta = meta
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        botId = try c.decode(String.self, forKey: .botId)
        role = try c.decode(MessageRole.self, forKey: .role)
        text = (try c.decodeIfPresent(String.self, forKey: .text)) ?? ""
        createdAt = (try c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? Date()
        meta = (try? c.decodeIfPresent(MessageMeta.self, forKey: .meta)) ?? MessageMeta()
        // Absender (geteilte Scoops) darf auch neben `meta` stehen
        if meta.authorUserId == nil { meta.authorUserId = try? c.decodeIfPresent(String.self, forKey: .authorUserId) }
        if meta.authorName == nil { meta.authorName = try? c.decodeIfPresent(String.self, forKey: .authorName) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(botId, forKey: .botId)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(meta, forKey: .meta)
    }

    var isRunning: Bool { role == .status && meta.state == "running" }
    /// Chat-ID (Bot- oder Gruppen-ID). Das Feld heißt laut API weiter `bot_id`.
    var chatId: String { botId }
    var isPendingApproval: Bool { role == .approval && meta.state == "pending" }

    /// Kurzer Vorschautext für die Seitenleiste.
    var previewText: String {
        switch role {
        case .status:
            if let last = meta.lines?.last { return last }
            return meta.state == "running" ? String(localized: "Arbeitet …")
                : String(localized: "Fertig", comment: "Lauf eines Scoops beendet")
        case .approval:
            let title = meta.title ?? text
            return String(localized: "Freigabe: \(title)")
        default:
            return MarkdownText.plain(text)
        }
    }
}

nonisolated struct Memory: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var botId: String?
    var kind: String
    var text: String
    var createdAt: Date?
}

nonisolated struct Routine: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var botId: String
    var kind: String
    var title: String
    var schedule: String?
    var scheduleText: String?
    var prompt: String?
    var enabled: Bool
    var nextRun: Date?
    var lastRun: Date?
    /// v1.20: eigenes Modell der Routine, `nil` = Modell des Scoops
    var model: String? = nil
}

/// Dauerhafte Freigabe eines Scoops (v1.20, „Immer erlauben“): Der Server erteilt Freigaben mit diesem Schlüssel automatisch.
nonisolated struct StandingApproval: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var botId: String
    var key: String
    var label: String
    /// freigabe | mail | t3 | t3_send | apple
    var kind: String?
    var createdAt: Date?

    var symbol: String {
        switch kind {
        case "mail": "envelope"
        case "t3", "t3_send": "hammer"
        case "apple": "house"
        default: "checkmark.seal"
        }
    }
}

/// Gruppenchat (v1.1): 2 bis 6 Scoops.
nonisolated struct ChatGroup: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var memberIds: [String]
    var pinned: Bool
    var section: String?
    var createdAt: Date?
    var lastMessage: Message?
    var unread: Int
    var busy: Bool
    var busyIds: [String]
    /// Wartet auf den Nutzer (siehe `Bot.waiting`)
    var waiting: Bool = false
    /// App 1.3: Stummschaltung für mich (siehe `Bot.mute`)
    var mute: ChatMute?

    init(id: String, name: String, memberIds: [String], pinned: Bool = false, section: String? = nil,
         createdAt: Date? = nil, lastMessage: Message? = nil, unread: Int = 0, busy: Bool = false, busyIds: [String] = []) {
        self.id = id; self.name = name; self.memberIds = memberIds; self.pinned = pinned; self.section = section
        self.createdAt = createdAt; self.lastMessage = lastMessage; self.unread = unread; self.busy = busy; self.busyIds = busyIds
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? "Gruppe"
        memberIds = (try? c.decodeIfPresent([String].self, forKey: .memberIds)) ?? []
        pinned = (try? c.decodeIfPresent(Bool.self, forKey: .pinned)) ?? false
        section = try? c.decodeIfPresent(String.self, forKey: .section)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        lastMessage = try? c.decodeIfPresent(Message.self, forKey: .lastMessage)
        unread = (try? c.decodeIfPresent(Int.self, forKey: .unread)) ?? 0
        busy = (try? c.decodeIfPresent(Bool.self, forKey: .busy)) ?? false
        busyIds = (try? c.decodeIfPresent([String].self, forKey: .busyIds)) ?? []
        waiting = ((try? c.decodeIfPresent(Bool.self, forKey: .waiting)) ?? nil) ?? false
        mute = try? c.decodeIfPresent(ChatMute.self, forKey: .mute)
    }

    var isMuted: Bool { mute?.isActive() ?? false }

    var trimmedSection: String? {
        guard let s = section?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    static func isGroupID(_ id: String) -> Bool { id.hasPrefix("g_") }
}

/// Datei oder Link in der Bibliothek eines Chats (v1.1).
nonisolated struct LibraryFile: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var chatId: String
    var authorId: String?
    /// datei | bild | link
    var kind: String
    var name: String
    var mime: String?
    var size: Int?
    var url: String?
    var note: String?
    var createdAt: Date?
    var downloadUrl: String?

    var isLink: Bool { kind == "link" }
    var isImage: Bool { kind == "bild" || (mime ?? "").hasPrefix("image/") }

    var symbolName: String {
        if isLink { return "link" }
        if isImage { return "photo" }
        let m = mime ?? "", ext = (name as NSString).pathExtension.lowercased()
        if m == "application/pdf" || ext == "pdf" { return "doc.richtext" }
        if m.hasPrefix("text/") || ["md", "txt", "csv", "json"].contains(ext) { return "doc.plaintext" }
        if ["xlsx", "xls", "numbers"].contains(ext) { return "tablecells" }
        if ["zip"].contains(ext) { return "doc.zipper" }
        if m.hasPrefix("audio/") { return "waveform" }
        if m.hasPrefix("video/") { return "film" }
        return "doc"
    }

    var sizeText: String? {
        guard let size else { return nil }
        return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
    }
}

// MARK: - Apps verbinden (v1.8)

/// Konto einer verbundenen App (Composio).
nonisolated struct ConnectedAccount: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var app: String?
    var alias: String?
    var email: String?
    /// active | expired | failed | initiated | initializing
    var status: String
    var createdAt: Date?

    init(id: String, app: String?, alias: String?, email: String?, status: String, createdAt: Date? = nil) {
        self.id = id; self.app = app; self.alias = alias; self.email = email; self.status = status; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        app = try? c.decodeIfPresent(String.self, forKey: .app)
        alias = try? c.decodeIfPresent(String.self, forKey: .alias)
        email = try? c.decodeIfPresent(String.self, forKey: .email)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "initiated"
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
    }

    var displayName: String {
        guard let a = alias?.trimmingCharacters(in: .whitespaces), !a.isEmpty else { return String(localized: "Standard", comment: "Verbundenes Konto ohne eigenen Namen") }
        return a
    }

    enum State { case active, problem, pending }
    var state: State {
        switch status {
        case "active": .active
        case "expired", "failed": .problem
        default: .pending
        }
    }
}

nonisolated struct ConnectableApp: Codable, Hashable, Identifiable, Sendable {
    var slug: String
    var name: String
    var detail: String?
    var symbol: String?
    var logoUrl: String?
    var canAdd: Bool
    var accounts: [ConnectedAccount]
    var id: String { slug }

    init(slug: String, name: String, detail: String?, symbol: String?, logoUrl: String? = nil, canAdd: Bool = true,
         accounts: [ConnectedAccount] = []) {
        self.slug = slug; self.name = name; self.detail = detail; self.symbol = symbol; self.logoUrl = logoUrl
        self.canAdd = canAdd; self.accounts = accounts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slug = try c.decode(String.self, forKey: .slug)
        name = (try? c.decode(String.self, forKey: .name)) ?? slug
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        logoUrl = try? c.decodeIfPresent(String.self, forKey: .logoUrl)
        canAdd = (try? c.decodeIfPresent(Bool.self, forKey: .canAdd)) ?? true
        accounts = (try? c.decodeIfPresent([ConnectedAccount].self, forKey: .accounts)) ?? []
    }
}

nonisolated struct BuiltinConnection: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var detail: String?
    var symbol: String?
    /// ok | error | off
    var status: String
    var tools: Int?

    init(id: String, name: String, detail: String?, symbol: String?, status: String, tools: Int? = nil) {
        self.id = id; self.name = name; self.detail = detail; self.symbol = symbol; self.status = status; self.tools = tools
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? id
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        symbol = try? c.decodeIfPresent(String.self, forKey: .symbol)
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "off"
        tools = try? c.decodeIfPresent(Int.self, forKey: .tools)
    }
}

nonisolated struct ConnectionsOverview: Codable, Sendable {
    var maxPerApp: Int
    var apps: [ConnectableApp]
    var builtin: [BuiltinConnection]
    /// v1.35: eigene MCP-Server (nil = älterer Server ohne die Funktion)
    var customMcp: [CustomMCPServer]? = nil

    init(maxPerApp: Int, apps: [ConnectableApp], builtin: [BuiltinConnection]) {
        self.maxPerApp = maxPerApp; self.apps = apps; self.builtin = builtin
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        maxPerApp = (try? c.decodeIfPresent(Int.self, forKey: .maxPerApp)) ?? 10
        apps = (try? c.decodeIfPresent([ConnectableApp].self, forKey: .apps)) ?? []
        builtin = (try? c.decodeIfPresent([BuiltinConnection].self, forKey: .builtin)) ?? []
        customMcp = try? c.decodeIfPresent([CustomMCPServer].self, forKey: .customMcp)
    }
}

/// v1.35: Eigener MCP-Server (docs/mcp.md). Ohne Geheimnisse: Tokens bleiben im Schlüsselbund des Servers.
nonisolated struct CustomMCPServer: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    /// remote | stdio
    var kind: String
    /// none | token | oauth
    var auth: String
    /// ok | error | login
    var status: String
    var error: String?
    var tools: Int
    var writeTools: Int?
    var url: String?
    var command: String?
    var header: String?
    var envKeys: [String]?

    init(id: String, name: String, kind: String = "remote", auth: String = "none", status: String = "ok",
         error: String? = nil, tools: Int = 0, writeTools: Int? = nil, url: String? = nil, command: String? = nil,
         header: String? = nil, envKeys: [String]? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.auth = auth; self.status = status; self.error = error
        self.tools = tools; self.writeTools = writeTools; self.url = url; self.command = command; self.header = header
        self.envKeys = envKeys
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? id
        kind = (try? c.decodeIfPresent(String.self, forKey: .kind)) ?? "remote"
        auth = (try? c.decodeIfPresent(String.self, forKey: .auth)) ?? "none"
        status = (try? c.decodeIfPresent(String.self, forKey: .status)) ?? "error"
        error = try? c.decodeIfPresent(String.self, forKey: .error)
        tools = (try? c.decodeIfPresent(Int.self, forKey: .tools)) ?? 0
        writeTools = try? c.decodeIfPresent(Int.self, forKey: .writeTools)
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        command = try? c.decodeIfPresent(String.self, forKey: .command)
        header = try? c.decodeIfPresent(String.self, forKey: .header)
        envKeys = try? c.decodeIfPresent([String].self, forKey: .envKeys)
    }

    /// Kurze Zeile unter dem Namen: Host bzw. Befehl
    var subtitle: String {
        if kind == "stdio" { return command ?? String(localized: "Lokaler Befehl") }
        return url.flatMap { URL(string: $0)?.host() } ?? (url ?? "")
    }
}

nonisolated struct ConnectionLink: Codable, Sendable {
    var url: String
    var accountId: String
    /// Ab Server 1.25 (z. B. Notion direkt): Rücksprung-Schema, auf das die Anmeldung im Browser wartet. Die
    /// Rücksprung-Adresse geht dann an `POST /api/connections/oauth/callback`. Ohne: Composio, Status-Abfrage.
    var callbackScheme: String? = nil
}

/// Bereich in der Seitenleiste (v1.6)
nonisolated struct SidebarSection: Codable, Hashable, Identifiable, Sendable {
    var name: String
    var collapsed: Bool

    var id: String { name }

    init(name: String, collapsed: Bool = false) { self.name = name; self.collapsed = collapsed }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        collapsed = (try? c.decodeIfPresent(Bool.self, forKey: .collapsed)) ?? false
    }
}

nonisolated struct SectionList: Codable, Sendable {
    var sections: [SidebarSection]
}

/// Initiative des Haupt-Scoops (v1.4)
nonisolated struct InitiativeSettings: Codable, Hashable, Sendable {
    var enabled: Bool
    var times: [String]
    var quietStart: String?
    var quietEnd: String?
    var primaryBotId: String?

    init(enabled: Bool, times: [String], quietStart: String?, quietEnd: String?, primaryBotId: String?) {
        self.enabled = enabled; self.times = times; self.quietStart = quietStart; self.quietEnd = quietEnd
        self.primaryBotId = primaryBotId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        times = (try? c.decodeIfPresent([String].self, forKey: .times)) ?? []
        quietStart = try? c.decodeIfPresent(String.self, forKey: .quietStart)
        quietEnd = try? c.decodeIfPresent(String.self, forKey: .quietEnd)
        primaryBotId = try? c.decodeIfPresent(String.self, forKey: .primaryBotId)
    }
}

/// Fähigkeit (Skill) eines Scoops oder aller Scoops (v1.4)
nonisolated struct Skill: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var botId: String?
    var name: String
    var description: String?
    var steps: String?
    var uses: Int
    var lastUsed: Date?
    var createdAt: Date?
    var updatedAt: Date?

    init(id: String, botId: String?, name: String, description: String?, steps: String?, uses: Int = 0,
         lastUsed: Date? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id; self.botId = botId; self.name = name; self.description = description; self.steps = steps
        self.uses = uses; self.lastUsed = lastUsed; self.createdAt = createdAt; self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        botId = try? c.decodeIfPresent(String.self, forKey: .botId)
        name = (try? c.decode(String.self, forKey: .name)) ?? String(localized: "Fähigkeit")
        description = try? c.decodeIfPresent(String.self, forKey: .description)
        steps = try? c.decodeIfPresent(String.self, forKey: .steps)
        uses = (try? c.decodeIfPresent(Int.self, forKey: .uses)) ?? 0
        lastUsed = try? c.decodeIfPresent(Date.self, forKey: .lastUsed)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }

    var isShared: Bool { botId == nil }
}

/// Tresor-Eintrag (Login). Passwörter kommen nie vom Server zurück (v1.4).
nonisolated struct VaultEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var title: String
    var url: String?
    var domain: String?
    var username: String?
    var note: String?
    var hasPassword: Bool
    var lastUsed: Date?
    var createdAt: Date?
    var updatedAt: Date?

    init(id: String, title: String, url: String?, domain: String?, username: String?, note: String?,
         hasPassword: Bool, lastUsed: Date? = nil, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id; self.title = title; self.url = url; self.domain = domain; self.username = username
        self.note = note; self.hasPassword = hasPassword; self.lastUsed = lastUsed; self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = (try? c.decode(String.self, forKey: .title)) ?? "Login"
        url = try? c.decodeIfPresent(String.self, forKey: .url)
        domain = try? c.decodeIfPresent(String.self, forKey: .domain)
        username = try? c.decodeIfPresent(String.self, forKey: .username)
        note = try? c.decodeIfPresent(String.self, forKey: .note)
        hasPassword = (try? c.decodeIfPresent(Bool.self, forKey: .hasPassword)) ?? false
        lastUsed = try? c.decodeIfPresent(Date.self, forKey: .lastUsed)
        createdAt = try? c.decodeIfPresent(Date.self, forKey: .createdAt)
        updatedAt = try? c.decodeIfPresent(Date.self, forKey: .updatedAt)
    }
}

nonisolated struct ComputerState: Codable, Hashable, Sendable {
    var state: String
    var botId: String?
    /// Bildschirmgröße in Punkten (v1.1), gleiches Koordinatensystem wie screen.jpg
    var width: Double?
    var height: Double?
    /// Rechner, zu dem der Zustand gehört (v1.11); fehlt bei älteren Servern → Bot-Rechner
    var nodeId: String?
    /// Nur bei Scoops-Connect-Rechnern (v1.11)
    var online: Bool?
    var paused: Bool?

    init(state: String, botId: String?, width: Double? = nil, height: Double? = nil, nodeId: String? = nil,
         online: Bool? = nil, paused: Bool? = nil) {
        self.state = state; self.botId = botId; self.width = width; self.height = height
        self.nodeId = nodeId; self.online = online; self.paused = paused
    }

    static let unknown = ComputerState(state: "asleep", botId: nil)

    /// Rechner-ID, ältere Server ohne `node_id` → Bot-Rechner
    var node: String { nodeId ?? ComputerNode.builtinID }

    var isUserControlling: Bool { state == "user" }
    var screenSize: CGSize { CGSize(width: width ?? 1024, height: height ?? 768) }

    var displayText: String {
        if paused == true && state != "busy" && state != "user" { return String(localized: "Pausiert", comment: "Zustand: angehalten (Rechner, Timer)") }
        if online == false { return String(localized: "Offline", comment: "Zustand eines Rechners") }
        switch state {
        case "awake": return String(localized: "Wach", comment: "Zustand eines Rechners")
        case "busy": return String(localized: "Arbeitet")
        case "asleep": return String(localized: "Schläft", comment: "Zustand eines Rechners")
        case "user": return String(localized: "Du steuerst")
        default: return state.capitalized
        }
    }
}

/// Ein Rechner, an dem Scoops arbeiten (v1.11, GET /api/nodes): der eingebaute Bot-Rechner (`vm`) oder ein
/// über Scoops Connect angeschlossener Mac.
nonisolated struct ComputerNode: Codable, Hashable, Identifiable, Sendable {
    static let builtinID = "vm"

    var id: String
    var name: String
    /// `direct` (Mac wird direkt gesteuert) oder `vm` (abgeschirmte VM)
    var mode: String
    var builtin: Bool
    var online: Bool
    var paused: Bool
    var os: String?
    var appVersion: String?
    var lastSeen: Date?
    var screen: Size?
    /// `awake|busy|user|asleep` wie bei ComputerState
    var state: String
    var botId: String?
    var botName: String?
    var createdAt: Date?

    nonisolated struct Size: Codable, Hashable, Sendable {
        var width: Double
        var height: Double
    }

    init(id: String, name: String, mode: String = "direct", builtin: Bool = false, online: Bool = true,
         paused: Bool = false, os: String? = nil, appVersion: String? = nil, lastSeen: Date? = nil, screen: Size? = nil,
         state: String = "awake", botId: String? = nil, botName: String? = nil, createdAt: Date? = nil) {
        self.id = id; self.name = name; self.mode = mode; self.builtin = builtin; self.online = online
        self.paused = paused; self.os = os; self.appVersion = appVersion; self.lastSeen = lastSeen; self.screen = screen
        self.state = state; self.botId = botId; self.botName = botName; self.createdAt = createdAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = (try? c.decode(String.self, forKey: .name)) ?? String(localized: "Rechner", comment: "Rechner (Computer)")
        mode = ((try? c.decodeIfPresent(String.self, forKey: .mode)) ?? nil) ?? "direct"
        builtin = ((try? c.decodeIfPresent(Bool.self, forKey: .builtin)) ?? nil) ?? (id == Self.builtinID)
        online = ((try? c.decodeIfPresent(Bool.self, forKey: .online)) ?? nil) ?? false
        paused = ((try? c.decodeIfPresent(Bool.self, forKey: .paused)) ?? nil) ?? false
        os = (try? c.decodeIfPresent(String.self, forKey: .os)) ?? nil
        appVersion = (try? c.decodeIfPresent(String.self, forKey: .appVersion)) ?? nil
        lastSeen = (try? c.decodeIfPresent(Date.self, forKey: .lastSeen)) ?? nil
        screen = (try? c.decodeIfPresent(Size.self, forKey: .screen)) ?? nil
        state = ((try? c.decodeIfPresent(String.self, forKey: .state)) ?? nil) ?? "asleep"
        botId = (try? c.decodeIfPresent(String.self, forKey: .botId)) ?? nil
        botName = (try? c.decodeIfPresent(String.self, forKey: .botName)) ?? nil
        createdAt = (try? c.decodeIfPresent(Date.self, forKey: .createdAt)) ?? nil
    }

    var isBuiltin: Bool { builtin || id == Self.builtinID }
    /// Scoops können gerade daran arbeiten
    var isAvailable: Bool { online && !paused }

    /// Kurzer Status für Listen und Auswahl
    var statusText: String {
        if !online {
            return isBuiltin ? String(localized: "Schläft", comment: "Zustand eines Rechners")
                : String(localized: "Offline", comment: "Zustand eines Rechners")
        }
        if paused { return String(localized: "Pausiert", comment: "Zustand: angehalten (Rechner, Timer)") }
        switch state {
        case "busy": return botName.map { String(localized: "\($0) arbeitet") } ?? String(localized: "Arbeitet")
        case "user": return String(localized: "Du steuerst")
        default: return String(localized: "Bereit", comment: "Zustand eines Rechners")
        }
    }

    var modeText: String {
        if isBuiltin { return String(localized: "Eingebaut · VM auf dem Server") }
        return mode == "vm" ? String(localized: "Abgeschirmte VM") : String(localized: "Mac direkt gesteuert")
    }

    var symbol: String {
        if isBuiltin { return "cube.transparent" }
        return mode == "vm" ? "macwindow.on.rectangle" : "desktopcomputer"
    }

    /// Bildschirmgröße wie bei ComputerState (Standard 1024×768)
    var screenSize: CGSize { CGSize(width: screen?.width ?? 1024, height: screen?.height ?? 768) }

    /// Zustand für die Bildschirm-Ansicht aus dem Listeneintrag
    var computerState: ComputerState {
        ComputerState(state: state, botId: botId, width: screen?.width, height: screen?.height, nodeId: id,
                      online: isBuiltin ? nil : online, paused: isBuiltin ? nil : paused)
    }
}

/// Kopplungscode für einen neuen Rechner (POST /api/nodes/pair).
nonisolated struct NodePairing: Codable, Hashable, Sendable {
    var code: String
    var expiresAt: Date
    var ttlSeconds: Int?
    var serverUrl: String?
}

/// Eingabe auf dem Bot-Rechner während der Übernahme (POST /api/computer/input).
nonisolated struct ComputerInput: Encodable, Sendable {
    var type: String
    var x: Int?
    var y: Int?
    var x2: Int?
    var y2: Int?
    var modifiers: String?
    var direction: String?
    var amount: Int?
    var text: String?
    var `repeat`: Int?

    static func click(_ p: CGPoint, double: Bool = false, right: Bool = false, modifiers: String? = nil) -> ComputerInput {
        ComputerInput(type: right ? "right_click" : (double ? "double_click" : "click"),
                      x: Int(p.x.rounded()), y: Int(p.y.rounded()), modifiers: modifiers)
    }
    static func drag(from a: CGPoint, to b: CGPoint) -> ComputerInput {
        ComputerInput(type: "drag", x: Int(a.x.rounded()), y: Int(a.y.rounded()), x2: Int(b.x.rounded()), y2: Int(b.y.rounded()))
    }
    static func scroll(at p: CGPoint, direction: String, amount: Int) -> ComputerInput {
        ComputerInput(type: "scroll", x: Int(p.x.rounded()), y: Int(p.y.rounded()), direction: direction, amount: max(1, amount))
    }
    static func type(_ text: String) -> ComputerInput { ComputerInput(type: "type", text: text) }
    static func key(_ name: String) -> ComputerInput { ComputerInput(type: "key", text: name) }
}

nonisolated struct Health: Codable, Sendable {
    var ok: Bool
    var version: String?
    var userName: String?
    /// App 1.3: Server kann die Suche über alle Chats (`GET /api/search`); fehlt bei älteren Servern
    var search: Bool? = nil
    /// App 1.3: Server kann eigene Nachrichten bearbeiten (`PATCH /api/messages/{id}`)
    var messageEdit: Bool? = nil
    /// App 1.3: Server kennt die Seite „Heute“ mit dem Freigaben-Postfach (`GET /api/today`)
    var today: Bool? = nil
    /// App 1.3: Server kann Chats stummschalten (`PUT /api/chats/{id}/mute`). Die App erkennt das auch am Feld
    /// `mute` im Scoop-JSON; das Health-Feld braucht vor allem der Demo-Modus.
    var mute: Bool? = nil
    /// App 1.3: Ruhezeiten (`/api/settings/quiet-hours`)
    var quietHours: Bool? = nil
    /// App 1.3: höchste lesbare Formatversion von Scoop-Vorlagen (`/api/templates/…`)
    var templates: Int? = nil
    /// Server 1.40: Archiv des Aufgaben-Boards leeren, archivierte einzeln löschen, automatisch nach X Tagen
    var taskArchiveCleanup: Bool? = nil
}

nonisolated struct Usage: Codable, Sendable {
    var todayUsd: Double
    var monthUsd: Double
    var byModel: [String: Double]
    /// Kosten pro Scoop (Server 1.14): Bot-ID → heute/Monat
    var byBot: [String: BotCost]

    nonisolated struct BotCost: Codable, Hashable, Sendable {
        var todayUsd: Double
        var monthUsd: Double

        init(todayUsd: Double, monthUsd: Double) { self.todayUsd = todayUsd; self.monthUsd = monthUsd }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            todayUsd = (try? c.decodeIfPresent(Double.self, forKey: .todayUsd)) ?? 0
            monthUsd = (try? c.decodeIfPresent(Double.self, forKey: .monthUsd)) ?? 0
        }
    }

    /// Läufe über KI-Abos (Server 1.30, docs/abos.md): ohne Betrag, getrennt von den API-Kosten
    var abo: AboUsage?

    nonisolated struct AboUsage: Codable, Hashable, Sendable {
        var todayRuns: Int
        var monthRuns: Int
        var byModel: [String: ModelRuns]

        nonisolated struct ModelRuns: Codable, Hashable, Sendable {
            var runs: Int
            var inputTokens: Int?
            var outputTokens: Int?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            todayRuns = (try? c.decodeIfPresent(Int.self, forKey: .todayRuns)) ?? 0
            monthRuns = (try? c.decodeIfPresent(Int.self, forKey: .monthRuns)) ?? 0
            byModel = (try? c.decodeIfPresent([String: ModelRuns].self, forKey: .byModel)) ?? [:]
        }
    }

    init(todayUsd: Double, monthUsd: Double, byModel: [String: Double], byBot: [String: BotCost] = [:]) {
        self.todayUsd = todayUsd; self.monthUsd = monthUsd; self.byModel = byModel; self.byBot = byBot
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todayUsd = (try c.decodeIfPresent(Double.self, forKey: .todayUsd)) ?? 0
        monthUsd = (try c.decodeIfPresent(Double.self, forKey: .monthUsd)) ?? 0
        byModel = (try c.decodeIfPresent([String: Double].self, forKey: .byModel)) ?? [:]
        byBot = (try? c.decodeIfPresent([String: BotCost].self, forKey: .byBot)) ?? [:]
        abo = try? c.decodeIfPresent(AboUsage.self, forKey: .abo)
    }
}

/// `GET /api/voice/live` (v1.13): Live-Sprechmodus mit OpenAI GPT-Live-1 über den Server.
nonisolated struct LiveVoiceInfo: Codable, Sendable, Equatable {
    nonisolated struct Voice: Codable, Sendable, Equatable, Identifiable, Hashable {
        var id: String
        var name: String
        var note: String?
    }
    var available: Bool
    var reason: String?
    var model: String?
    var defaultVoice: String?
    var voices: [Voice]
    var maxSeconds: Double?
    var idleSeconds: Double?
    var pricePerMinuteUsd: Double?

    static var unavailable: LiveVoiceInfo {
        LiveVoiceInfo(available: false, reason: String(localized: "Der Server kennt den Live-Sprechmodus noch nicht."),
                      model: nil, defaultVoice: nil, voices: [], maxSeconds: nil, idleSeconds: nil,
                      pricePerMinuteUsd: nil)
    }
}

/// Stimme eines Scoops (Feld `voice`): `live:<name>` (optional `|<Geräte-ID>` als Rückfall) = OpenAI-Live-Stimme,
/// `device` bzw. `device:<id>` = Gerätestimme
/// (offline). Leer oder eine alte Geräte-ID (vor v1.13) = Live mit der Standardstimme, Gerätestimme als Rückfall.
nonisolated struct VoiceChoice: Equatable, Sendable {
    /// Live-Stimme (nil = Gerätestimme gewählt)
    var live: String?
    /// Gerätestimme (Kennung) für „offline“ und als Rückfall
    var deviceID: String?

    init(live: String?, deviceID: String?) { self.live = live; self.deviceID = deviceID }

    init(_ raw: String?) {
        let v = (raw ?? "").trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("live:") {
            // „live:<name>|<Geräte-ID>“: Live-Stimme und eigene Rückfall-Stimme
            let parts = v.dropFirst(5).split(separator: "|", maxSplits: 1).map(String.init)
            live = parts.first ?? ""
            deviceID = parts.count > 1 && !parts[1].isEmpty ? parts[1] : nil
        } else if v == "device" {
            live = nil; deviceID = nil
        } else if v.hasPrefix("device:") {
            live = nil; deviceID = String(v.dropFirst(7))
        } else {
            live = ""  // Standardstimme des Servers
            deviceID = v.isEmpty ? nil : v
        }
    }

    var usesLive: Bool { live != nil }

    /// Wert für `PATCH /api/bots/{id}` → `voice`
    var raw: String {
        if let live {
            if live.isEmpty { return deviceID ?? "" }
            return "live:\(live)" + (deviceID.map { "|\($0)" } ?? "")
        }
        return deviceID.map { "device:\($0)" } ?? "device"
    }
}

nonisolated struct OKResponse: Codable, Sendable { var ok: Bool? }
nonisolated struct APIErrorBody: Codable, Sendable { var error: String }

// MARK: - Modelle (Claude) mit deutschen Hinweisen

/// Anbieter eines Modells.
nonisolated enum ModelProvider: String, CaseIterable, Identifiable, Sendable {
    case anthropic, openai
    var id: String { rawValue }
    /// Überschrift der Auswahl
    var title: String { self == .anthropic ? "Claude (Anthropic)" : "OpenAI" }
    /// Kurzes Kennzeichen (z. B. im Profil)
    var mark: String { self == .anthropic ? "Claude" : "OpenAI" }
}

/// Eingebaute Modellliste: nur noch Rückfall für Server vor 1.34 (ohne `GET /api/models`). Die Auswahl, Namen und
/// Hinweise kommen sonst aus dem Modellkatalog des Servers (`ModelCatalogStore`, docs/modelle.md).
nonisolated enum BotModel: String, CaseIterable, Identifiable, Sendable {
    case haiku = "claude-haiku-5-5"
    case sonnet = "claude-sonnet-5-5"
    case opus = "claude-opus-5-5"
    // OpenAI (v1.7), nach Stärke: Luna < Terra < Sol < Astra
    case luna = "gpt-6-luna"
    case terra = "gpt-6.1-terra"
    case sol = "gpt-6.1-sol"
    case astra = "gpt-6-astra"

    var id: String { rawValue }

    var provider: ModelProvider {
        switch self {
        case .haiku, .sonnet, .opus: .anthropic
        case .luna, .terra, .sol, .astra: .openai
        }
    }

    var displayName: String {
        switch self {
        case .haiku: "Haiku 5.5"
        case .sonnet: "Sonnet 5.5"
        case .opus: "Opus 5.5"
        case .luna: "GPT-6 Luna"
        case .terra: "GPT-6.1 Terra"
        case .sol: "GPT-6.1 Sol"
        case .astra: "GPT-6 Astra"
        }
    }

    var hint: String {
        switch self {
        case .haiku: String(localized: "Schnell & günstig")
        case .sonnet: String(localized: "Stärker")
        case .opus: String(localized: "Am stärksten, teuer")
        case .luna: String(localized: "Schnell & sehr günstig")
        case .terra: String(localized: "Ausgewogen & günstig")
        case .sol: String(localized: "Stark, Allrounder")
        case .astra: String(localized: "Am stärksten, teuer")
        }
    }

    static func models(of provider: ModelProvider) -> [BotModel] { allCases.filter { $0.provider == provider } }

    /// Wählbare Modelle eines Anbieters laut Katalog des Servers (Rückfall: eingebaute Liste)
    @MainActor static func choices(of provider: ModelProvider) -> [CatalogModel] {
        ModelCatalogStore.shared.catalog.selectable(of: provider)
    }

    /// Anzeigename: Katalog des Servers, sonst eingebaute Liste, sonst lesbar aus der Kennung („gpt-6.3-nova“ →
    /// „GPT-6.3 Nova“).
    @MainActor static func displayName(for raw: String) -> String {
        if let m = ModelCatalogStore.shared.catalog.models.first(where: { $0.id == raw }) { return m.label }
        return BotModel(rawValue: raw)?.displayName ?? prettyName(for: raw)
    }

    /// Anbieter-Kennzeichen für eine Kennung (auch unbekannte: „gpt-…“/„o…“ = OpenAI, „claude-…“ = Claude).
    @MainActor static func providerMark(for raw: String) -> String? {
        if let p = ModelCatalogStore.shared.catalog.model(raw)?.modelProvider { return p.mark }
        if let m = BotModel(rawValue: raw) { return m.provider.mark }
        if raw.hasPrefix("claude") { return ModelProvider.anthropic.mark }
        if raw.hasPrefix("gpt") || raw.hasPrefix("o") { return ModelProvider.openai.mark }
        return nil
    }

    /// Anbieter einer Kennung (Katalog, sonst Präfix)
    @MainActor static func provider(for raw: String) -> ModelProvider {
        ModelCatalogStore.shared.catalog.model(raw)?.modelProvider ?? (raw.hasPrefix("gpt") ? .openai : .anthropic)
    }
}

// MARK: - WebSocket-Ereignisse

nonisolated enum ServerEvent: Sendable {
    case messageCreated(Message)
    case messageUpdated(Message)
    /// App 1.3: Nachricht entfernt (Antwort auf die alte Fassung einer bearbeiteten Nachricht)
    case messageDeleted(id: String, chatId: String)
    case botCreated(Bot)
    case botUpdated(Bot)
    case botDeleted(id: String)
    case botTyping(chatId: String, botId: String, typing: Bool)
    case groupCreated(ChatGroup)
    case groupUpdated(ChatGroup)
    case groupDeleted(id: String)
    case sectionsUpdated([SidebarSection])
    case skillUpdated(Skill)
    case skillDeleted(id: String)
    case computerUpdated(ComputerState)
    case nodeUpdated(ComputerNode)
    case nodeDeleted(id: String)
    case routineUpdated(Routine)
    /// Server 1.34: neuer Modellkatalog (GET /api/models neu laden)
    case modelsUpdated
    /// v1.22: Aufgaben-Board
    case taskUpdated(BotTask)
    case taskDeleted(id: String)
    /// v1.18: Befehl an dieses Gerät (Home, Wecker, Standort); kommt über `EventSocket` mit eigenem Decoder
    case deviceCommand(AppleDeviceCommand)
    case pong
    case unknown(String)
}

nonisolated struct ServerEventEnvelope: Decodable, Sendable {
    let event: ServerEvent

    private enum Keys: String, CodingKey { case type, data }
    private struct IDOnly: Decodable { var id: String }
    private struct MessageRef: Decodable { var id: String; var botId: String }
    private struct Typing: Decodable { var botId: String; var chatId: String?; var typing: Bool }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "message.created": event = .messageCreated(try c.decode(Message.self, forKey: .data))
        case "message.updated": event = .messageUpdated(try c.decode(Message.self, forKey: .data))
        case "message.deleted":
            let ref = try c.decode(MessageRef.self, forKey: .data)
            event = .messageDeleted(id: ref.id, chatId: ref.botId)
        case "bot.created": event = .botCreated(try c.decode(Bot.self, forKey: .data))
        case "bot.updated": event = .botUpdated(try c.decode(Bot.self, forKey: .data))
        case "bot.deleted": event = .botDeleted(id: try c.decode(IDOnly.self, forKey: .data).id)
        case "bot.typing":
            let t = try c.decode(Typing.self, forKey: .data)
            event = .botTyping(chatId: t.chatId ?? t.botId, botId: t.botId, typing: t.typing)
        case "group.created": event = .groupCreated(try c.decode(ChatGroup.self, forKey: .data))
        case "group.updated": event = .groupUpdated(try c.decode(ChatGroup.self, forKey: .data))
        case "group.deleted": event = .groupDeleted(id: try c.decode(IDOnly.self, forKey: .data).id)
        case "sections.updated": event = .sectionsUpdated(try c.decode(SectionList.self, forKey: .data).sections)
        case "skill.updated": event = .skillUpdated(try c.decode(Skill.self, forKey: .data))
        case "skill.deleted": event = .skillDeleted(id: try c.decode(IDOnly.self, forKey: .data).id)
        case "computer.updated": event = .computerUpdated(try c.decode(ComputerState.self, forKey: .data))
        case "node.updated": event = .nodeUpdated(try c.decode(ComputerNode.self, forKey: .data))
        case "node.deleted": event = .nodeDeleted(id: try c.decode(IDOnly.self, forKey: .data).id)
        case "routine.updated": event = .routineUpdated(try c.decode(Routine.self, forKey: .data))
        case "models.updated": event = .modelsUpdated
        case "task.updated": event = .taskUpdated(try c.decode(BotTask.self, forKey: .data))
        case "task.deleted": event = .taskDeleted(id: try c.decode(IDOnly.self, forKey: .data).id)
        case "pong": event = .pong
        default: event = .unknown(type)
        }
    }
}

/// Geänderte Felder einer Mail-Karte (`edits` beim Senden). Nur gesetzte Felder werden übertragen.
nonisolated struct MailEdits: Encodable, Equatable, Sendable {
    var account: String?
    var to: [String]?
    var cc: [String]?
    var subject: String?
    var body: String?

    var isEmpty: Bool { account == nil && to == nil && cc == nil && subject == nil && body == nil }
}
