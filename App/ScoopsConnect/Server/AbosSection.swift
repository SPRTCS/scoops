import SwiftUI

// KI-Abos (Server 1.30, docs/abos.md): Die Scoops können statt über API-Schlüssel über ein Claude- bzw. ChatGPT-Abo
// laufen. Der Server steuert dafür die offiziellen Programme (Claude Code, Codex); angemeldet wird ausschließlich in
// diesen Programmen selbst. Diese Ansicht zeigt nur den Status, den die Programme melden, und startet ihren eigenen
// Login-Ablauf in einem Terminal-Fenster. Sie sieht und speichert nie Anmeldedaten.

struct AboProvider: Identifiable {
    let id: String  // "claude" | "openai"
    let title: String
    let loginTitle: String
    let symbol: String
    let help: String

    /// Berechnet (nicht gespeichert), damit die Texte in der aktuellen Sprache nachgeschlagen werden
    static var all: [AboProvider] {
        [
            AboProvider(id: "claude", title: "Claude", loginTitle: String(localized: "Mit Claude anmelden"), symbol: "sparkles",
                        help: String(localized: "Claude Pro oder Max. Claude-Scoops, Aufgaben und Routinen laufen dann über Claude Code mit deinem Abo.")),
            AboProvider(id: "openai", title: "ChatGPT", loginTitle: String(localized: "Mit ChatGPT anmelden"),
                        symbol: "bubble.left.and.bubble.right",
                        help: String(localized: "ChatGPT Plus oder Pro. GPT-Scoops, Aufgaben und Routinen laufen dann über Codex mit deinem Abo.")),
        ]
    }
}

struct AbosView: View {
    let manager: ServerManager
    var compact = false
    @State private var busy: String?
    @State private var message: String?
    @State private var watching = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !compact {
                Text("Hast du ein Claude- oder ChatGPT-Abo, können deine Scoops darüber arbeiten statt über einen API-Schlüssel. Du meldest dich dafür im offiziellen Programm an (Claude Code bzw. Codex); AIS Scoops sieht deine Anmeldedaten nie.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(AboProvider.all) { p in
                row(p)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Sprechmodus und Diktat laufen weiter über den API-Schlüssel, Bilder nur über das ChatGPT-Abo. Abo-Läufe kosten nichts extra, zählen aber auf die Limits deines Abos.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .task { await manager.refreshAbos(force: true) }
        .task(id: watching) {
            // Nach dem Start des Logins den Status ein paar Minuten lang nachfragen, bis die Anmeldung da ist
            guard watching else { return }
            for _ in 0..<60 {
                try? await Task.sleep(for: .seconds(4))
                await manager.refreshAbos(force: true)
                if AboProvider.all.allSatisfy({ manager.abos?[$0.id]?["subscription"]?.bool == true }) { break }
            }
            watching = false
        }
    }

    @ViewBuilder
    private func row(_ p: AboProvider) -> some View {
        let st = manager.abos?[p.id]
        let loggedIn = st?["subscription"]?.bool == true
        let mode = st?["mode"]?.string ?? "api"
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: p.symbol).font(.title2).foregroundStyle(.tint).frame(width: 28).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(p.title).font(.headline)
                        if loggedIn {
                            Label(statusText(st), systemImage: "checkmark.circle.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(.green)
                        } else if st?["logged_in"]?.bool == true {
                            Label("Angemeldet ohne Abo", systemImage: "exclamationmark.circle.fill")
                                .font(.caption.weight(.medium)).foregroundStyle(.orange)
                        } else {
                            Label("Nicht angemeldet", systemImage: "circle.dashed")
                                .font(.caption.weight(.medium)).foregroundStyle(.secondary)
                        }
                    }
                    Text(p.help).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let lim = st?["limit"], lim != .null {
                        limitText(lim["until"]?.string)
                            .font(.caption).foregroundStyle(.orange)
                    } else if let u = st?["usage"]?["utilization"]?.double {
                        usageText(Int((u * 100).rounded()), window: st?["usage"]?["window"]?.string)
                            .font(.caption).foregroundStyle(u > 0.85 ? .orange : .secondary)
                    }
                    if st?["installed"]?.bool == false {
                        Text("Programm fehlt in der Server-Runtime. Bitte AIS Scoops Server aktualisieren.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(busy == p.id ? String(localized: "Öffnet …") : (loggedIn ? String(localized: "Neu anmelden") : p.loginTitle)) {
                    Task { await login(p) }
                }
                .disabled(busy != nil || st?["installed"]?.bool == false)
            }
            Picker("Abrechnung", selection: Binding(get: { mode }, set: { v in Task { await setMode(p.id, v) } })) {
                Text("API-Schlüssel").tag("api")
                Text("Abo").tag("abo")
                Text("Abo, bei Limit API").tag("abo_api")
            }
            .pickerStyle(.segmented)
            .padding(.leading, 40)
            .disabled(busy != nil)
            if mode != "api" && !loggedIn {
                Text(mode == "abo" ? "Noch nicht angemeldet: Bis dahin schlagen Läufe mit einem Hinweis fehl."
                                   : "Noch nicht angemeldet: Bis dahin läuft alles über den API-Schlüssel.")
                    .font(.caption).foregroundStyle(.orange).padding(.leading, 40)
            }
        }
    }

    private func statusText(_ st: JSONValue?) -> String {
        let plan = st?["plan"]?.string.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return plan.map { String(localized: "Angemeldet · \($0)", comment: "Abo: angemeldet, mit Tarif") } ?? String(localized: "Angemeldet")
    }

    /// Auslastung des Abos in Prozent, mit Zeitfenster des Anbieters (ganze Sätze, je Sprache eigenes Prozentformat)
    private func usageText(_ percent: Int, window: String?) -> Text {
        switch window {
        case "five_hour": Text("Abo-Auslastung \(percent) % (5-Stunden-Fenster)")
        case "seven_day", "seven_day_opus", "seven_day_sonnet": Text("Abo-Auslastung \(percent) % (Woche)")
        default: Text("Abo-Auslastung \(percent) %")
        }
    }

    private func limitText(_ iso: String?) -> Text {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else {
            return Text("Abo-Limit erreicht – läuft bis später über den API-Schlüssel.")
        }
        return Text("Abo-Limit erreicht – läuft bis \(d.formatted(date: .omitted, time: .shortened)) über den API-Schlüssel.")
    }

    private func login(_ p: AboProvider) async {
        busy = p.id
        defer { busy = nil }
        do {
            try await manager.startAboLogin(p.id)
            let program = p.id == "claude" ? "Claude Code" : "Codex"
            message = String(localized: "Ein Terminal-Fenster mit der Anmeldung von \(program) ist offen. Melde dich dort bzw. im Browser an; der Status hier aktualisiert sich von selbst.")
            watching = true
        } catch {
            message = error.localizedDescription
        }
    }

    private func setMode(_ provider: String, _ mode: String) async {
        busy = provider
        defer { busy = nil }
        do { try await manager.setAboMode(provider, mode) } catch { message = error.localizedDescription }
    }
}

struct AbosSection: View {
    let manager: ServerManager

    var body: some View {
        Section {
            AbosView(manager: manager, compact: true)
        } header: {
            Text("KI-Abos")
        } footer: {
            Text("„Abo, bei Limit API“: Ist das Abo-Limit erreicht, arbeiten die Scoops mit einem kurzen Hinweis über den API-Schlüssel weiter.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
