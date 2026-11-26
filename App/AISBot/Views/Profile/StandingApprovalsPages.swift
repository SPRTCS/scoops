import SwiftUI

// MARK: - Dauerhafte Freigaben: Unterseiten nach Werkzeug
//
// Die Liste der dauerhaften Freigaben („Immer erlauben“) wächst mit der Zeit, vor allem bei MCP-Servern, deren
// Werkzeuge einzeln freigegeben werden (Keynote: list_functions, list_windows, …). Deshalb steht im Profil nur eine
// Zeile unter „Rechner-Zugriff“; sie führt zu einer Liste der Werkzeuge (MCP-Server, Mail, T3 Code, Apple, Weitere)
// und von dort zu den einzelnen Freigaben.

/// Werkzeug, zu dem eine dauerhafte Freigabe gehört.
struct StandingApprovalGroup: Identifiable, Hashable {
    /// stabil über Sprachen hinweg (MCP: Servername aus dem Schlüssel, sonst die Art)
    let id: String
    let title: String
    let symbol: String
    var items: [StandingApproval]

    /// Gruppiert nach Werkzeug; Reihenfolge: MCP-Server alphabetisch, dann Mail, T3 Code, Apple, Weitere.
    static func groups(_ list: [StandingApproval]) -> [StandingApprovalGroup] {
        var byID: [String: StandingApprovalGroup] = [:]
        for item in list {
            let g = item.group
            byID[g.id, default: StandingApprovalGroup(id: g.id, title: g.title, symbol: g.symbol, items: [])].items.append(item)
        }
        return byID.values.sorted { a, b in
            (a.rank, a.title.localizedLowercase) < (b.rank, b.title.localizedLowercase)
        }
    }

    private var rank: Int {
        if id.hasPrefix("mcp:") { return 0 }
        switch id { case "mail": return 1; case "t3": return 2; case "apple": return 3; default: return 4 }
    }
}

extension StandingApproval {
    /// MCP-Server dieser Freigabe (Schlüssel `mcp:<server>__<werkzeug>`), sonst nil
    private var mcpServer: String? {
        guard key.hasPrefix("mcp:") || kind == "mcp" else { return nil }
        let rest = key.hasPrefix("mcp:") ? String(key.dropFirst(4)) : key
        return rest.components(separatedBy: "__").first.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Name des MCP-Servers, wie ihn der Server in die Beschriftung schreibt („Keynote: list_functions ausführen“)
    private var labelPrefix: String? {
        guard let r = label.range(of: ": ") else { return nil }
        let p = String(label[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        return p.isEmpty ? nil : p
    }

    fileprivate var group: (id: String, title: String, symbol: String) {
        if let server = mcpServer {
            let fallback = server.hasPrefix("mcp_") ? String(server.dropFirst(4)).capitalized : server
            return ("mcp:\(server)", labelPrefix ?? fallback, "server.rack")
        }
        switch kind {
        case "mail": return ("mail", String(localized: "Mail", comment: "Werkzeug-Gruppe dauerhafter Freigaben"), "envelope")
        case "t3", "t3_send": return ("t3", "T3 Code", "hammer")
        case "apple": return ("apple", String(localized: "Apple-Dienste", comment: "Werkzeug-Gruppe dauerhafter Freigaben"), "house")
        default: return ("other", String(localized: "Weitere Aktionen", comment: "Werkzeug-Gruppe dauerhafter Freigaben"), "checkmark.seal")
        }
    }

    /// Beschriftung innerhalb der Werkzeug-Seite: ohne den Servernamen davor („list_functions ausführen“)
    var labelInGroup: String {
        guard mcpServer != nil, let prefix = labelPrefix else { return label }
        let rest = label.dropFirst(prefix.count + 2).trimmingCharacters(in: .whitespaces)
        return rest.isEmpty ? label : rest
    }
}

/// Zeile im Profil unter „Rechner-Zugriff“ (nur, wenn es dauerhafte Freigaben gibt).
struct StandingApprovalsNavSection: View {
    let bot: Bot
    @Environment(AppStore.self) private var store

    var body: some View {
        let list = store.standingApprovals[bot.id] ?? []
        if !list.isEmpty {
            GroupedSection(dividerInset: 50) {
                ProfileNavRow(page: .standing, value: "\(list.count)")
            }
        }
    }
}

/// Seite „Dauerhafte Freigaben“: ein Eintrag je Werkzeug mit Anzahl.
struct StandingApprovalsPage: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(ProfileRouter.self) private var router: ProfileRouter?
    @Environment(\.theme) private var theme

    var body: some View {
        let groups = StandingApprovalGroup.groups(store.standingApprovals[bot.id] ?? [])
        if groups.isEmpty {
            GroupedSection(footer: "Wenn du bei einer Freigabe „Immer erlauben“ wählst, erscheint sie hier.") {
                GroupedLabelRow(icon: "checkmark.seal", title: "Keine dauerhaften Freigaben", titleColor: theme.textSecondary)
            }
        } else {
            GroupedSection(footer: "Dafür fragt \(bot.name) nicht mehr, sondern meldet es nur im Chat. Entfernen heißt: wieder fragen.",
                           dividerInset: 50) {
                ForEach(groups) { group in groupRow(group) }
            }
        }
    }

    private func groupRow(_ group: StandingApprovalGroup) -> some View {
        Button {
            router?.openStandingGroup(id: group.id, title: group.title)
        } label: {
            GroupedLabelRow(icon: group.symbol, title: group.title) {
                HStack(spacing: 6) {
                    Text("\(group.items.count)")
                        .appFont(14.5).monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                    DisclosureChevron()
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel([group.title, "\(group.items.count)"].joined(separator: ", "))
    }
}

/// Seite eines Werkzeugs: die einzelnen Freigaben mit Entfernen. Ist die letzte entfernt, geht es eine Seite zurück.
struct StandingApprovalGroupPage: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(ProfileRouter.self) private var router: ProfileRouter?
    @Environment(\.theme) private var theme

    private var group: StandingApprovalGroup? {
        let groups = StandingApprovalGroup.groups(store.standingApprovals[bot.id] ?? [])
        guard let id = router?.standingGroup?.id else { return nil }
        return groups.first { $0.id == id }
    }

    var body: some View {
        if let group {
            GroupedSection(footer: "Dafür fragt \(bot.name) nicht mehr. Entfernen heißt: wieder fragen.", dividerInset: 50) {
                ForEach(group.items) { item in StandingApprovalRow(item: item, title: item.labelInGroup) }
            }
        } else {
            GroupedSection {
                GroupedLabelRow(icon: "checkmark.seal", title: "Keine dauerhaften Freigaben", titleColor: theme.textSecondary)
            }
            .task { router?.back() }
        }
    }
}
