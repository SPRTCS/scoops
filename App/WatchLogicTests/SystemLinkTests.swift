import Foundation
import Testing

/// Reine Logik der Systemintegration (docs/system.md): tiefe Links, das Verzeichnis für Erweiterungen und die Ablage.
@Suite("System: Links, Verzeichnis, Ablage")
struct SystemLinkTests {
    // MARK: Tiefe Links

    @Test func chatLinks() {
        #expect(DeepLink(url: URL(string: "aisbot://bot/b_mila")!) == .chat(id: "b_mila", server: nil, compose: false))
        #expect(DeepLink(url: URL(string: "aisbot://group/g_team")!) == .chat(id: "g_team", server: nil, compose: false))
        #expect(DeepLink(url: URL(string: "aisbot://chat/b_mila?server=srv1&compose=1")!)
            == .chat(id: "b_mila", server: "srv1", compose: true))
        #expect(DeepLink(url: URL(string: "aisbot://compose")!) == .chat(id: nil, server: nil, compose: true))
        #expect(DeepLink(url: URL(string: "AISBOT://Compose/b_lio")!) == .chat(id: "b_lio", server: nil, compose: true))
        // Chat ohne ID ist kein gültiger Link
        #expect(DeepLink(url: URL(string: "aisbot://chat")!) == nil)
    }

    // MARK: Schlüsselbund-Gruppe

    /// Team-Präfix der Zugriffsgruppe aus der Info.plist (`$(AppIdentifierPrefix)`), sonst der bisherige Wert
    @Test func teamPraefixDerSchluesselbundGruppe() {
        #expect(SharedKeychain.resolvePrefix("ABCDE12345.") == ("ABCDE12345.", true))
        #expect(SharedKeychain.resolvePrefix("MYXQKK3T2Z.").value == "MYXQKK3T2Z.")
        // Nicht eingesetzt, leer, fehlt oder ohne Punkt: Rückfall auf das Team des Projekts (Verhalten wie bisher)
        for raw in ["$(AppIdentifierPrefix)", "", ".", nil, "ABCDE12345", "AB CD."] as [String?] {
            let r = SharedKeychain.resolvePrefix(raw)
            #expect(r.value == SharedKeychain.fallbackPrefix && !r.fromInfoPlist, "\(raw ?? "nil")")
        }
        #expect(SharedKeychain.fallbackPrefix == "MYXQKK3T2Z.")
    }

    @Test func sprechmodusHeuteAblage() {
        #expect(DeepLink(url: URL(string: "aisbot://voice")!) == .voice(id: nil, server: nil))
        #expect(DeepLink(url: URL(string: "aisbot://voice/b_mila?server=demo")!) == .voice(id: "b_mila", server: "demo"))
        #expect(DeepLink(url: URL(string: "aisbot://today")!) == .today)
        #expect(DeepLink(url: URL(string: "aisbot://outbox")!) == .outbox)
    }

    @Test func fremdeLinksBleibenUnberuehrt() {
        // Kopplung und Nutzung wertet weiter die App selbst aus
        #expect(DeepLink(url: URL(string: "aisbot://pair?url=http://x&token=t")!) == nil)
        #expect(DeepLink(url: URL(string: "aisbot://usage/limits")!) == nil)
        #expect(DeepLink(url: URL(string: "aisscoops://invite/ABC")!) == nil)
        #expect(DeepLink(url: URL(string: "https://example.com/chat/b_1")!) == nil)
    }

    @Test func hinUndZurueck() {
        let links: [DeepLink] = [
            .chat(id: "b_mila", server: nil, compose: false),
            .chat(id: "g_team", server: "srv 1", compose: true),
            .chat(id: nil, server: nil, compose: true),
            .voice(id: nil, server: nil),
            .voice(id: "b_mila", server: "demo"),
            .today,
            .outbox,
        ]
        for link in links {
            #expect(DeepLink(url: link.url) == link, "\(link.url)")
        }
    }

    // MARK: Verzeichnis

    private func chat(_ id: String, primary: Bool = false, pinned: Bool = false, age: TimeInterval = 0,
                      canWrite: Bool = true, shared: Bool = false, server: String = "s1") -> SystemChat {
        SystemChat(id: id, serverID: server, name: id, label: nil, mascot: ChatGroup.isGroupID(id) ? nil : .default,
                   members: nil, primary: primary, pinned: pinned, lastActiveAt: Date(timeIntervalSince1970: 1_000_000 - age),
                   canWrite: canWrite, shared: shared, ownerName: shared ? "Sophie" : nil)
    }

    private func directory(_ chats: [SystemChat]) -> SystemDirectory {
        SystemDirectory(generatedAt: Date(), userName: "Test", demo: false, activeServerID: "s1",
                        servers: [SystemServer(id: "s1", name: "Server", url: "https://a.example/", altURL: "b.example:8787",
                                               usesAccount: true, guest: false)],
                        chats: chats)
    }

    @Test func hauptScoopUndReihenfolge() {
        let d = directory([chat("b_alt", age: 500), chat("b_neu", age: 10), chat("b_pin", pinned: true, age: 900),
                           chat("b_haupt", primary: true, age: 5000), chat("g_team", age: 1),
                           chat("b_gast", age: 0, shared: true, server: "s2")])
        #expect(d.primaryScoop?.id == "b_haupt")
        #expect(d.ordered(d.scoops).map(\.id) == ["b_haupt", "b_pin", "b_gast", "b_neu", "b_alt"])
        #expect(d.scoops.count == 5)
        #expect(d.chat("g_team")?.isGroup == true)
    }

    @Test func ohneHauptScoopEinEigener() {
        // Ohne Haupt-Scoop: ein eigener Scoop, kein geteilter
        let d = directory([chat("b_gast", age: 0, shared: true, server: "s2"), chat("b_eigen", age: 100)])
        #expect(d.primaryScoop?.id == "b_eigen")
        #expect(directory([]).primaryScoop == nil)
    }

    @Test func serverAdressen() {
        let server = directory([]).servers[0]
        #expect(server.baseURLs.map(\.absoluteString) == ["https://a.example", "http://b.example:8787"])
    }

    @Test func unterzeile() {
        var c = chat("b_x")
        c.label = "Assistenz"
        #expect(c.subtitle == "Assistenz")
        var shared = chat("b_y", shared: true)
        #expect(shared.subtitle == "Geteilt von Sophie")
        shared.label = "Recherche"
        #expect(shared.subtitle == "Recherche · von Sophie")
        var group = chat("g_z")
        #expect(group.subtitle == "Gruppe")
        group.members = [SystemChatMember(id: "b_1", name: "Mila", mascot: .default),
                         SystemChatMember(id: "b_2", name: "Lio", mascot: .default)]
        #expect(group.subtitle == "Gruppe mit Mila und Lio")
    }

    @Test func verzeichnisBleibtBeimSpeichernGleich() throws {
        let d = directory([chat("b_a", primary: true), chat("g_b")])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(SystemDirectory.self, from: encoder.encode(d))
        #expect(back.chats == d.chats)
        #expect(back.servers == d.servers)
        #expect(back.activeServerID == "s1")
    }

    // MARK: Ablage

    @Test func zusammenfassungDerSendung() {
        var item = ShareOutboxItem(id: "x", createdAt: Date(), chatID: "b_a", serverID: "s1", chatName: "Mila", text: "",
                                   attachments: [], state: .queued, touchedAt: Date(), lastError: nil)
        #expect(item.summary == "Leer")
        item.text = "Hallo"
        #expect(item.summary == "Text")
        item.attachments = [.init(file: "1-a.jpg", name: "a.jpg", mime: "image/jpeg", size: 10, fileID: nil),
                            .init(file: "2-b.jpg", name: "b.jpg", mime: "image/jpeg", size: 10, fileID: nil),
                            .init(file: "3-c.pdf", name: "c.pdf", mime: "application/pdf", size: 10, fileID: nil),
                            .init(file: "4-d.pdf", name: "d.pdf", mime: "application/pdf", size: 10, fileID: nil)]
        // Einzahl („1 Datei“) kommt aus dem String Catalog (Mehrzahl-Regeln); den gibt es im Testprogramm nicht
        #expect(item.summary == "2 Bilder, 2 Dateien")
    }

    @Test func fehlerDieEinenZweitenVersuchLohnen() {
        #expect(SystemError.offline.isTransient)
        #expect(SystemError.unauthorized.isTransient)
        #expect(SystemError(kind: .server, message: "", status: 503).isTransient)
        #expect(!SystemError(kind: .server, message: "", status: 400).isTransient)
        #expect(!SystemError(kind: .forbidden, message: "", status: 403).isTransient)
        #expect(!SystemError(kind: .tooLarge, message: "", status: 413).isTransient)
        #expect(SystemError.from(URLError(.timedOut)).isTransient)
    }
}
