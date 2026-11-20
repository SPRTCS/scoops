import Foundation
import Observation

// MARK: - Stummschalten und Ruhezeiten (App 1.3, docs/ruhe.md)

/// Ruhezeit der angemeldeten Person. Quelle ist der eigene Server; eine Kopie liegt auf dem Gerät, damit lokale
/// Mitteilungen sie kennen und die App sie an die Server von Admins geteilter Scoops weitergeben kann.
@Observable
final class RuheStore {
    /// Zuletzt bekannte Ruhezeit (`nil` = noch nie eingestellt)
    var quietHours: QuietHours? = RuheStore.stored()
    /// Wird gerade gespeichert
    var saving = false
    /// Blatt „Ruhezeiten“ über dem Hauptfenster (Befehlspalette); aus den Einstellungen öffnet es sich dort
    var showSheet = false

    private static let key = "quietHours"

    static func stored() -> QuietHours? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONCoding.makeDecoder().decode(QuietHours.self, from: data)
    }

    func remember(_ value: QuietHours) {
        quietHours = value
        guard !ProcessInfo.processInfo.arguments.contains("-mock") else { return }  // Demo: nichts auf dem Gerät ablegen
        if let data = try? JSONCoding.makeEncoder().encode(value) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}

extension AppStore {
    // MARK: Stummschalten

    /// Stummschaltung dieses Chats für mich (`nil` = der Server des Chats kann es noch nicht)
    func mute(of chatID: String?) -> ChatMute? {
        guard let chatID else { return nil }
        return group(chatID)?.mute ?? bot(chatID)?.mute
    }

    /// Lässt sich der Chat stummschalten? Ältere Server liefern das Feld `mute` nicht, dann fehlt der Menüpunkt.
    /// Im Demo-Modus immer, außer der Demo-Server spielt mit `-oldserver` einen alten Server (dort trägt nur ein
    /// stummer Chat das Feld).
    func canMute(_ chatID: String?) -> Bool {
        guard let chatID else { return false }
        return mute(of: chatID) != nil || (isMock && serverHealth?.mute == true && chatExists(chatID))
    }

    func isMuted(_ chatID: String?) -> Bool { mute(of: chatID)?.isActive() ?? false }

    /// Stummschalten (`preset`) bzw. Stummschaltung aufheben (`nil`). Zeigt den neuen Stand sofort und nimmt ihn
    /// zurück, falls der Server ablehnt. Bei geteilten Scoops gilt es nur für mich.
    func setMute(_ chatID: String, _ preset: MutePreset?) async {
        guard let svc = service(for: chatID) as? RuheService else { return }
        let previous = mute(of: chatID)
        let wanted = preset.map { ChatMute(muted: true, until: $0.until()) } ?? .off
        applyMute(chatID, wanted)
        do {
            applyMute(chatID, try await svc.setMute(chatID: chatID, mute: wanted))
        } catch {
            applyMute(chatID, previous)
            report(error)
        }
    }

    private func applyMute(_ chatID: String, _ mute: ChatMute?) {
        if var g = group(chatID) {
            g.mute = mute
            apply(.groupUpdated(g))
        } else if isGuestChat(chatID), var b = bot(chatID) {
            b.mute = mute
            applySharedBot(b)
        } else if var b = ownBot(chatID) {
            b.mute = mute
            apply(.botUpdated(b))
        }
    }

    // MARK: Ruhezeiten

    /// Der eigene Server kennt Ruhezeiten (der Demo-Server meldet sie wie ein echter, außer mit `-oldserver`)
    var supportsQuietHours: Bool { serverHealth?.quietHours == true }

    /// Nur Gast (kein eigener Server verbunden): Die Ruhezeit gilt dann auf den Servern der Admins.
    private var guestOnly: Bool { service == nil && !guestConnections.isEmpty }

    /// Lassen sich Ruhezeiten gerade einstellen?
    var quietHoursAvailable: Bool { supportsQuietHours || guestOnly }

    /// Stand vom eigenen Server holen. Auf iPhone und iPad folgt die Ruhezeit der Zeitzone des Geräts (Reisen);
    /// `adoptZone: false` übernimmt nur (Antwort auf eine Änderung von einem anderen Gerät, sonst könnten sich zwei
    /// Geräte in verschiedenen Zeitzonen die Einstellung gegenseitig zurückstellen).
    func loadQuietHours(adoptZone: Bool = true) async {
        guard supportsQuietHours, let svc = service as? RuheService else { return }
        guard var value = try? await svc.quietHours() else { return }
        #if os(iOS)
        let zone = TimeZone.current.identifier
        if adoptZone, value.enabled, value.timezone != zone {
            value.timezone = zone
            if let saved = try? await svc.updateQuietHours(value) { value = saved }
        }
        #endif
        ruhe.remember(value)
    }

    /// Speichert die Ruhezeit auf dem eigenen Server und gibt sie an die Server der Admins geteilter Scoops weiter.
    /// Rückgabe: Fehlertext, falls der eigene Server ablehnt.
    @discardableResult
    func saveQuietHours(_ value: QuietHours) async -> String? {
        var value = value
        value.timezone = TimeZone.current.identifier
        let previous = ruhe.quietHours
        ruhe.remember(value)
        ruhe.saving = true
        defer { ruhe.saving = false }
        if supportsQuietHours, let svc = service as? RuheService {
            do {
                ruhe.remember(try await svc.updateQuietHours(value))
            } catch {
                if let previous { ruhe.remember(previous) }
                return message(error)
            }
        }
        for serverID in guestConnections.keys { await syncQuietHours(toGuest: serverID) }
        return nil
    }

    /// Ruhezeit an den Server eines Admins geben (pro Person; ältere Server antworten mit 404 und werden übergangen).
    func syncQuietHours(toGuest serverID: String) async {
        guard let value = ruhe.quietHours, let svc = guestConnections[serverID]?.service as? RuheService else { return }
        _ = try? await svc.updateQuietHours(value)
    }

    /// Ereignisse, die der gemeinsame Decoder nicht kennt
    func applyOther(_ type: String) {
        if type == "quiet_hours.updated" { Task { await loadQuietHours(adoptZone: false) } }
    }
}
