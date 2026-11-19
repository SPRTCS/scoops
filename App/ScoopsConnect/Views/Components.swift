import AppKit
import SwiftUI

/// Zustandspunkt (grün/gelb/rot/grau) mit Text.
struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(.black.opacity(0.1), lineWidth: 0.5))
            .accessibilityHidden(true)
    }
}

extension AppModel {
    var statusColor: Color {
        if !isPaired { return .secondary }
        if paused { return .orange }
        switch linkState {
        case .connected: return .green
        case .connecting: return .yellow
        case .waiting: return .red
        case .unpaired: return .secondary
        }
    }
}

/// Eine Berechtigungszeile mit Live-Status, „Erlauben“ und Direkt-Link in die Systemeinstellungen.
struct PermissionRow: View {
    let title: String
    let detail: String
    let symbol: String
    let granted: Bool
    let request: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if granted {
                        Label("Erlaubt", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.green)
                    } else {
                        Label("Fehlt", systemImage: "exclamationmark.circle.fill")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.orange)
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !granted {
                    HStack {
                        Button("Erlauben …", action: request)
                        Button("Systemeinstellungen öffnen", action: openSettings)
                            .buttonStyle(.link)
                    }
                    .padding(.top, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
    }
}

/// Beide Rechte für den direkten Modus, mit Live-Prüfung im Sekundentakt.
struct PermissionsSection: View {
    let model: AppModel

    var body: some View {
        // `permissionTick` sorgt für das Neuzeichnen, die Werte selbst fragt die Ansicht direkt ab.
        let _ = model.permissionTick
        VStack(alignment: .leading, spacing: 14) {
            PermissionRow(
                title: "Bildschirmaufnahme",
                detail: "Damit Scoops sehen, was auf dem Bildschirm passiert.",
                symbol: "rectangle.dashed.badge.record",
                granted: Permissions.screenRecording,
                request: Permissions.requestScreenRecording,
                openSettings: Permissions.openScreenRecordingSettings)
            PermissionRow(
                title: "Bedienungshilfen",
                detail: "Damit Scoops Maus und Tastatur bedienen können.",
                symbol: "accessibility",
                granted: Permissions.accessibility,
                request: Permissions.requestAccessibility,
                openSettings: Permissions.openAccessibilitySettings)
            Text("Nach dem Erlauben der Bildschirmaufnahme verlangt macOS manchmal einen Neustart der App.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task {
            while !Task.isCancelled {
                model.tickPermissions()
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}

/// Auswahlkarte für den Modus.
struct ModeCard: View {
    let mode: AppModel.Mode
    let selected: Bool
    let action: () -> Void

    private var symbol: String { mode == .direct ? "desktopcomputer" : "shippingbox" }
    private var detail: String {
        mode == .direct
            ? "Für einen Mac, der nur für die Scoops da ist. Sie bedienen diesen Bildschirm, Maus und Tastatur direkt. Hier sollte nichts Privates angemeldet sein."
            : "Für einen Mac, an dem du selbst arbeitest. Die Scoops arbeiten abgeschirmt in einer virtuellen Maschine (Lume) und sehen deinen Bildschirm nicht."
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol)
                    .font(.title)
                    .frame(width: 36)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode.title).font(.headline)
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .padding(14)
            .contentShape(.rect)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.04)))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.10), lineWidth: selected ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// App-Symbol für Kopfzeilen.
struct AppIconView: View {
    var size: CGFloat = 48
    var body: some View {
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Fragt per NSAlert nach, bevor der Rechner getrennt wird.
@MainActor
func confirmUnpair(_ model: AppModel) {
    let alert = NSAlert()
    alert.messageText = "Rechner trennen?"
    alert.informativeText = "Scoops Connect vergisst die Kopplung mit dem Server. Die Scoops können diesen Rechner dann nicht mehr nutzen, bis du ihn neu koppelst."
    alert.addButton(withTitle: "Trennen")
    alert.addButton(withTitle: "Abbrechen")
    alert.buttons.first?.hasDestructiveAction = true
    NSApp.activate()
    if alert.runModal() == .alertFirstButtonReturn { model.unpair() }
}
