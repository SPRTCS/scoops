import SwiftUI

/// Schritt 1: Was Scoops sind, in drei kurzen Seiten mit den Maskottchen. Überspringbar (Kopfzeile).
struct OnboardingWelcomeStep: View {
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pageCount = 3

    var body: some View {
        let onboarding = store.onboarding
        let page = min(onboarding.welcomePage, pageCount - 1)
        OnboardingPage {
            Group {
                switch page {
                case 0: firstPage
                case 1: homePage
                default: planPage
                }
            }
            .id(page)
            .transition(.opacity.combined(with: .offset(x: reduceMotion ? 0 : 24)))
            #if os(iOS)
            .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                if value.translation.width < -60, page < pageCount - 1 { turn(to: page + 1) }
                if value.translation.width > 60, page > 0 { turn(to: page - 1) }
            })
            #endif
            if page == 0 { OnboardingAlternatives() }
        } actions: {
            pageDots(page)
            Button {
                if page < pageCount - 1 { turn(to: page + 1) } else { onboarding.advance() }
            } label: {
                Text(page < pageCount - 1 ? "Weiter" : "Los geht’s")
            }
            .buttonStyle(OnboardingButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .animation(.smooth(duration: 0.3), value: page)
    }

    private func turn(to page: Int) {
        store.onboarding.welcomePage = page
    }

    private func pageDots(_ page: Int) -> some View {
        HStack(spacing: 7) {
            ForEach(0..<pageCount, id: \.self) { i in
                Circle()
                    .fill(i == page ? theme.textPrimary : theme.surfaceBorder)
                    .frame(width: 7, height: 7)
            }
        }
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Seite \(page + 1) von \(pageCount)")
    }

    // MARK: Seiten

    private var firstPage: some View {
        VStack(spacing: 22) {
            // Key Visual aus dem Marketing (hell/dunkel passend zum Erscheinungsbild der App)
            // Höchstens gut die Hälfte der sichtbaren Höhe: Auf niedrigen Bildschirmen (iPhone Duo aufgeklappt, 669 pt
            // hoch, oder zugeklappt) schob das Bild sonst Überschrift und Text unter die Knöpfe.
            Image(theme.kind == .nacht ? "WelcomeKeyvisualDark" : "WelcomeKeyvisualLight")
                .resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).strokeBorder(theme.surfaceBorder))
                .frame(maxWidth: 360)
                .containerRelativeFrame(.vertical) { height, _ in min(360, max(180, height * 0.52)) }
                .padding(.top, 12)
                .accessibilityLabel("AIS Scoops: sieben flauschige Scoops in verschiedenen Formen und Farben")
            OnboardingTitle(title: "Willkommen!",
                            text: "Scoops sind kleine KI-Helfer mit Namen, Charakter und Gedächtnis. Sie recherchieren, schreiben, erinnern dich an Dinge und arbeiten auf Wunsch an deinem Mac.")
        }
    }

    private var homePage: some View {
        VStack(spacing: 22) {
            HStack(alignment: .bottom, spacing: 14) {
                ScoopFigureView(figure: .blauWolke, size: 84)
                Image(systemName: "desktopcomputer")
                    .appFont(64, weight: .light)
                    .foregroundStyle(theme.textSecondary)
                    .padding(.bottom, 6)
                ScoopFigureView(figure: .gelbBarett, size: 74)
            }
            .padding(.top, 24)
            .accessibilityHidden(true)
            OnboardingTitle(title: "Sie wohnen auf deinem Mac",
                            text: "Deine Scoops laufen in der App „AIS Scoops Server“ auf deinem eigenen Mac. iPhone, iPad und Mac verbinden sich direkt mit ihm.")
            VStack(spacing: 12) {
                OnboardingInfoCard(icon: "lock.shield", tint: theme.success, title: "Deine Daten bleiben bei dir",
                                   text: "Chats, Erinnerungen und API-Schlüssel liegen nur auf deinem Mac.")
                OnboardingInfoCard(icon: "iphone.and.arrow.forward", title: "Überall dabei",
                                   text: "Schreib deinen Scoops vom iPhone, iPad oder Mac aus, auch von unterwegs.")
            }
        }
    }

    private var planPage: some View {
        VStack(spacing: 22) {
            WelcomeCrew(scale: 0.7).padding(.top, 24)
            OnboardingTitle(title: "So geht’s los", text: "Wir machen das zusammen, Schritt für Schritt.")
            VStack(alignment: .leading, spacing: 16) {
                OnboardingNumberedRow(number: 1, text: "Mit Apple anmelden")
                OnboardingNumberedRow(number: 2, text: "Deinen Mac als Server verbinden")
                OnboardingNumberedRow(number: 3, text: "Deinen ersten Scoop gestalten")
                OnboardingNumberedRow(number: 4, text: "Ihm die erste Nachricht schreiben")
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .themedCard(theme, radius: 20)
            Text("Mit einem eingerichteten Mac dauert das etwa fünf Minuten.")
                .font(.footnote)
                .foregroundStyle(theme.textTertiary)
                .multilineTextAlignment(.center)
        }
    }
}

/// Schritt 2: Mit Apple anmelden (bestehender Knopf). Angemeldet: Bestätigung mit „Weiter“.
struct OnboardingSignInStep: View {
    var mode: OnboardingFlowView.Mode = .guided
    @Environment(AppStore.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        let account = store.account
        OnboardingPage {
            if let user = account.user {
                signedIn(user)
            } else {
                signedOut
                OnboardingAlternatives()
            }
        } actions: {
            if account.isSignedIn {
                Button("Weiter") { store.onboarding.go(to: .server) }
                    .buttonStyle(OnboardingButtonStyle())
                    .keyboardShortcut(.defaultAction)
            } else if mode == .guided, store.phase == .online {
                // Schon per Token verbunden (z. B. „Einführung erneut ansehen“): Konto ist optional
                Button("Ohne Konto weiter") { store.onboarding.go(to: .server) }
                    .buttonStyle(OnboardingButtonStyle(kind: .secondary))
            }
        }
    }

    private var signedOut: some View {
        VStack(spacing: 22) {
            WelcomeCrew(scale: 0.8).padding(.top, 24)
            OnboardingTitle(title: "Melde dich an",
                            text: "Mit deinem Konto findet die App deinen Server, auf jedem deiner Geräte. Ohne neues Passwort, einfach mit deiner Apple-ID.")
            VStack(spacing: 14) {
                AppleSignInButton()
                if let error = store.account.errorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(.footnote)
                        .foregroundStyle(theme.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "lock.shield")
                        .font(.system(.subheadline, weight: .medium))
                        .foregroundStyle(theme.success)
                        .accessibilityHidden(true)
                    Text("Dein Konto kennt nur Name, E-Mail und deine Server. Chats, Erinnerungen und API-Schlüssel bleiben auf deinem eigenen Mac.")
                        .font(.footnote)
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
            .themedCard(theme, radius: 20)
            .frame(maxWidth: 440)
        }
    }

    private func signedIn(_ user: CloudUser) -> some View {
        VStack(spacing: 22) {
            AccountAvatar(user: user, size: 84).padding(.top, 36)
            OnboardingTitle(title: "Du bist angemeldet", text: "Als \(user.email ?? user.displayName). Als Nächstes verbinden wir deinen Server.")
            Button("Abmelden") { Task { await store.account.signOut() } }
                .buttonStyle(.plain)
                .font(.system(.subheadline, weight: .medium))
                .foregroundStyle(theme.accent)
        }
    }
}
