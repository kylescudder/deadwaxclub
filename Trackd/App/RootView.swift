import SwiftUI

struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @State private var publicListToken: String?

    var body: some View {
        Group {
            switch services.auth.state {
            case .unknown:
                LoadingView()
            case .signedOut:
                NavigationStack { SignInView() }
            case .signedIn:
                MainTabView()
                    .sheet(item: Binding(
                        get: { services.onboarding.current },
                        set: { _ in }
                    )) { step in
                        onboardingSheet(for: step)
                            .presentationDetents([.large])
                    }
            }
        }
        .task { await services.auth.bootstrap() }
        .onChange(of: services.profile.profile?.displayName) { _, _ in
            services.evaluateOnboarding()
        }
        .onOpenURL { url in handle(url: url) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { handle(url: url) }
        }
        .sheet(item: Binding(
            get: { publicListToken.map(PublicListPresentation.init) },
            set: { publicListToken = $0?.token }
        )) { presentation in
            NavigationStack { PublicListView(token: presentation.token) }
        }
        .animation(.easeInOut(duration: 0.2), value: services.auth.state)
    }

    private func handle(url: URL) {
        // Public list share link: https://trackd.app/l/<token> or trackd://list/<token>
        if url.host == "trackd.app", url.pathComponents.count >= 3, url.pathComponents[1] == "l" {
            publicListToken = url.pathComponents[2]
            return
        }
        if url.scheme == "trackd", url.host == "list", let token = url.pathComponents.last, !token.isEmpty {
            publicListToken = token
            return
        }
        // Otherwise pass to auth (OAuth callback).
        Task { await services.auth.handle(callbackURL: url) }
    }

    @ViewBuilder
    private func onboardingSheet(for step: OnboardingStep) -> some View {
        switch step {
        case .displayName:
            DisplayNameOnboardingView { name in
                Task {
                    await services.profile.updateDisplayName(name)
                    services.evaluateOnboarding()
                }
            }
        case .discogsToken:
            DiscogsTokenOnboardingView(
                onDone: {
                    services.onboarding.markDiscogsTokenSeen()
                    services.evaluateOnboarding()
                },
                onSkip: {
                    services.onboarding.markDiscogsTokenSeen()
                    services.evaluateOnboarding()
                }
            )
        case .enableNotifications:
            EnableNotificationsView {
                services.onboarding.markNotificationsSeen()
                services.evaluateOnboarding()
            }
        }
    }
}

private struct PublicListPresentation: Identifiable {
    let token: String
    var id: String { token }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { RecordsListView() }
                .tabItem { Label("Records", systemImage: "opticaldisc") }
            NavigationStack { ScannerTabView() }
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            NavigationStack { ListsTabView() }
                .tabItem { Label("Lists", systemImage: "list.bullet.rectangle") }
            NavigationStack { StatsView() }
                .tabItem { Label("Stats", systemImage: "chart.bar") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
