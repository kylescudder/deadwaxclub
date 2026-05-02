import SwiftUI

struct RootView: View {
    @EnvironmentObject private var services: AppServices

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
        .animation(.easeInOut(duration: 0.2), value: services.auth.state)
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
