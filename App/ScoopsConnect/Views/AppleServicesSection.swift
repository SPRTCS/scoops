import SwiftUI

/// Einstellungen → „Apple-Dienste“: Erinnerungen, Kalender und Kontakte für die Scoops freigeben.
/// Gleiche Bauart wie die Berechtigungsseite (`PermissionRow`), mit Live-Prüfung.
struct AppleServicesSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(AppleService.allCases) { s in
                AppleServiceRow(model: model, service: s, permission: model.appleGrants[s] ?? "unknown")
            }
            Text("Zusätzlich schaltest du jeden Dienst in AIS Scoops unter **Apps verbinden → Apple** ein. Änderungen landen per iCloud sofort auf deinem iPhone. Gäste geteilter Scoops bekommen nie Zugriff.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let last = model.lastAppleCommand {
                Text("Zuletzt genutzt: \(Self.label(last.command)) · \(last.at.formatted(date: .omitted, time: .shortened))",
                     comment: "Dienst · Uhrzeit")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .task {
            while !Task.isCancelled {
                model.refreshApple()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    static func label(_ command: String) -> String {
        if command.hasPrefix("apple.reminders.") { return AppleService.reminders.title }
        if command.hasPrefix("apple.calendar.") { return AppleService.calendar.title }
        if command.hasPrefix("apple.contacts.") { return AppleService.contacts.title }
        return command
    }
}

private struct AppleServiceRow: View {
    let model: AppModel
    let service: AppleService
    let permission: String
    @State private var asking = false

    private var granted: Bool { permission == "granted" || permission == "disabled" }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: service.symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(service.title).font(.headline)
                    badge
                }
                Text(service.detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions.padding(.top, 4)
            }
            Spacer(minLength: 0)
            if granted {
                Toggle("Für Scoops nutzen", isOn: Binding(get: { permission == "granted" },
                                                          set: { model.setAppleEnabled(service, $0) }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .accessibilityLabel(Text("\(service.title) für Scoops nutzen"))
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var badge: some View {
        switch permission {
        case "granted":
            Label("Freigegeben", systemImage: "checkmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.green)
        case "disabled":
            Label("Aus", systemImage: "pause.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        case "not_determined":
            Label("Noch nicht freigegeben", systemImage: "exclamationmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.orange)
        default:
            Label("Abgelehnt", systemImage: "xmark.circle.fill").font(.caption.weight(.medium)).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch permission {
        case "not_determined":
            HStack {
                Button("Freigeben …") {
                    asking = true
                    Task { await model.requestApple(service); asking = false }
                }
                .disabled(asking)
                if asking { ProgressView().controlSize(.small) }
            }
        case "granted", "disabled":
            EmptyView()
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(permission == "write_only"
                     ? "Nur Schreibzugriff erteilt. Für die Scoops bitte vollen Zugriff erlauben."
                     : "In den Systemeinstellungen unter Datenschutz & Sicherheit → \(service.title) „AIS Scoops Server“ erlauben.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Systemeinstellungen öffnen") { model.openAppleSettings(service) }
                    .buttonStyle(.link)
            }
        }
    }
}
