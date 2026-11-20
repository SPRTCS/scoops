import Foundation
import UniformTypeIdentifiers

// MARK: - Scoop-Vorlagen (App 1.3, docs/vorlagen.md)

extension UTType {
    /// Scoop-Vorlage (`.scoop`, JSON). Exportierter Typ, siehe `UTExportedTypeDeclarations` in project.yml.
    nonisolated static let scoopTemplate = UTType(exportedAs: "com.ais.aisbot.scoop-template", conformingTo: .json)
}

/// Inhalt einer Vorlagen-Datei (`"format": 1`). Enthält nie Gedächtnis, Verlauf, Dateien, Tresor, Konten,
/// Dauerfreigaben, Rechte oder Nutzungsdaten; der Server liest sie beim Export gar nicht erst.
nonisolated struct ScoopTemplate: Codable, Hashable, Sendable {
    static let currentFormat = 1
    static let typeID = "ais-scoops-template"
    static let fileExtension = "scoop"
    /// Größte Datei, die die App liest (der Server prüft dieselbe Grenze)
    static let maxBytes = 1_500_000

    var format: Int
    var type: String
    var name: String
    /// Rolle, z. B. „Assistenz“
    var label: String?
    /// Kurzbeschreibung für andere (wofür ist die Vorlage gut?)
    var description: String?
    var appearance: Appearance?
    /// Charakter und Anweisungen (landet im Prompt)
    var character: String?
    /// Bevorzugtes Modell
    var model: String?
    var skills: [SkillItem]
    var routines: [RoutineItem]
    var requires: [Requirement]

    nonisolated struct Appearance: Codable, Hashable, Sendable {
        var shape: String?
        var color: String?
        var eyes: String?
        var accessory: String?
        var gaze: String?
        var mouth: String?
        var cheeks: Bool?
        /// Eigenes Bild, nur auf Wunsch (Base64)
        var photo: Photo?

        nonisolated struct Photo: Codable, Hashable, Sendable {
            var mime: String
            var data: String
        }

        init(mascot: Mascot) {
            shape = mascot.shape; color = mascot.color; eyes = mascot.eyes; accessory = mascot.accessory
            gaze = mascot.gaze; mouth = mascot.mouth; cheeks = mascot.cheeks
        }

        /// Maskottchen zum Zeichnen (unbekannte Werte zeigt `MascotView` als Standard)
        var mascot: Mascot {
            var m = Mascot(shape: shape ?? Mascot.default.shape, color: color ?? Mascot.default.color,
                           eyes: eyes ?? Mascot.default.eyes, accessory: accessory ?? "none")
            m.gaze = gaze; m.mouth = mouth; m.cheeks = cheeks
            return m
        }

        var photoData: Data? { photo.flatMap { Data(base64Encoded: $0.data) } }
    }

    nonisolated struct SkillItem: Codable, Hashable, Sendable {
        var name: String
        var description: String?
        var steps: String
    }

    nonisolated struct RoutineItem: Codable, Hashable, Sendable {
        var title: String
        /// Cron-Ausdruck (Minute Stunde Tag Monat Wochentag)
        var schedule: String
        /// Zeitplan in Worten. In der Datei nur für Menschen; beim Import berechnet ihn der Server neu.
        var scheduleText: String?
        var prompt: String
        var model: String?
        /// Nur in der Vorschau vor dem Import (vom Server berechnet), nie in der Datei
        var runsPerDay: Double?
    }

    /// Hinweis auf eine benötigte Verbindung („braucht Gmail“)
    nonisolated struct Requirement: Codable, Hashable, Sendable {
        /// app | mcp | apple | other
        var kind: String
        var id: String?
        var name: String
        var note: String?
        /// Nur in der Vorschau vor dem Import: connected | missing | unknown
        var status: String?

        var symbol: String {
            switch kind {
            case "apple": "apple.logo"
            case "mcp": "server.rack"
            default: "link"
            }
        }
    }

    init(format: Int = ScoopTemplate.currentFormat, type: String = ScoopTemplate.typeID, name: String, label: String? = nil,
         description: String? = nil, appearance: Appearance? = nil, character: String? = nil, model: String? = nil,
         skills: [SkillItem] = [], routines: [RoutineItem] = [], requires: [Requirement] = []) {
        self.format = format; self.type = type; self.name = name; self.label = label; self.description = description
        self.appearance = appearance; self.character = character; self.model = model
        self.skills = skills; self.routines = routines; self.requires = requires
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        format = try c.decode(Int.self, forKey: .format)
        type = try c.decode(String.self, forKey: .type)
        name = try c.decode(String.self, forKey: .name)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        appearance = try c.decodeIfPresent(Appearance.self, forKey: .appearance)
        character = try c.decodeIfPresent(String.self, forKey: .character)
        model = try? c.decodeIfPresent(String.self, forKey: .model)
        skills = try c.decodeIfPresent([SkillItem].self, forKey: .skills) ?? []
        routines = try c.decodeIfPresent([RoutineItem].self, forKey: .routines) ?? []
        requires = try c.decodeIfPresent([Requirement].self, forKey: .requires) ?? []
    }

    // MARK: Datei

    /// Inhalt der `.scoop`-Datei: gut lesbares JSON mit festen Schlüsseln (snake_case), ohne Vorschau-Felder.
    func fileData() throws -> Data {
        var clean = self
        clean.format = Self.currentFormat
        clean.type = Self.typeID
        clean.label = clean.label.nilIfBlank
        clean.description = clean.description.nilIfBlank
        clean.character = clean.character.nilIfBlank
        clean.routines = clean.routines.map { var r = $0; r.runsPerDay = nil; return r }
        clean.requires = clean.requires.map { var q = $0; q.status = nil; q.note = q.note.nilIfBlank; return q }
        let encoder = JSONCoding.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(clean)
    }

    /// Dateiname ohne Sonderzeichen, z. B. „Mila.scoop“
    static func fileName(for name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let safe = String(name.unicodeScalars.filter { allowed.contains($0) }).trimmingCharacters(in: .whitespaces)
        return "\(safe.isEmpty ? "Scoop" : String(safe.prefix(40))).\(fileExtension)"
    }

    /// Erste Prüfung in der App, bevor die Datei an den Server geht: Größe, JSON, Typ und Formatversion.
    /// Die strenge Prüfung (Längen, erlaubte Werte, Zeitpläne) macht der Server.
    static func precheck(_ data: Data) -> TemplateProblem? {
        guard data.count <= maxBytes else { return .tooLarge }
        struct Head: Decodable { var format: Int?; var type: String? }
        guard let head = try? JSONDecoder().decode(Head.self, from: data), head.type == typeID, let format = head.format,
              format >= 1 else { return .notATemplate }
        return format > currentFormat ? .newerFormat(format) : nil
    }
}

/// Warum sich eine Datei nicht als Vorlage öffnen lässt (verständliche Meldung für die Vorschau).
nonisolated enum TemplateProblem: Error, Hashable, Sendable {
    case notATemplate
    case tooLarge
    case newerFormat(Int)
    case unreadable
    case server(String)

    var title: String {
        switch self {
        case .newerFormat: String(localized: "Vorlage ist zu neu")
        case .tooLarge: String(localized: "Vorlage ist zu groß")
        case .unreadable: String(localized: "Datei nicht lesbar")
        case .notATemplate: String(localized: "Keine Scoop-Vorlage")
        case .server: String(localized: "Vorlage abgelehnt")
        }
    }

    var message: String {
        switch self {
        case .notATemplate:
            String(localized: "Diese Datei ist keine Scoop-Vorlage. Vorlagen enden auf .scoop und kommen aus „Als Vorlage exportieren“.")
        case .tooLarge:
            String(localized: "Die Datei ist größer als 1,5 MB. Vorlagen sind klein; vielleicht ist es die falsche Datei.")
        case .newerFormat(let format):
            String(localized: "Diese Vorlage wurde mit einer neueren Version von AIS Scoops erstellt (Format \(String(format))). Aktualisiere die App und deinen Server, dann klappt es.")
        case .unreadable:
            String(localized: "Die Datei ließ sich nicht öffnen. Versuch es noch einmal oder lass sie dir erneut schicken.")
        case .server(let text):
            text
        }
    }
}

/// Antwort von `GET /api/bots/{id}/template`: was standardmäßig in die Datei kommt, was nur auf Wunsch, und Hinweise
/// auf Persönliches in den Texten.
nonisolated struct TemplateExport: Decodable, Sendable {
    var template: ScoopTemplate
    var optional: Extras
    var warnings: [Warning]
    var fileName: String?

    nonisolated struct Extras: Decodable, Sendable {
        /// Fähigkeiten, die für alle Scoops gelten
        var skills: [ScoopTemplate.SkillItem]
        var photo: ScoopTemplate.Appearance.Photo?

        init(skills: [ScoopTemplate.SkillItem] = [], photo: ScoopTemplate.Appearance.Photo? = nil) {
            self.skills = skills; self.photo = photo
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            skills = (try? c.decodeIfPresent([ScoopTemplate.SkillItem].self, forKey: .skills)) ?? []
            photo = try? c.decodeIfPresent(ScoopTemplate.Appearance.Photo.self, forKey: .photo)
        }

        private enum CodingKeys: String, CodingKey { case skills, photo }
    }

    nonisolated struct Warning: Decodable, Hashable, Sendable {
        var `where`: String?
        var text: String
    }

    init(template: ScoopTemplate, optional: Extras = Extras(), warnings: [Warning] = [], fileName: String? = nil) {
        self.template = template; self.optional = optional; self.warnings = warnings; self.fileName = fileName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decode(ScoopTemplate.self, forKey: .template)
        optional = (try? c.decodeIfPresent(Extras.self, forKey: .optional)) ?? Extras()
        warnings = (try? c.decodeIfPresent([Warning].self, forKey: .warnings)) ?? []
        fileName = try? c.decodeIfPresent(String.self, forKey: .fileName)
    }

    private enum CodingKeys: String, CodingKey { case template, optional, warnings, fileName }
}

/// Antwort von `POST /api/templates/check`: die geprüfte Vorlage, wie sie angelegt würde.
nonisolated struct TemplateCheck: Decodable, Sendable {
    var template: ScoopTemplate
    var model: ModelInfo?
    var notes: [String]

    nonisolated struct ModelInfo: Decodable, Hashable, Sendable {
        /// Modell laut Vorlage
        var id: String?
        /// Auf diesem Server nutzbar?
        var available: Bool
        /// Modell, das der Server sonst nimmt
        var `default`: String?

        init(id: String?, available: Bool, default: String?) {
            self.id = id; self.available = available; self.default = `default`
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            available = (try? c.decodeIfPresent(Bool.self, forKey: .available)) ?? false
            `default` = try? c.decodeIfPresent(String.self, forKey: .default)
        }

        private enum CodingKeys: String, CodingKey { case id, available, `default` }
    }

    init(template: ScoopTemplate, model: ModelInfo? = nil, notes: [String] = []) {
        self.template = template; self.model = model; self.notes = notes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        template = try c.decode(ScoopTemplate.self, forKey: .template)
        model = try? c.decodeIfPresent(ModelInfo.self, forKey: .model)
        notes = (try? c.decodeIfPresent([String].self, forKey: .notes)) ?? []
    }

    private enum CodingKeys: String, CodingKey { case template, model, notes }
}

/// Body von `POST /api/templates/import`.
nonisolated struct TemplateImportRequest: Encodable, Sendable {
    var template: ScoopTemplate
    var name: String
    /// Positionen der gewählten Routinen bzw. Fähigkeiten in der Vorlage
    var routines: [Int]
    var skills: [Int]
    var useModel: Bool
    var usePhoto: Bool
}

nonisolated struct TemplateImportResult: Decodable, Sendable {
    var bot: Bot
    var skills: Int?
    var routines: Int?
}

/// Eine Datei, die als Vorlage geöffnet werden soll (Dateiauswahl, „Öffnen mit“, AirDrop, Drag-and-drop).
nonisolated struct TemplateSource: Identifiable, Hashable, Sendable {
    let id = UUID()
    var data: Data
    var fileName: String?
}

private extension Swift.Optional where Wrapped == String {
    nonisolated var nilIfBlank: String? {
        guard let s = self?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }
}
