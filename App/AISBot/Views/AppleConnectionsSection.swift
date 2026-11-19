import SwiftUI

/// „Apps verbinden“ → Apple: Erinnerungen, Kalender und Kontakte über den Apple-Rechner (API v1.17), Home, Wecker und
/// Standort über das iPhone (API v1.18).
///
/// Status kommt vom Server (`GET /api/apple`). Ein Tipp auf „Erlauben“ schaltet den Dienst ein; fehlt auf dem Mac die
/// macOS-Freigabe, steht darunter „Auf dem Mac in AIS Scoops Server freigeben“. Auf iPhone/iPad löst „Erlauben“ bei
/// Home, Wecker und Standort zuerst die iOS-Abfrage aus (HomeKit, AlarmKit, Standort; für Orte zusätzlich „Immer“).
/// Auf dem Mac steht dort „Auf dem iPhone erlauben“ mit dem Status des Geräts. Gäste geteilter Scoops sehen diesen
/// Abschnitt nie (er hängt nur in „Apps verbinden“).
struct AppleConnectionsSection: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.openURL) private var openURL

    @State private var status: AppleStatus?
    @State private var errorText: String?
    @State private var busy: Set<String> = []
    @State private var confirmOff: AppleServiceStatus?
    private var agent: AppleDeviceAgent { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: GroupedMetrics.sectionSpacing) {
            GroupedSection("Apple", footer: footer, dividerInset: 62) {
                if let status {
                    ForEach(status.services) { s in serviceRow(s, status: status) }
                    if status.nodes.count > 1 { nodePicker(status) }
                } else if let errorText {
                    Text(errorText).font(.system(size: 13.5)).foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .groupedRow()
                } else {
                    ProgressView().frame(maxWidth: .infinity).groupedRow()
                }
            }
            GroupedSection("Über dein iPhone", footer: deviceFooter, dividerInset: 62) {
                if let status, let services = status.deviceServices {
                    ForEach(services) { s in deviceRow(s, status: status) }
                    if let loc = services.first(where: { $0.id == "location" }), showsAlwaysRow(loc) { alwaysRow }
                    if (status.devices?.count ?? 0) > 1 { devicePicker(status) }
                } else if status != nil {
                    Text("Dein Server kennt Home, Wecker und Standort noch nicht. Bitte AIS Scoops Server aktualisieren (ab Version 1.18).")
                        .font(.system(size: 13.5)).foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .groupedRow()
                } else if errorText == nil {
                    ProgressView().frame(maxWidth: .infinity).groupedRow()
                }
            }
        }
        .task { await poll() }
        .confirmationDialog(confirmOff.map { "\($0.name) für die Scoops ausschalten?" } ?? "",
                            isPresented: Binding(get: { confirmOff != nil }, set: { if !$0 { confirmOff = nil } }),
                            titleVisibility: .visible) {
            Button("Ausschalten", role: .destructive) {
                if let s = confirmOff { Task { await set(s.id, false) } }
                confirmOff = nil
            }
            Button("Abbrechen", role: .cancel) { confirmOff = nil }
        } message: {
            Text("Die Scoops können dann nicht mehr darauf zugreifen. Deine Daten auf dem Mac und iPhone bleiben unverändert.")
        }
    }

    private var footer: String? {
        guard let status else { return nil }
        guard let name = status.nodeName else {
            return "Läuft über einen Mac mit AIS Scoops Server. Gerade ist keiner verbunden."
        }
        let state = status.nodeOnline ? "" : " (gerade offline)"
        return "Läuft über „\(name)“\(state). Änderungen erscheinen per iCloud sofort auf deinem iPhone. Löschen nur mit deiner Freigabe."
    }

    // MARK: Zeilen

    private func serviceRow(_ s: AppleServiceStatus, status: AppleStatus) -> some View {
        HStack(alignment: .center, spacing: 12) {
            AppleServiceIcon(service: s.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.textPrimary)
                Text(subtitle(s.id)).font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = hint(s) {
                    Label(hint, systemImage: s.status == "offline" ? "wifi.slash" : "desktopcomputer")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 6)
            if busy.contains(s.id) {
                ProgressView().controlSize(.small).frame(minWidth: 80)
            } else if s.enabled {
                Button { confirmOff = s } label: {
                    Label("Erlaubt", systemImage: "checkmark").labelStyle(.titleAndIcon)
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .accessibilityLabel("\(s.name): erlaubt. Tippen zum Ausschalten")
            } else {
                Button("Erlauben") { Task { await set(s.id, true) } }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(status.nodeId == nil)
                    .accessibilityLabel("\(s.name) erlauben")
            }
        }
        .groupedRow(vertical: 10)
    }

    private func subtitle(_ id: String) -> String {
        switch id {
        case "reminders": "Lesen, anlegen, ändern und abhaken"
        case "calendar": "Termine lesen und eintragen"
        case "home": "Licht, Steckdosen, Heizung und Szenen schalten"
        case "alarms": "Wecker und Timer stellen"
        case "location": "Standort abfragen und Orte merken"
        default: "Nummern, Mailadressen und Geburtstage nachschlagen"
        }
    }

    /// Hinweis nur, wenn der Nutzer etwas tun muss (eingeschaltet, aber nicht bereit) oder der Mac fehlt.
    private func hint(_ s: AppleServiceStatus) -> String? {
        switch s.status {
        case "needs_permission": s.enabled ? "Auf dem Mac in AIS Scoops Server freigeben" : nil
        case "offline", "needs_update", "no_node": s.enabled ? s.hint : nil
        default: nil
        }
    }

    private func nodePicker(_ status: AppleStatus) -> some View {
        Menu {
            Picker("Apple-Rechner", selection: Binding(get: { status.nodeChoice }, set: { v in Task { await setNode(v) } })) {
                Text("Automatisch (Mac des Servers)").tag("auto")
                ForEach(status.nodes) { n in
                    Text(n.online ? n.name : "\(n.name) (offline)").tag(n.id)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 38)
                Text("Apple-Rechner").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                Text(status.nodeName ?? "keiner").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .groupedRow()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Apple-Rechner: \(status.nodeName ?? "keiner")")
    }

    // MARK: Home, Wecker, Standort (über das iPhone, v1.18)

    /// Dieses Gerät ist (oder wird) das Apple-Gerät des Servers: iPhone/iPad, kein anderes gewählt.
    private func isLocalDevice(_ status: AppleStatus) -> Bool {
        guard AppleDeviceAgent.isSupported else { return false }
        guard let dev = status.device else { return true }
        return dev.id == agent.deviceID
    }

    private static func granted(_ id: String, _ perm: String) -> Bool {
        id == "location" ? ["always", "when_in_use"].contains(perm) : perm == "granted"
    }

    private var deviceFooter: String? {
        guard let status, status.deviceServices != nil else { return nil }
        let device = status.device
        var parts: [String] = []
        if let device {
            let here = AppleDeviceAgent.isSupported && device.id == agent.deviceID
            let state = device.online ? "verbunden" : (device.lastSeen.map { "zuletzt gesehen \(Self.relative($0))" } ?? "offline")
            parts.append(here ? "Läuft über dieses \(device.label) (\(state))." : "Läuft über „\(device.name)“ (\(state)).")
            parts.append("Ist AIS Scoops im Hintergrund, weckt der Server die App mit einer stillen Mitteilung. Das klappt "
                         + "nicht immer; dann AIS Scoops auf dem \(device.label) kurz öffnen.")
        } else {
            parts.append(AppleDeviceAgent.isSupported
                         ? "Tippe auf „Erlauben“, dann meldet sich dieses \(agent.label) bei deinem Server an."
                         : "Läuft über die AIS-Scoops-App auf deinem iPhone. Öffne sie dort einmal und erlaube Home, Wecker und Standort.")
        }
        parts.append("Schlösser, Türen, Garagentore und die Alarmanlage nur mit deiner Freigabe.")
        return parts.joined(separator: " ")
    }

    private func deviceRow(_ s: AppleServiceStatus, status: AppleStatus) -> some View {
        let local = isLocalDevice(status)
        let perm = local ? (agent.permissions[s.id] ?? s.permission) : s.permission
        return HStack(alignment: .center, spacing: 12) {
            AppleServiceIcon(service: s.id)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.system(size: 15, weight: .medium)).foregroundStyle(theme.textPrimary)
                Text(subtitle(s.id)).font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = deviceHint(s, status: status, local: local, perm: perm) {
                    Label(hint, systemImage: local ? "iphone" : "iphone.gen3")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                if AppleDeviceAgent.isSupported, !local, let dev = status.device,
                   status.devices?.contains(where: { $0.id == agent.deviceID }) == true {
                    Button("Dieses \(agent.label) nehmen") { Task { await setDevice(agent.deviceID) } }
                        .font(.system(size: 12.5, weight: .semibold))
                        .buttonStyle(.borderless)
                        .padding(.top, 2)
                        .accessibilityHint("Statt „\(dev.name)“")
                }
            }
            Spacer(minLength: 6)
            deviceButton(s, status: status, local: local, perm: perm)
        }
        .groupedRow(vertical: 10)
    }

    @ViewBuilder
    private func deviceButton(_ s: AppleServiceStatus, status: AppleStatus, local: Bool, perm: String) -> some View {
        if busy.contains(s.id) || agent.asking.contains(s.id) {
            ProgressView().controlSize(.small).frame(minWidth: 80)
        } else if local && !Self.granted(s.id, perm) {
            if perm == "not_determined" || (s.id == "home" && perm == "unknown") {
                Button("Erlauben") { Task { await allowOnDevice(s.id) } }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .accessibilityLabel("\(s.name) erlauben")
            } else {
                Button("Einstellungen") { openAppSettings() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .accessibilityLabel("\(s.name) in den iOS-Einstellungen erlauben")
            }
        } else if s.enabled && (local || s.permission != "unknown") && s.status != "needs_permission" {
            Button { confirmOff = s } label: {
                Label("Erlaubt", systemImage: "checkmark").labelStyle(.titleAndIcon)
            }
            .buttonStyle(PillButtonStyle(kind: .secondary))
            .accessibilityLabel("\(s.name): erlaubt. Tippen zum Ausschalten")
        } else if !local && (s.status == "needs_permission" || s.status == "no_device" || s.status == "unsupported") {
            Button("Auf dem iPhone erlauben") {}
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .disabled(true)
                .accessibilityLabel("\(s.name): auf dem iPhone in AIS Scoops erlauben")
        } else {
            Button("Erlauben") { Task { await set(s.id, true) } }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .accessibilityLabel("\(s.name) erlauben")
        }
    }

    private func deviceHint(_ s: AppleServiceStatus, status: AppleStatus, local: Bool, perm: String) -> String? {
        if local {
            if ["denied", "restricted"].contains(perm) { return "In den iOS-Einstellungen für AIS Scoops erlauben" }
            if let dev = status.device, dev.id != agent.deviceID { return "Läuft gerade über „\(dev.name)“" }
            return nil
        }
        switch s.status {
        case "needs_permission": return status.device.map { "Auf „\($0.name)“ in AIS Scoops erlauben" }
        case "unsupported": return s.hint
        default: return nil
        }
    }

    /// Standort „Beim Verwenden“ erlaubt: Orte (Geofences) brauchen zusätzlich „Immer“.
    private func showsAlwaysRow(_ loc: AppleServiceStatus) -> Bool {
        guard let status, isLocalDevice(status) else { return false }
        return agent.permissions["location"] == "when_in_use" && loc.enabled
    }

    private var alwaysRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text("Orte: „Immer“ erlauben").font(.system(size: 14.5, weight: .medium)).foregroundStyle(theme.textPrimary)
                Text("Damit dich deine Scoops an Orte erinnern („wenn ich im Büro bin …“), auch wenn AIS Scoops geschlossen ist. "
                     + "Das iPhone meldet nur Betreten und Verlassen, der Standort wird dafür nicht dauernd abgefragt.")
                    .font(.system(size: 12.5)).foregroundStyle(theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            if agent.asking.contains("location") {
                ProgressView().controlSize(.small).frame(minWidth: 80)
            } else {
                Button("Immer") {
                    Task {
                        let st = await agent.requestPermission("location", always: true)
                        if st != "always" { openAppSettings() }  // iOS fragt nur einmal; danach nur in den Einstellungen
                        await load()
                    }
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .accessibilityLabel("Standort immer erlauben")
            }
        }
        .groupedRow(vertical: 10)
    }

    private func devicePicker(_ status: AppleStatus) -> some View {
        Menu {
            Picker("Gerät", selection: Binding(get: { status.deviceChoice ?? "auto" }, set: { v in Task { await setDevice(v) } })) {
                Text("Automatisch (zuletzt aktives iPhone)").tag("auto")
                ForEach(status.devices ?? []) { d in
                    Text(d.id == agent.deviceID && AppleDeviceAgent.isSupported ? "\(d.name) (dieses Gerät)" : d.name).tag(d.id)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "iphone")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 38)
                Text("Gerät").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                Text(status.device?.name ?? "keins").font(.system(size: 14)).foregroundStyle(theme.textSecondary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
            }
            .groupedRow()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Gerät für Home, Wecker und Standort: \(status.device?.name ?? "keins")")
    }

    /// iOS-Abfrage, danach (wenn erteilt) den Dienst beim Server einschalten.
    private func allowOnDevice(_ id: String) async {
        let state = await agent.requestPermission(id)
        if Self.granted(id, state) {
            try? await Task.sleep(for: .milliseconds(400))  // Server hat das hello mit der neuen Freigabe
            await set(id, true)
        } else {
            await load()
        }
    }

    private func setDevice(_ choice: String) async {
        guard let service = store.service else { return }
        do {
            let s = try await service.updateApple(ApplePatch(device: choice == "auto" ? "" : choice))
            withAnimation(.snappy) { status = s }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func openAppSettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        #endif
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "de_DE")
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Server

    /// Lädt den Status und hält ihn aktuell, solange der Abschnitt sichtbar ist (Freigaben ändern sich auf dem Mac).
    private func poll() async {
        while !Task.isCancelled {
            await load()
            try? await Task.sleep(for: .seconds(status?.services.contains { $0.enabled && !$0.available } == true ? 3 : 10))
        }
    }

    private func load() async {
        guard let service = store.service else { return }
        do {
            let s = try await service.appleStatus()
            if s != status { withAnimation(.snappy) { status = s } }
            errorText = nil
        } catch let e as APIError where e.status == 404 {
            errorText = "Der Server kennt die Apple-Dienste noch nicht. Bitte AIS Scoops Server aktualisieren (ab Version 1.17)."
        } catch {
            if status == nil { errorText = "Status nicht verfügbar: \(error.localizedDescription)" }
        }
    }

    private func set(_ id: String, _ on: Bool) async {
        guard let service = store.service else { return }
        busy.insert(id)
        defer { busy.remove(id) }
        do {
            let s = try await service.updateApple(.service(id, on))
            withAnimation(.snappy) { status = s }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func setNode(_ choice: String) async {
        guard let service = store.service else { return }
        do {
            let s = try await service.updateApple(ApplePatch(node: choice == "auto" ? "" : choice))
            withAnimation(.snappy) { status = s }
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Kachel im Stil der Apple-Apps: Erinnerungen (Punkte-Liste), Kalender (Wochentag + Tag), Kontakte.
struct AppleServiceIcon: View {
    let service: String
    var size: CGFloat = 38

    var body: some View {
        Group {
            switch service {
            case "calendar": calendarTile
            case "home":
                Image(systemName: "house.fill")
                    .font(.system(size: size * 0.46, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [Color(red: 1, green: 0.72, blue: 0.2), Color(red: 1, green: 0.55, blue: 0.1)],
                                               startPoint: .top, endPoint: .bottom), in: tile)
            case "alarms":
                Image(systemName: "alarm.fill")
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: size, height: size)
                    .background(Color(white: 0.1), in: tile)
            case "location":
                Image(systemName: "location.fill")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [Color(red: 0.25, green: 0.6, blue: 1), Color(red: 0.1, green: 0.42, blue: 0.95)],
                                               startPoint: .top, endPoint: .bottom), in: tile)
            case "reminders":
                Image(systemName: "list.bullet")
                    .font(.system(size: size * 0.44, weight: .bold))
                    .foregroundStyle(.orange)
                    .frame(width: size, height: size)
                    .background(.white, in: tile)
            default:
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.white, Color(white: 0.55))
                    .frame(width: size, height: size)
                    .background(LinearGradient(colors: [Color(white: 0.82), Color(white: 0.68)], startPoint: .top, endPoint: .bottom),
                                in: tile)
            }
        }
        .overlay(tile.strokeBorder(.black.opacity(0.08), lineWidth: 0.5))
        .accessibilityHidden(true)
    }

    private var tile: RoundedRectangle { RoundedRectangle(cornerRadius: size * 0.26, style: .continuous) }

    private var calendarTile: some View {
        let now = Date()
        let de = Locale(identifier: "de_DE")
        return VStack(spacing: -1) {
            Text(now.formatted(Date.FormatStyle(locale: de).weekday(.abbreviated)).uppercased().replacingOccurrences(of: ".", with: ""))
                .font(.system(size: size * 0.22, weight: .semibold))
                .foregroundStyle(.red)
            Text(now.formatted(.dateTime.day()))
                .font(.system(size: size * 0.46, weight: .regular))
                .foregroundStyle(.black)
                .monospacedDigit()
        }
        .frame(width: size, height: size)
        .background(.white, in: tile)
    }
}
