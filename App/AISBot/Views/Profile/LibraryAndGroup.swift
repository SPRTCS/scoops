import SwiftUI
import AVFoundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

// MARK: - Bibliothek

/// Dateien und Links eines Chats (Scoop oder Gruppe).
struct LibraryList: View {
    let chatID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var toDelete: LibraryFile?
    @State private var loading = true

    private var items: [LibraryFile] { store.files[chatID] ?? [] }

    var body: some View {
        Group {
            if items.isEmpty {
                if loading && store.files[chatID] == nil {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
                } else {
                    GroupedSection("Dateien und Links",
                                   footer: "Hänge im Chat Dateien an oder lass dir etwas erstellen. Alles landet hier.") {
                        GroupedLabelRow(icon: "books.vertical", title: "Noch nichts in der Bibliothek", titleColor: theme.textSecondary)
                    }
                }
            } else {
                GroupedSection("Dateien und Links",
                               footer: "Antippen öffnet die Vorschau. Halte gedrückt oder klicke mit rechts für weitere Aktionen.",
                               dividerInset: 60) {
                    ForEach(items) { file in row(file) }
                }
            }
        }
        .task(id: chatID) {
            await store.loadFiles(chatID: chatID)
            loading = false
        }
        .confirmationDialog("„\(toDelete?.name ?? "")“ löschen?",
                            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                if let f = toDelete { Task { await store.deleteFile(f) } }
                toDelete = nil
            }
            Button("Abbrechen", role: .cancel) { toDelete = nil }
        } message: {
            Text("Die Datei wird aus der Bibliothek entfernt.")
        }
    }

    private func row(_ file: LibraryFile) -> some View {
        Button { store.open(file) } label: {
            HStack(spacing: 10) {
                ZStack {
                    if file.isImage {
                        FileThumbnail(file: file)
                    } else {
                        Image(systemName: file.symbolName)
                            .font(.system(size: 15))
                            .foregroundStyle(file.isLink ? theme.link : theme.accent)
                    }
                }
                .frame(width: 32, height: 32)
                .background(theme.groupedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.name)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        if let author = store.bot(file.authorId) {
                            MascotView(mascot: author.mascot, size: 14, seed: author.id, animated: false)
                            Text(author.name)
                        } else {
                            Text("Du")
                        }
                        Text("·")
                        Text(detail(file))
                    }
                    .font(.system(size: 11.5))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .groupedRow(vertical: 8)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { store.open(file) } label: { Label(file.isLink ? "Im Browser öffnen" : "Öffnen", systemImage: "eye") }
            if file.isLink, let s = file.url, let url = URL(string: s) {
                ShareLink(item: url) { Label("Teilen …", systemImage: "square.and.arrow.up") }
                Button { Clipboard.copy(s) } label: { Label("Link kopieren", systemImage: "link") }
            } else {
                ShareFileButton(file: file)
            }
            Divider()
            Button(role: .destructive) { toDelete = file } label: { Label("Löschen", systemImage: "trash") }
        }
        .accessibilityLabel("\(file.name), \(detail(file))")
    }

    private func detail(_ file: LibraryFile) -> String {
        var parts: [String] = []
        if file.isLink, let s = file.url, let host = URL(string: s)?.host() { parts.append(host) }
        if let size = file.sizeText { parts.append(size) }
        if let d = file.createdAt { parts.append(Formatting.shortDate(d)) }
        return parts.joined(separator: " · ")
    }
}

/// „Teilen …“ für Dateien: lädt die Datei und zeigt dann das Teilen-Menü.
struct ShareFileButton: View {
    let file: LibraryFile
    @Environment(AppStore.self) private var store

    var body: some View {
        Button {
            Task {
                guard let url = await store.download(file) else { return }
                share(url)
            }
        } label: {
            Label("Teilen …", systemImage: "square.and.arrow.up")
        }
    }

    private func share(_ url: URL) {
        #if os(iOS)
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var top = scene?.keyWindow?.rootViewController
        while let presented = top?.presentedViewController { top = presented }
        vc.popoverPresentationController?.sourceView = top?.view
        top?.present(vc, animated: true)
        #else
        NSWorkspace.shared.activateFileViewerSelecting([url])
        #endif
    }
}

// MARK: - Stimme

/// Auswahl der Vorlesestimme (deutsche Systemstimmen) mit Probehören.
struct VoicePicker: View {
    let bot: Bot
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @State private var speaker = Speaker()
    @State private var voices: [AVSpeechSynthesisVoice] = []
    @State private var info: LiveVoiceInfo?
    @State private var player: AVAudioPlayer?
    @State private var previewing: String?
    @State private var previewError: String?

    private var choice: VoiceChoice { VoiceChoice(bot.voice) }
    private var liveAvailable: Bool { info?.available == true }
    /// Gewählte Live-Stimme (leer = Standard des Servers)
    private var liveID: String? {
        guard let live = choice.live else { return nil }
        return live.isEmpty ? (info?.defaultVoice ?? "marin") : live
    }
    private var deviceID: String? { choice.deviceID ?? VoiceCatalog.voice(for: nil)?.identifier }

    var body: some View {
        GroupedSection("Stimme", footer: footer) {
            if liveAvailable, let info {
                row("Stimme") {
                    Picker(selection: Binding(
                        get: { liveID.map { "live:\($0)" } ?? "device" },
                        set: { select($0) })) {
                        ForEach(info.voices) { v in
                            Text(v.note.map { "\(v.name) · \($0)" } ?? v.name).tag("live:\(v.id)")
                        }
                        Divider()
                        Text("Gerätestimme (offline)").tag("device")
                    } label: {
                        Text("Stimme")
                    } currentValueLabel: {
                        // In der Zeile nur der Name; die Beschreibung steht im Menü
                        Text(info.voices.first { $0.id == liveID }?.name ?? "Gerätestimme")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .tint(theme.textSecondary)
                    .lineLimit(1)
                }
            }
            row(choice.usesLive && liveAvailable ? "Rückfall (offline)" : "Gerätestimme") {
                Picker(selection: Binding(
                    get: { deviceID ?? "" },
                    set: { id in save(VoiceChoice(live: liveAvailable ? choice.live : nil, deviceID: id)) })) {
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) · \(VoiceCatalog.qualityLabel(v))").tag(v.identifier)
                    }
                } label: {
                    Text("Gerätestimme")
                } currentValueLabel: {
                    // In der Zeile nur der Name (sonst bricht „Flo · Standard“ in schmalen Spalten um)
                    Text(voices.first { $0.identifier == deviceID }?.name ?? "–")
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(theme.textSecondary)
                .lineLimit(1)
                .disabled(voices.isEmpty)
            }
            Button(action: preview) {
                GroupedLabelRow(icon: isPlaying ? "stop.circle.fill" : "play.circle.fill", iconColor: theme.accent,
                                title: isPlaying ? "Stopp" : (previewing != nil ? "Lädt Stimmprobe …" : "Probehören"),
                                subtitle: previewError, titleColor: theme.accent)
            }
            .buttonStyle(.plain)
            .disabled(previewing != nil || (!(choice.usesLive && liveAvailable) && voices.isEmpty))
        }
        .task {
            voices = VoiceCatalog.germanVoices()
            info = await store.loadLiveVoice(chatID: bot.id)
        }
        .onDisappear {
            speaker.stop()
            player?.stop()
        }
    }

    private var isPlaying: Bool { speaker.isSpeaking || (player?.isPlaying ?? false) }

    private func row<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 12) {
            Text(title).font(.system(size: 15)).foregroundStyle(theme.textPrimary).fixedSize()
            Spacer(minLength: 8)
            content()
        }
        .groupedRow(vertical: 6)
    }

    private func select(_ tag: String) {
        if tag == "device" {
            save(VoiceChoice(live: nil, deviceID: choice.deviceID))
        } else {
            save(VoiceChoice(live: String(tag.dropFirst(5)), deviceID: choice.deviceID))
        }
    }

    private func save(_ new: VoiceChoice) {
        player?.stop()
        speaker.stop()
        previewError = nil
        Task { await store.updateBot(bot.id, BotPatch(voice: .some(new.raw))) }
    }

    private func preview() {
        if isPlaying {
            speaker.stop()
            player?.stop()
            player = nil
            return
        }
        previewError = nil
        guard choice.usesLive, liveAvailable, let voice = liveID else {
            speaker.speak("Hallo \(store.userName), ich bin \(bot.name). So klinge ich ohne Internet.", voiceID: deviceID.map { "device:\($0)" })
            return
        }
        previewing = voice
        Task {
            let result = await store.liveVoicePreview(voice: voice)
            previewing = nil
            switch result {
            case .success(let data):
                #if os(iOS)
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
                #endif
                let p = try? AVAudioPlayer(data: data)
                player = p
                p?.play()
                if let p {
                    // Nach dem Ende wieder „Probehören“ zeigen (isPlaying ist nicht beobachtbar)
                    try? await Task.sleep(for: .seconds(p.duration + 0.2))
                    if player === p { player = nil }
                } else {
                    previewError = "Stimmprobe ließ sich nicht abspielen."
                }
            case .failure(let error):
                previewError = error.localizedDescription
            }
        }
    }

    private var footer: String {
        if let info, info.available {
            if choice.usesLive {
                let price = info.pricePerMinuteUsd.map {
                    " Kostet etwa \($0.formatted(.currency(code: "USD").locale(Locale(identifier: "de-DE")))) pro Minute."
                } ?? ""
                return "Im Sprechmodus spricht \(bot.name) live mit der natürlichen OpenAI-Stimme (GPT-Live-1), du kannst jederzeit dazwischenreden.\(price) Klappt Live nicht, liest die Gerätestimme vor."
            }
            return "\(bot.name) liest im Sprechmodus mit der Gerätestimme vor (ohne OpenAI, auch offline)."
        }
        if voices.isEmpty {
            return "Keine deutsche Stimme installiert. Lade in den Systemeinstellungen unter Bedienungshilfen → Gesprochene Inhalte eine Stimme (am besten „Premium“)."
        }
        let reason = info?.reason.map { "Live-Stimme: \($0) " } ?? ""
        return reason + "Damit liest \(bot.name) im Sprechmodus vor. „Erweitert“- und „Premium“-Stimmen klingen natürlicher (Bedienungshilfen → Gesprochene Inhalte)."
    }
}

// MARK: - Gruppenprofil

/// Profil einer Gruppe: Name, Mitglieder (2–6), Bibliothek, Verwalten.
struct GroupProfileView: View {
    let groupID: String
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = ProcessInfo.processInfo.arguments.contains("-library") ? .library : .group
    @State private var name = ""
    @State private var memberProfile: String?
    @State private var confirmReset = false
    @State private var confirmDelete = false
    @State private var showAdd = false
    /// Erst nach dem Einfahren alles aufbauen (siehe `ProfileSettle`)
    @State private var settled = false
    @State private var router = ProfileRouter()

    enum Tab: String, CaseIterable { case group = "Gruppe", library = "Bibliothek" }

    private var group: ChatGroup? { store.group(groupID) }

    var body: some View {
        // Gleicher Rahmen wie das Scoop-Profil: Schließen in einer festen Leiste statt über dem Inhalt
        ProfileStack(botID: groupID) {
            ProfileScaffold(page: nil) {
                if let group {
                    VStack(spacing: 0) {
                        VStack(spacing: 6) {
                            GroupAvatar(members: store.members(of: groupID), size: 104)
                                .padding(.top, 4)
                            Text(group.name).font(.system(size: 21, weight: .semibold)).foregroundStyle(theme.textPrimary)
                            Text("\(group.memberIds.count) Scoops").font(.system(size: 13.5)).foregroundStyle(theme.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        tabs.padding(.top, 14).padding(.bottom, 18)
                        if settled {
                            switch tab {
                            case .group: details(group)
                            case .library: LibraryList(chatID: groupID)
                            }
                        } else {
                            ProfileSettle.placeholder
                        }
                    }
                }
            }
        }
        .environment(router)
        #if os(iOS)
        .tint(theme.textPrimary)
        #endif
        .task { await ProfileSettle.wait(); settled = true }
        .onAppear {
            router.onClose = { [store, dismiss] in
                store.showInspector = false
                #if os(iOS)
                dismiss()
                #endif
            }
        }
        .onAppear { name = group?.name ?? "" }
        .onChange(of: groupID) { name = group?.name ?? "" }
        .sheet(item: Binding(get: { memberProfile.map(IdentifiedString.init) }, set: { memberProfile = $0?.id })) { item in
            ProfileView(botID: item.id)
                .environment(\.theme, theme)
                .environment(store)
                #if os(macOS)
                .frame(width: 340, height: 640)
                #endif
        }
        .confirmationDialog("Verlauf leeren?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Verlauf leeren", role: .destructive) { Task { await store.resetHistory(groupID) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Alle Nachrichten der Gruppe werden gelöscht. Die Scoops behalten ihr Gedächtnis.")
        }
        .confirmationDialog("„\(group?.name ?? "")“ löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Gruppe löschen", role: .destructive) { Task { await store.deleteGroup(groupID) } }
            Button("Abbrechen", role: .cancel) {}
        } message: {
            Text("Gruppe und Gruppenverlauf werden gelöscht. Die Scoops bleiben erhalten.")
        }
    }

    private var tabs: some View {
        HStack(spacing: 4) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button { withAnimation(.snappy(duration: 0.2)) { tab = t } } label: {
                    Text(t.rawValue)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tab == t ? theme.textPrimary : theme.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background { if tab == t { Capsule().fill(theme.selection) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func details(_ group: ChatGroup) -> some View {
        GroupedStack {
            GroupedSection("Name") {
                HStack {
                    TextField("Name der Gruppe", text: $name)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundStyle(theme.textPrimary)
                        .onSubmit(saveName)
                    if name.trimmingCharacters(in: .whitespaces) != group.name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
                        Button("Sichern", action: saveName).buttonStyle(PillButtonStyle(kind: .primary))
                    }
                }
                .groupedRow()
            }
            GroupedSection("Mitglieder", footer: "2 bis 6 Scoops. Antippen öffnet das Profil.", dividerInset: 60) {
                ForEach(store.members(of: groupID)) { bot in memberRow(bot, group: group) }
                if group.memberIds.count < CreateGroupView.maxMembers {
                    Menu {
                        ForEach(store.bots.filter { !group.memberIds.contains($0.id) }) { bot in
                            Button(bot.title) {
                                Task { await store.updateGroup(groupID, GroupPatch(memberIds: group.memberIds + [bot.id])) }
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 18)).foregroundStyle(theme.success)
                                .frame(width: 32)
                            Text("Scoop hinzufügen").font(.system(size: 15)).foregroundStyle(theme.textPrimary)
                            Spacer()
                        }
                        .groupedRow()
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .disabled(store.bots.allSatisfy { group.memberIds.contains($0.id) })
                }
            }
            GroupedSection("Verwalten", footer: "Beim Löschen bleiben alle Scoops erhalten.", dividerInset: 50) {
                Button { confirmReset = true } label: {
                    GroupedLabelRow(icon: "eraser", iconColor: theme.danger, title: "Verlauf leeren", titleColor: theme.danger)
                }
                .buttonStyle(.plain)
                Button { confirmDelete = true } label: {
                    GroupedLabelRow(icon: "trash", iconColor: theme.danger, title: "Gruppe löschen", titleColor: theme.danger)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func memberRow(_ bot: Bot, group: ChatGroup) -> some View {
        HStack(spacing: 10) {
            Button { memberProfile = bot.id } label: {
                HStack(spacing: 10) {
                    MascotView(mascot: bot.mascot, size: 32, mood: group.busyIds.contains(bot.id) ? .working : .idle,
                               seed: bot.id, animated: group.busyIds.contains(bot.id))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(bot.name).font(.system(size: 13.5, weight: .medium)).foregroundStyle(theme.textPrimary)
                        if let label = bot.label, !label.isEmpty {
                            Text(label).font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profil von \(bot.name)")
            Button {
                Task { await store.updateGroup(groupID, GroupPatch(memberIds: group.memberIds.filter { $0 != bot.id })) }
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(group.memberIds.count > CreateGroupView.minMembers ? theme.danger : theme.textTertiary)
            }
            .buttonStyle(.plain)
            .disabled(group.memberIds.count <= CreateGroupView.minMembers)
            .help(group.memberIds.count <= CreateGroupView.minMembers ? "Eine Gruppe braucht mindestens 2 Scoops" : "Aus der Gruppe entfernen")
            .accessibilityLabel("\(bot.name) entfernen")
        }
        .groupedRow(vertical: 7)
    }

    private func saveName() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != group?.name else { return }
        Task { await store.updateGroup(groupID, GroupPatch(name: n)) }
    }


}

struct IdentifiedString: Identifiable { let id: String }
