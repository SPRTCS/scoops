import SwiftUI

// Eigene Nachricht bearbeiten (App 1.3): Kontextmenü „Bearbeiten“ an der jüngsten eigenen Nachricht bzw.
// „Erneut senden …“ an älteren (Logik in AppStore+Suche.swift). Hier: der Hinweis-Chip über dem Eingabefeld und
// die Kennzeichnung „Bearbeitet“ unter der Blase.

/// Hinweis über dem Eingabefeld, solange eine Nachricht bearbeitet wird: Stift, „Nachricht bearbeiten“, der
/// bisherige Text und ein Knopf zum Abbrechen (auch Esc).
struct EditComposerBar: View {
    let target: ComposerDraft.EditTarget
    var onCancel: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "pencil")
                .appFont(13, weight: .semibold)
                .foregroundStyle(theme.accent)
                .scaledFrame(width: 22)
                .accessibilityHidden(true)
            Capsule().fill(theme.accent).frame(width: 3, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nachricht bearbeiten")
                    .appFont(12.5, weight: .semibold)
                    .foregroundStyle(theme.textPrimary)
                Text(MarkdownText.plain(target.original))
                    .appFont(13)
                    .foregroundStyle(theme.textSecondary)
            }
            .adaptiveLineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .appFont(11, weight: .bold)
                    .foregroundStyle(theme.textSecondary)
                    .scaledFrame(26)
                    .background(theme.hover, in: Circle())
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Bearbeiten abbrechen (Esc)")
            .accessibilityLabel("Bearbeiten abbrechen")
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 7)
        .background(theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.surfaceBorder))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Nachricht bearbeiten")
    }
}

/// „Bearbeitet“ unter einer nachträglich geänderten Nachricht.
struct EditedLabel: View {
    @Environment(\.theme) private var theme

    var body: some View {
        Label("Bearbeitet", systemImage: "pencil")
            .appFont(11, weight: .medium)
            .foregroundStyle(theme.textTertiary)
            .padding(.horizontal, 4)
            .accessibilityLabel("Bearbeitet")
    }
}
