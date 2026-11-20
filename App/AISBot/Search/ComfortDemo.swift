import Foundation

/// Demo-Daten für Suche und Chat-Komfort (nur `-mock`): ein langer Verlauf, um den Sprung zu einer älteren
/// Fundstelle, das Nachladen im Ausschnitt und den Zum-Ende-Knopf auszuprobieren. Startargument `-longchat`
/// (optional mit Anzahl, Standard 320) hängt ihn vor Pips Chat.
enum ComfortDemo {
    static let chatID = "b_pip"

    /// Anzahl aus `-longchat [n]`, `nil` ohne das Argument
    static var requestedCount: Int? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-longchat") else { return nil }
        return args.indices.contains(i + 1) ? max(20, Int(args[i + 1]) ?? 320) : 320
    }

    /// `-incoming <chat-id> [sekunden]`: Nach der Wartezeit (Standard 6 s) treffen in diesem Chat nacheinander drei
    /// Nachrichten ein, ohne dass man selbst schreibt (Zähler am Zum-Ende-Knopf ausprobieren).
    static var incoming: (chatID: String, delay: Double)? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-incoming"), args.indices.contains(i + 1) else { return nil }
        return (args[i + 1], args.indices.contains(i + 2) ? Double(args[i + 2]) ?? 6 : 6)
    }

    static var incomingTexts: [String] {
        [demoText("Kurzer Zwischenstand: Die Unterlagen sind fertig.", en: "Quick update: the documents are ready."),
         demoText("Ich habe sie in die Bibliothek gelegt.", en: "I put them in the Library."),
         demoText("Sag Bescheid, wenn ich noch etwas ändern soll.", en: "Let me know if I should change anything.")]
    }

    private static var topics: [(String, String)] {
        AppLanguage.isGerman ? [
            ("Erinnere mich bitte an den Biomüll am Donnerstag.", "Mach ich! Donnerstag um 7:00 erinnere ich dich an den **Biomüll**."),
            ("Was koche ich heute Abend?", "Wie wäre es mit einer schnellen **Kürbissuppe** mit Ingwer? Dauert 25 Minuten."),
            ("Wann ist der Zahnarzttermin?", "Dein Zahnarzttermin bei Dr. Weber ist am **Montag um 16:00**."),
            ("Hast du die Stromrechnung gesehen?", "Ja, die **Stromrechnung** für Oktober liegt bei 84,20 €. Soll ich sie in deine Ausgaben eintragen?"),
            ("Schick mir den Link zur Swift-Seite.", "Gern: [swift.org](https://www.swift.org/documentation/) hat alle Anleitungen."),
            ("Welche Bahn nehme ich morgen?", "Der **ICE 1023** um 7:12 passt am besten, Ankunft 8:58 in Köln."),
            ("Merk dir: Ich trinke keinen Kaffee.", "Gemerkt! Ich schlage dir künftig Tee vor."),
            ("Wie wird das Wetter am Wochenende?", "Samstag sonnig bei 14 Grad, Sonntag Regen ab mittags."),
        ] : [
            ("Please remind me about recycling on Thursday.", "Will do! I’ll remind you about **recycling** on Thursday at 7:00 AM."),
            ("What should I cook tonight?", "How about a quick **pumpkin soup** with ginger? It takes 25 minutes."),
            ("When’s my dentist appointment?", "Your appointment with Dr. Miller is on **Monday at 4:00 PM**."),
            ("Did you see the electric bill?", "Yes, the **electric bill** for October is $84.20. Want me to add it to your expenses?"),
            ("Send me the link to the Swift site.", "Sure: [swift.org](https://www.swift.org/documentation/) has all the guides."),
            ("Which train should I take tomorrow?", "**Acela 2151** at 5:00 AM works best, arriving in Boston at 8:40 AM."),
            ("Remember: I don’t drink coffee.", "Got it! I’ll suggest tea from now on."),
            ("What’s the weather like this weekend?", "Sunny and 57°F on Saturday, rain starting around noon on Sunday."),
        ]
    }

    /// `count` Nachrichten (abwechselnd du und der Scoop), die älteste zuerst, alle älter als `before`.
    static func longHistory(count: Int, before: Date) -> [Message] {
        var out: [Message] = []
        for i in 0..<count {
            let (question, answer) = topics[(i / 2) % topics.count]
            let date = before.addingTimeInterval(-Double(count - i) * 47 * 60)
            let round = i / 2 + 1
            if i % 2 == 0 {
                out.append(Message(id: "d_\(i)", botId: chatID, role: .user, text: demoText("\(question) (Runde \(round))", en: "\(question) (round \(round))"),
                                   createdAt: date))
            } else {
                out.append(Message(id: "d_\(i)", botId: chatID, role: .bot, text: answer, createdAt: date))
            }
        }
        // Eine eindeutige, alte Fundstelle weit vor dem Ende
        if count > 40 {
            out[12] = Message(id: "d_12", botId: chatID, role: .user,
                              text: demoText("Notier dir bitte das Kennwort für den Fahrradkeller: Lavendelhonig.",
                                              en: "Please make a note of the bike room password: lavender honey."), createdAt: out[12].createdAt)
            out[13] = Message(id: "d_13", botId: chatID, role: .bot,
                              text: demoText("Notiert: Fahrradkeller, Kennwort **Lavendelhonig**. Ich frage nach, bevor ich es weitergebe.",
                                              en: "Noted: bike room, password **lavender honey**. I’ll check with you before sharing it."),
                              createdAt: out[13].createdAt)
        }
        return out
    }
}
