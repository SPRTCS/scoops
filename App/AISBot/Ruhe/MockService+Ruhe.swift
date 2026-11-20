import Foundation

// MARK: - Stummschalten und Ruhezeiten im Demo-Modus (`-mock`)

extension MockService: RuheService {
    /// `-mutedemo`: Nora ist dauerhaft stumm, die Gruppe bis morgen früh (für Screenshots der Seitenleiste).
    func applyDemoMutes() {
        guard ProcessInfo.processInfo.arguments.contains("-mutedemo") else { return }
        demoUpdate(chatID: "b_nora", announce: false, bot: { $0.mute = .forever; $0.unread = max($0.unread, 2) })
        demoUpdate(chatID: "g_team", announce: false,
                   group: { $0.mute = ChatMute(muted: true, until: MutePreset.untilMorning.until()) })
    }

    func setMute(chatID: String, mute: ChatMute) async throws -> ChatMute {
        try? await Task.sleep(for: .milliseconds(150))
        let state = mute.muted ? mute : ChatMute.off
        guard demoUpdate(chatID: chatID, bot: { $0.mute = state }, group: { $0.mute = state }) else {
            throw APIError(status: 404, message: "Chat nicht gefunden")
        }
        return state
    }

    func quietHours() async throws -> QuietHours { demoQuietHours }

    func updateQuietHours(_ value: QuietHours) async throws -> QuietHours {
        guard QuietHours.minutes(value.start) != nil, QuietHours.minutes(value.end) != nil else {
            throw APIError(status: 400, message: "start muss eine Uhrzeit im Format HH:MM sein")
        }
        demoQuietHours = value
        return value
    }
}
