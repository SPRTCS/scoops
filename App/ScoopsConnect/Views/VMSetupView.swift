import SwiftUI

/// Einrichtung für den Modus „Abgeschirmte VM“: Lume prüfen/installieren, VM wählen oder anlegen, starten.
struct VMSetupView: View {
    let model: AppModel
    @State private var newName = LumeManager.defaultVMName
    @State private var showCreate = false

    private var lume: LumeManager { model.lume }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if lume.lumePath == nil {
                lumeMissing
            } else {
                HStack {
                    Label("Lume \(lume.lumeVersion ?? "")", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                        .font(.callout)
                    Spacer()
                    Button {
                        Task { await lume.refresh() }
                    } label: {
                        Label("Aktualisieren", systemImage: "arrow.clockwise")
                    }
                    .disabled(lume.isBusy)
                }
                vmList
                createSection
            }
            phaseView
        }
        .task { await lume.refresh() }
    }

    private var lumeMissing: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Lume ist nicht installiert", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.headline)
            Text("Lume betreibt die virtuelle Maschine. Scoops Connect installiert es über Homebrew (`brew install lume`).")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Lume installieren") { lume.installLume() }
                .disabled(lume.isBusy || LumeManager.brewPath == nil)
            if LumeManager.brewPath == nil {
                Text("Homebrew fehlt – zuerst von brew.sh installieren.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var vmList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Virtuelle Maschinen").font(.headline)
            if lume.vms.isEmpty {
                Text("Noch keine VM vorhanden.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(lume.vms) { vm in
                VMRow(vm: vm, selected: model.vmName == vm.name, ready: model.vmName == vm.name && lume.baseURL != nil) {
                    model.vmName = vm.name
                }
            }
            if !model.vmName.isEmpty, !LumeManager.protectedNames.contains(model.vmName),
               lume.vms.contains(where: { $0.name == model.vmName }) {
                HStack {
                    Button(lume.baseURL != nil ? "Neu verbinden" : "VM starten") { model.startVM(model.vmName) }
                        .buttonStyle(.borderedProminent)
                        .disabled(lume.isBusy)
                    if lume.isBusy {
                        Button("Abbrechen") { lume.cancel() }
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private var createSection: some View {
        DisclosureGroup("Neue VM aus dem Cua-macOS-Image anlegen", isExpanded: $showCreate) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Lädt `\(LumeManager.cuaImage)` (macOS mit vorinstalliertem Computer-Server). Großer Download – mehrere Dutzend GB, je nach Leitung eine Weile.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    TextField("Name", text: $newName)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                    Button("Anlegen") {
                        let name = newName
                        lume.createVM(named: name)
                        model.vmName = name
                    }
                    .disabled(lume.isBusy || !LumeManager.isValidName(newName))
                }
            }
            .padding(.top, 6)
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch lume.phase {
        case .idle:
            EmptyView()
        case .working(let text):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(text).font(.callout)
                }
                if let last = lume.log.last {
                    Text(last).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        case .ready(let url):
            Label("Computer-Server der VM bereit (\(url.host() ?? ""))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .failed(let text):
            Label(text, systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct VMRow: View {
    let vm: LumeManager.VM
    let selected: Bool
    let ready: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 10) {
                Image(systemName: vm.isProtected ? "lock.fill" : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(vm.isProtected ? Color.secondary : (selected ? Color.accentColor : Color.secondary))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.name).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                StatusDot(color: vm.isRunning ? .green : .secondary)
                Text(vm.isRunning ? "läuft" : "aus").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .contentShape(.rect)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected && !vm.isProtected ? Color.accentColor.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(vm.isProtected)
        .help(vm.isProtected ? String(localized: "Diese VM nutzt der AIS-Scoops-Server direkt. Scoops Connect startet, stoppt oder verändert sie nicht.") : "")
    }

    private var subtitle: String {
        if vm.isProtected { return String(localized: "Vom Server direkt genutzt – nur Anzeige") }
        var parts: [String] = []
        if let d = vm.display { parts.append(d) }
        if let ip = vm.ip, vm.isRunning { parts.append(ip) }
        if ready { parts.append(String(localized: "verbunden", comment: "VM: mit dem Computer-Server verbunden")) }
        return parts.joined(separator: " · ")
    }
}
