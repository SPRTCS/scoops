import SwiftUI
#if canImport(UIKit)
import UIKit
typealias PlatformImage = UIImage
#else
import AppKit
typealias PlatformImage = NSImage
#endif

extension Image {
    init(platformImage: PlatformImage) {
        #if canImport(UIKit)
        self.init(uiImage: platformImage)
        #else
        self.init(nsImage: platformImage)
        #endif
    }
}

/// Lädt Bildschirmfotos robust: höchstens eine Anfrage gleichzeitig, kurzer Timeout, automatisches
/// Wiederverbinden mit Rückfall (2 s, 3 s, 5 s, 8 s, dann alle 10 s), optional adaptive Größe/Qualität
/// (Übernahme). Das letzte gute Bild bleibt erhalten.
///
/// Die Schleife endet nur, wenn ihre Task abgebrochen wird (Fenster zu bzw. `restart`). Fehlt kurzzeitig
/// die Serververbindung (z. B. während die App neu verbindet), wartet sie, statt still zu enden.
@Observable
final class ScreenFeed {
    enum Status: Equatable {
        /// erster Abruf bzw. „Neu versuchen“ gedrückt
        case connecting
        case live
        /// kurzer Aussetzer, letztes Bild bleibt stehen
        case reconnecting
        /// mehrere Fehlschläge – Hinweis mit „Neu versuchen“, im Hintergrund wird weiter versucht
        case failed
    }

    private(set) var image: PlatformImage?
    private(set) var status: Status = .connecting
    /// aktuelle Stufe (für adaptive Übernahme)
    private(set) var scale: Double
    private var quality: Int
    /// Während der Übernahme: Größe/Qualität an die Verbindung anpassen
    var adaptive: Bool {
        didSet { if adaptive && !oldValue { scale = 0.6; quality = 50 } }
    }
    @ObservationIgnored private var failures = 0
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var loopInterval: Double = 1.5

    init(scale: Double, quality: Int = 50, adaptive: Bool = false) {
        self.scale = scale
        self.quality = quality
        self.adaptive = adaptive
    }

    /// Rückfall nach `n` Fehlschlägen in Folge.
    nonisolated static func backoff(after n: Int) -> Double {
        switch n {
        case ...1: 2
        case 2: 3
        case 3: 5
        case 4: 8
        default: 10
        }
    }

    /// Startet die Abruf-Schleife (bricht eine laufende vorher ab).
    func start(store: AppStore, interval: Double) {
        loopInterval = interval
        loop?.cancel()
        loop = Task { [weak self] in await self?.run(store: store) }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// „Neu versuchen“: laufenden Abruf und Wartezeit abbrechen, Fehlerzustand zurücksetzen, sichtbar
    /// „Verbinde …“ zeigen, Rechner-Zustand neu abfragen und sofort neu laden.
    func restart(store: AppStore) {
        failures = 0
        status = .connecting
        Task { await store.refreshComputer() }
        start(store: store, interval: loopInterval)
    }

    private func run(store: AppStore) async {
        while !Task.isCancelled {
            let started = Date()
            do {
                if let img = try await store.fetchScreen(scale: scale, quality: quality) { image = img }
                if Task.isCancelled { return }
                let recovered = failures > 0
                status = .live
                failures = 0
                // Nach einem Ausfall (z. B. Server-Neustart) auch den Rechner-Zustand auffrischen
                if recovered { Task { await store.refreshComputer() } }
                if adaptive { adapt(duration: Date().timeIntervalSince(started)) }
                try? await Task.sleep(for: .seconds(loopInterval))
            } catch {
                if Task.isCancelled { return }
                failures += 1
                if status != .connecting || failures >= 2 {
                    status = failures >= 2 ? .failed : (image == nil ? .connecting : .reconnecting)
                }
                if adaptive { scale = 0.5; quality = 40 }
                // Ab und zu den Zustand neu abfragen (z. B. eingeschlafen ↔ wach)
                if failures % 3 == 0 { Task { await store.refreshComputer() } }
                try? await Task.sleep(for: .seconds(Self.backoff(after: failures)))
            }
        }
    }

    private func adapt(duration: TimeInterval) {
        if duration > 0.7 {
            scale = max(0.5, scale - 0.1); quality = 40
        } else if duration < 0.3 {
            scale = min(0.8, scale + 0.1); quality = 50
        }
    }
}

/// Live-Bild des Bot-Rechners (`screen.jpg?scale=…&q=…&token=…`), solange sichtbar.
/// Kleine Miniaturen laden mit `scale` 0,4, die Vollansicht mit 0,6, während der Übernahme adaptiv.
struct ScreenThumbnail: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    var cornerRadius: CGFloat = 10
    var live: Bool = true
    var interval: Double = 1.5
    var scale: Double = 0.4
    var adaptive: Bool = false

    @State private var feed: ScreenFeed?
    /// Rechner, zu dem `feed` gehört (beim Wechsel neu aufbauen, kein altes Bild zeigen)
    @State private var feedNode: String?

    /// Rechner offline oder pausiert (nur Scoops-Connect-Rechner melden das ausdrücklich)
    private var unavailable: Bool { store.computer.online == false || store.computer.paused == true }

    var body: some View {
        let size = store.computer.screenSize
        ZStack {
            if store.isMock {
                MockScreenView()
                    .opacity(feed == nil || feed?.status == .live ? 1 : 0.45)
            } else if let image = feed?.image {
                Image(platformImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .opacity(feed?.status == .live ? 1 : 0.45)
            } else {
                theme.surfaceRaised
            }
            if feed != nil || (store.isMock && unavailable) { overlay }
        }
        .aspectRatio(size.width / max(size.height, 1), contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(theme.surfaceBorder))
        .task(id: "\(live)-\(interval)-\(adaptive)-\(store.computerNodeID)") {
            if feedNode != store.computerNodeID {
                feed?.stop()
                feed = nil
                feedNode = store.computerNodeID
            }
            // Demo-Modus: nur mit simuliertem Ausfall (`-screenfaildemo`) über die echte Abruf-Schleife
            guard live, !store.isMock || store.mockScreenOutage != nil else { feed?.stop(); return }
            if feed == nil { feed = ScreenFeed(scale: scale, adaptive: adaptive) }
            feed?.adaptive = adaptive
            feed?.start(store: store, interval: interval)
        }
        .onDisappear { feed?.stop() }
    }

    @ViewBuilder
    private var overlay: some View {
        let compact = cornerRadius < 12
        let name = store.nodeName(store.computerNodeID)
        if store.computer.online == false {
            stateBox(icon: "powersleep", text: "„\(name)“ ist offline", button: "Erneut prüfen", compact: compact,
                     detail: "Scoops Connect auf dem Mac öffnen. Die App verbindet sich dann von selbst.")
        } else if store.computer.paused == true {
            stateBox(icon: "pause.circle", text: "„\(name)“ ist pausiert", button: "Erneut prüfen", compact: compact,
                     detail: "Auf dem Mac in Scoops Connect fortsetzen.")
        } else if store.computer.state == "asleep" && feed?.status != .live {
            stateBox(icon: "moon.zzz", text: "\(name) schläft", button: "Aufwecken", compact: compact)
        } else {
            switch feed?.status ?? .connecting {
            case .connecting:
                if compact {
                    ProgressView().controlSize(.small)
                } else {
                    statusPill("Verbinde …", compact: compact)
                }
            case .reconnecting:
                statusPill("Verbinde neu …", compact: compact)
            case .failed:
                stateBox(icon: "wifi.exclamationmark", text: "Keine Verbindung zu „\(name)“", button: "Neu versuchen", compact: compact)
            case .live:
                EmptyView()
            }
        }
    }

    private func statusPill(_ text: LocalizedStringKey, compact: Bool) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini).tint(.white)
            Text(text)
        }
        .appFont(compact ? 9 : 12, weight: .semibold)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.black.opacity(0.55), in: Capsule())
        .foregroundStyle(.white)
    }

    @ViewBuilder
    private func stateBox(icon: String, text: LocalizedStringKey, button: LocalizedStringKey, compact: Bool,
                          detail: LocalizedStringKey = "Wird automatisch weiter versucht.") -> some View {
        if compact {
            Image(systemName: icon)
                .appFont(13, weight: .semibold)
                .foregroundStyle(theme.textSecondary)
        } else {
            VStack(spacing: 8) {
                Image(systemName: icon).appFont(22)
                Text(text).appFont(13, weight: .semibold)
                Text(detail)
                    .appFont(11.5).foregroundStyle(theme.textSecondary)
                    .multilineTextAlignment(.center)
                Button(button) {
                    if let feed { feed.restart(store: store) } else { Task { await store.refreshComputer() } }
                }
                    .buttonStyle(PillButtonStyle(kind: .primary))
            }
            .foregroundStyle(theme.textPrimary)
            .padding(14)
            .background(theme.surfaceRaised.opacity(0.92), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }
}

/// Vollbild des Bot-Bildschirms mit „Übernehmen“ (Maus, Gesten, Tastatur) und „Zurückgeben“.
struct ScreenViewer: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @Environment(AppStore.self) private var store
    var botName: String

    @State private var working = false
    @State private var error: String?
    @State private var showKeyboard = false
    @State private var typed = ""
    @State private var didTakeOver = false
    @State private var zoom: CGFloat = 1
    @GestureState private var pinch: CGFloat = 1
    @FocusState private var keyboardFocused: Bool

    private var controlling: Bool { store.computer.isUserControlling }

    var body: some View {
        VStack(spacing: 14) {
            header
            // Umschalter in eigener Zeile, damit die Kopfzeile auch auf dem iPhone passt
            if store.nodes.count > 1 {
                HStack {
                    ComputerNodeSwitcher(disabled: controlling || working)
                    Spacer(minLength: 0)
                }
            }
            if controlling { controlBanner }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .appFont(13)
                    .foregroundStyle(theme.warning)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(theme.warning.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            screen
            if controlling && showKeyboard { keyboardBar }
            Spacer(minLength: 0)
        }
        .padding(20)
        #if os(macOS)
        .frame(minWidth: 640, idealWidth: 960, minHeight: 520, idealHeight: 780)
        #endif
        .background(theme.background)
        .onDisappear {
            // Beim Schließen immer zurückgeben
            if didTakeOver || controlling { Task { await store.releaseComputer() } }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(botName.isEmpty ? store.nodeName(store.computerNodeID) : String(localized: "Bildschirm von \(botName)"))
                    .font(.headline).foregroundStyle(theme.textPrimary)
                Text(subtitle)
                    .font(.caption).foregroundStyle(theme.textSecondary)
                    .adaptiveLineLimit(1)
            }
            Spacer()
            if controlling {
                Button {
                    showKeyboard.toggle()
                    keyboardFocused = showKeyboard
                } label: {
                    Label("Tastatur", systemImage: "keyboard")
                }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                Button("Zurückgeben") { release() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .disabled(working)
            } else if store.computerAccess(store.selectedChatID).canControl {
                Button { takeOver() } label: {
                    HStack(spacing: 6) {
                        if working { ProgressView().controlSize(.small) }
                        // Eigener Schlüssel: „Übernehmen“ heißt hier „Steuerung übernehmen“ (englisch „Take Over“),
                        // sonst „Anwenden“ (englisch „Apply“)
                        Label(String(localized: "computer.takeOver", defaultValue: "Übernehmen",
                                     comment: "Bildschirm des Rechners: die Steuerung übernehmen (englisch „Take Over“)"),
                              systemImage: "cursorarrow.click.2")
                    }
                    .lineLimit(1)
                    .fixedSize()
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .disabled(working || store.computer.online == false || store.computer.paused == true)
            } else {
                // Geteilter Scoop mit Rechner-Stufe „Zusehen“
                Label("Nur zusehen", systemImage: "eye")
                    .appFont(13, weight: .medium)
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Button("Fertig") { dismiss() }
                .buttonStyle(PillButtonStyle(kind: .secondary))
                .keyboardShortcut(.cancelAction)
        }
    }

    private var subtitle: String {
        // Der Rechner selbst steht im Umschalter darunter (bei mehreren Rechnern)
        if controlling { return String(localized: "Live · du steuerst") }
        if store.computer.online == false || store.computer.paused == true { return store.computer.displayText }
        return String(localized: "Live, aktualisiert alle 1,5 Sekunden · \(store.computer.displayText)")
    }

    private var controlBanner: some View {
        HStack(spacing: 8) {
            Circle().fill(theme.danger).frame(width: 8, height: 8)
            Text("Du steuerst").appFont(13, weight: .semibold)
            Text("Scoops, die den Rechner brauchen, warten, bis du zurückgibst.")
                .appFont(12).foregroundStyle(theme.textSecondary)
                .adaptiveLineLimit(1)
            Spacer(minLength: 0)
        }
        .foregroundStyle(theme.textPrimary)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(theme.accent.opacity(0.12), in: Capsule())
    }

    private var screen: some View {
        ScreenThumbnail(cornerRadius: 14, interval: controlling ? 0.33 : 1.5, scale: 0.6, adaptive: controlling)
            .overlay {
                if controlling {
                    RemoteSurface { event in handle(event) }
                }
            }
            .scaleEffect(zoom * pinch)
            .gesture(
                MagnifyGesture()
                    .updating($pinch) { value, state, _ in state = value.magnification }
                    .onEnded { value in zoom = min(3, max(1, zoom * value.magnification)) }
            )
            // simultan: Der Doppeltipp zum Zoomen darf Knöpfe im Bild („Neu versuchen“, „Aufwecken“) nicht schlucken
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                if !controlling { withAnimation(.snappy) { zoom = zoom > 1 ? 1 : 2 } }
            })
            .animation(.snappy(duration: 0.2), value: zoom)
            .clipped()
    }

    private var keyboardBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("Text eingeben und mit Return senden", text: $typed)
                    .textFieldStyle(.plain)
                    .focused($keyboardFocused)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit {
                        if !typed.isEmpty { store.sendComputerInput(.type(typed)) }
                        store.sendComputerInput(.key("return"))
                        typed = ""
                        keyboardFocused = true
                    }
                    .modifier(FieldStyle(alignment: .leading))
                Button("Senden") {
                    guard !typed.isEmpty else { return }
                    store.sendComputerInput(.type(typed))
                    typed = ""
                }
                .buttonStyle(PillButtonStyle(kind: .primary))
            }
            ScrollView(.horizontal) {
                HStack(spacing: 6) {
                    ForEach([("⏎", "return"), ("⌫", "backspace"), ("⇥", "tab"), ("Esc", "escape"),
                             ("←", "left"), ("↑", "up"), ("↓", "down"), ("→", "right"),
                             ("⌘C", "super+c"), ("⌘V", "super+v"), ("⌘A", "super+a"), ("⌘Z", "super+z")], id: \.1) { label, key in
                        Button(label) { store.sendComputerInput(.key(key)) }
                            .buttonStyle(PillButtonStyle(kind: .secondary))
                    }
                }
            }
            .scrollIndicators(.never)
        }
    }

    /// Normierte Position (0…1) → Bildschirmpunkte des Bot-Rechners.
    private func point(_ p: CGPoint) -> CGPoint {
        let size = store.computer.screenSize
        return CGPoint(x: p.x * size.width, y: p.y * size.height)
    }

    private func handle(_ event: RemoteEvent) {
        switch event {
        case .click(let p, let mods): store.sendComputerInput(.click(point(p), modifiers: mods))
        case .doubleClick(let p): store.sendComputerInput(.click(point(p), double: true))
        case .rightClick(let p): store.sendComputerInput(.click(point(p), right: true))
        case .drag(let a, let b): store.sendComputerInput(.drag(from: point(a), to: point(b)))
        case .scroll(let p, let dir, let amount): store.sendComputerInput(.scroll(at: point(p), direction: dir, amount: amount))
        case .type(let text): store.sendComputerInput(.type(text))
        case .key(let key): store.sendComputerInput(.key(key))
        }
    }

    private func takeOver() {
        working = true
        error = nil
        Task {
            if let message = await store.takeOverComputer() {
                error = message
            } else {
                didTakeOver = true
                zoom = 1
            }
            working = false
        }
    }

    private func release() {
        working = true
        Task {
            await store.releaseComputer()
            didTakeOver = false
            showKeyboard = false
            working = false
        }
    }
}

/// Erfundener Bildschirm für den Demo-Modus (Browser mit Hotelsuche).
struct MockScreenView: View {
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(hex: "#2B3A67"), Color(hex: "#7D5BA6")], startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack(spacing: 0) {
                    HStack(spacing: w * 0.01) {
                        ForEach(["#FF5F57", "#FEBC2E", "#28C840"], id: \.self) { c in
                            Circle().fill(Color(hex: c)).frame(width: w * 0.018, height: w * 0.018)
                        }
                        RoundedRectangle(cornerRadius: w * 0.01)
                            .fill(Color(hex: "#E9E9EC"))
                            .frame(height: w * 0.035)
                            .overlay(alignment: .leading) {
                                Text(verbatim: demoText("booking.com/köln-deutz", en: "booking.com/boston"))
                                    .font(.fixed(max(5, w * 0.022)))
                                    .foregroundStyle(Color(hex: "#555")).padding(.leading, w * 0.015)
                            }
                    }
                    .padding(w * 0.015)
                    .background(Color(hex: "#F6F6F8"))
                    HStack(alignment: .top, spacing: w * 0.02) {
                        VStack(alignment: .leading, spacing: w * 0.012) {
                            ForEach(0..<4) { i in
                                HStack(spacing: w * 0.015) {
                                    RoundedRectangle(cornerRadius: w * 0.008)
                                        .fill(Color(hex: ["#8DB3E2", "#E2B38D", "#9AD1B5", "#C7A8E0"][i]))
                                        .frame(width: w * 0.12, height: w * 0.08)
                                    VStack(alignment: .leading, spacing: w * 0.008) {
                                        Capsule().fill(Color(hex: "#3A3A3F")).frame(width: w * 0.3, height: w * 0.014)
                                        Capsule().fill(Color(hex: "#B5B5BA")).frame(width: w * 0.22, height: w * 0.011)
                                        Capsule().fill(Color(hex: "#2E7D32")).frame(width: w * 0.08, height: w * 0.011)
                                    }
                                }
                            }
                        }
                        RoundedRectangle(cornerRadius: w * 0.01)
                            .fill(Color(hex: "#DDE7F3"))
                            .overlay(Image(systemName: "map").font(.fixed(w * 0.06)).foregroundStyle(Color(hex: "#7E95B4")))
                    }
                    .padding(w * 0.025)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .background(Color.white)
                }
                .clipShape(RoundedRectangle(cornerRadius: w * 0.015))
                .padding(w * 0.04)
            }
        }
    }
}
