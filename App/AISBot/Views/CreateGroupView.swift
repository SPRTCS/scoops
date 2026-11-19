import SwiftUI

/// „Neue Gruppe“: Name und 2 bis 6 Scoops auswählen.
struct CreateGroupView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var selected: [String] = []
    @State private var saving = false
    @FocusState private var nameFocused: Bool

    static let minMembers = 2
    static let maxMembers = 6

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && (Self.minMembers...Self.maxMembers).contains(selected.count) && !saving
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Neue Gruppe").font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.textPrimary)
                Spacer()
                CircleIconButton(systemName: "xmark", help: "Abbrechen", size: 28) { dismiss() }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            Divider().overlay(theme.surfaceBorder)

            ScrollView {
                VStack(spacing: 20) {
                    GroupAvatar(members: selected.compactMap { store.bot($0) }, size: 120)
                        .frame(height: 130)
                        .overlay {
                            if selected.isEmpty {
                                Image(systemName: "person.3")
                                    .font(.system(size: 40, weight: .light))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .animation(.spring(duration: 0.35, bounce: 0.35), value: selected)
                        .padding(.top, 6)

                    TextField("Name der Gruppe", text: $name)
                        .focused($nameFocused)
                        .multilineTextAlignment(.center)
                        .modifier(FieldStyle())

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Scoops").font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.textSecondary)
                            Spacer()
                            Text("\(selected.count) von 2–6")
                                .font(.system(size: 12))
                                .foregroundStyle(selected.count > Self.maxMembers ? theme.danger : theme.textTertiary)
                                .monospacedDigit()
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 8)], spacing: 8) {
                            ForEach(store.bots) { bot in memberCell(bot) }
                        }
                    }

                    Text("Sprich einzelne Scoops mit @Name an oder alle mit @alle. Ohne Erwähnung antwortet, wer am besten passt.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 18)
            }

            Divider().overlay(theme.surfaceBorder)
            HStack(spacing: 10) {
                Spacer()
                Button("Abbrechen") { dismiss() }
                    .buttonStyle(PillButtonStyle(kind: .secondary))
                    .keyboardShortcut(.cancelAction)
                Button("Erstellen") { save() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(!canSave)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(theme.background)
        #if os(macOS)
        .frame(width: 460, height: 620)
        #endif
        .onAppear { nameFocused = true }
    }

    private func memberCell(_ bot: Bot) -> some View {
        let isOn = selected.contains(bot.id)
        let full = selected.count >= Self.maxMembers && !isOn
        return Button {
            withAnimation(.snappy(duration: 0.2)) {
                if isOn { selected.removeAll { $0 == bot.id } } else if !full { selected.append(bot.id) }
            }
        } label: {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    MascotView(mascot: bot.mascot, size: 52, seed: bot.id, animated: false)
                    Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(isOn ? theme.accent : theme.textTertiary)
                        .background(Circle().fill(theme.background).padding(2))
                        .offset(x: 6, y: -2)
                }
                Text(bot.name).font(.system(size: 12.5, weight: .medium)).foregroundStyle(theme.textPrimary).lineLimit(1)
            }
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(isOn ? theme.selection : .clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(full ? 0.4 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(full)
        .accessibilityLabel(bot.name)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }

    private func save() {
        guard !saving else { return }
        saving = true
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        store.createGroupInBackground(name: n, memberIDs: selected)
        dismiss()
    }
}
