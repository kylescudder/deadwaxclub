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
                    .sheet(isPresented: Binding(
                        get: { services.onboarding.isOnboarding },
                        set: { _ in }
                    )) {
                        OnboardingSheet(
                            initialSteps: services.onboarding.pendingSteps,
                            onCompleteDiscogsToken: {
                                services.onboarding.markDiscogsTokenSeen()
                                services.evaluateOnboarding()
                            },
                            onSkipDiscogsToken: {
                                services.onboarding.markDiscogsTokenSeen()
                                services.evaluateOnboarding()
                            },
                            onCompleteNotifications: {
                                services.onboarding.markNotificationsSeen()
                                services.evaluateOnboarding()
                            }
                        )
                        .presentationDetents([.large])
                        .interactiveDismissDisabled()
                    }
            }
        }
        .task { await services.auth.bootstrap() }
        .onChange(of: services.profile.profile?.displayName) { _, _ in
            services.evaluateOnboarding()
        }
        .onChange(of: services.profile.hasLoadedFromLocal) { _, _ in
            services.evaluateOnboarding()
        }
        .onOpenURL { url in handle(url: url) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { handle(url: url) }
        }
        .onContinueUserActivity("com.apple.corespotlightitem") { activity in
            // Tapping a DeadWaxClub record in Spotlight delivers the recordID
            // here; reuse the openRecord pipeline so the same sheet shows.
            if let recordID = activity.userInfo?["kCSSearchableItemActivityIdentifier"] as? String {
                NotificationCenter.default.post(
                    name: .openRecord, object: nil, userInfo: ["record_id": recordID]
                )
            }
        }
        .sheet(item: Binding(
            get: { publicListToken.map(PublicListPresentation.init) },
            set: { publicListToken = $0?.token }
        )) { presentation in
            NavigationStack { PublicListView(token: presentation.token) }
        }
        .sheet(item: Binding(
            get: { services.pendingDeepLinkRecord },
            set: { services.pendingDeepLinkRecord = $0 }
        )) { record in
            NavigationStack { RecordDetailView(record: record) }
        }
        .sheet(item: Binding(
            get: { services.pendingDeepLinkCollectionID.map(CollectionDeepLinkPresentation.init) },
            set: { services.pendingDeepLinkCollectionID = $0?.id }
        )) { _ in
            // ManageCollectionsView reads pendingDeepLinkCollectionID from
            // services and auto-navigates to the matching Collection.
            NavigationStack { ManageCollectionsView() }
        }
        .animation(.easeInOut(duration: 0.2), value: services.auth.state)
    }

    private func handle(url: URL) {
        Log.breadcrumb("incoming url: \(url.absoluteString)", category: "deeplink")
        // Public list share link: https://deadwaxclub.app/l/<token> or deadwaxclub://list/<token>
        if url.host == "deadwaxclub.app", url.pathComponents.count >= 3, url.pathComponents[1] == "l" {
            publicListToken = url.pathComponents[2]
            return
        }
        if url.scheme == "deadwaxclub", url.host == "list", let token = url.pathComponents.last, !token.isEmpty {
            publicListToken = token
            return
        }
        // Otherwise pass to auth (OAuth callback / email confirmation).
        Task { await services.auth.handle(callbackURL: url) }
    }

}

private struct PublicListPresentation: Identifiable {
    let token: String
    var id: String { token }
}

private struct CollectionDeepLinkPresentation: Identifiable {
    let id: String
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
