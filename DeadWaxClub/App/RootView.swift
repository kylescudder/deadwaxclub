import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.scenePhase) private var scenePhase
    @State private var publicListToken: String?

    var body: some View {
        accountContent
        .task { await services.auth.bootstrap(offlineAccount: services.sync.offlineAccount) }
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
            get: { services.auth.canAccessMainApp ? publicListToken.map(PublicListPresentation.init) : nil },
            set: { publicListToken = $0?.token }
        )) { presentation in
            NavigationStack { PublicListView(token: presentation.token) }
        }
        .sheet(item: Binding(
            get: { services.auth.canAccessMainApp ? services.pendingDeepLinkRecord : nil },
            set: { services.pendingDeepLinkRecord = $0 }
        )) { record in
            NavigationStack { RecordDetailView(record: record) }
        }
        .sheet(item: Binding(
            get: { services.auth.canAccessMainApp ? services.pendingDeepLinkCollectionID.map(CollectionDeepLinkPresentation.init) : nil },
            set: { services.pendingDeepLinkCollectionID = $0?.id }
        )) { _ in
            // ManageCollectionsView reads pendingDeepLinkCollectionID from
            // services and auto-navigates to the matching Collection.
            NavigationStack { ManageCollectionsView() }
        }
        .alert(item: Binding(
            get: { services.syncIssues.current },
            set: { services.syncIssues.current = $0 }
        )) { issue in
            Alert(title: Text(issue.title), message: Text(issue.message), dismissButton: .default(Text("OK")))
        }
        // Password reset links carry a short-lived recovery token.
        // Stacked at the end so it sits above every other sheet, including
        // sign-in if the user wasn't already authenticated.
        .sheet(isPresented: Binding(
            get: { services.auth.isPasswordRecovery },
            set: { services.auth.isPasswordRecovery = $0 }
        )) {
            ResetPasswordSheet()
                .presentationDetents([.medium, .large])
        }
        .animation(.easeInOut(duration: 0.2), value: services.auth.state)
        .onAppear { QuickActionRouter.activate() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                QuickActionRouter.activate()
                Task { await PushManager.shared.refreshRegistration() }
                Task { await services.sync.retryConnection() }
            }
        }
    }

    @ViewBuilder
    private var accountContent: some View {
        switch services.auth.state {
        case .unknown:
            if let error = services.auth.lastError {
                ContentUnavailableView("Offline account unavailable", systemImage: "exclamationmark.lock", description: Text(error))
            } else {
                LoadingView()
            }
        case .signedOut:
            NavigationStack { SignInView() }
        case .signedIn:
            if !services.auth.canAccessMainApp {
                NavigationStack { SignInView() }
            } else {
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
    }

    private func handle(url: URL) {
        Log.breadcrumb("incoming url: \(Log.redactedURLDescription(url))", category: "deeplink")
        // Public list share link: https://deadwaxclub.app/l/<token> or deadwaxclub://list/<token>
        if url.host == "deadwaxclub.app", url.pathComponents.count >= 3, url.pathComponents[1] == "l" {
            Log.breadcrumb("deeplink routed to public list", category: "deeplink")
            publicListToken = url.pathComponents[2]
            return
        }
        if url.scheme == "deadwaxclub", url.host == "list", let token = url.pathComponents.last, !token.isEmpty {
            Log.breadcrumb("deeplink routed to public list", category: "deeplink")
            publicListToken = token
            return
        }
        if url.scheme == "deadwaxclub", url.host == "shortcut",
           let actionName = url.pathComponents.last,
           let action = AppQuickAction(rawValue: actionName) {
            Log.event("deeplink routed to shortcut", category: "deeplink", metadata: ["action": actionName])
            QuickActionRouter.handle(action)
            return
        }
        if url.scheme == "deadwaxclub", url.host == "record",
           let recordID = url.pathComponents.last, !recordID.isEmpty {
            Log.event("deeplink routed to record", category: "deeplink", metadata: ["recordID": recordID])
            NotificationCenter.default.post(
                name: .openRecord, object: nil, userInfo: ["record_id": recordID]
            )
            return
        }
        // Otherwise pass to auth (OAuth callback / email confirmation).
        Log.breadcrumb("deeplink routed to auth callback", category: "deeplink")
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
    @State private var selection: MainTab = .records
    @State private var recordsStatus: RecordStatus = .owned
    @State private var addRecordRequest: UUID?
    @State private var logPriceRequest: UUID?

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack {
                RecordsListView(
                    status: $recordsStatus,
                    addRecordRequest: addRecordRequest,
                    logPriceRequest: logPriceRequest
                )
            }
                .tabItem {
                    Label {
                        Text("Records")
                    } icon: {
                        recordsTabIcon
                    }
                }
                .tag(MainTab.records)
            NavigationStack { ScannerTabView(defaultStatus: recordsStatus) }
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
                .tag(MainTab.scan)
            NavigationStack { ListsTabView() }
                .tabItem { Label("Lists", systemImage: "list.bullet.rectangle") }
                .tag(MainTab.lists)
            NavigationStack { StatsView() }
                .tabItem { Label("Stats", systemImage: "chart.bar") }
                .tag(MainTab.stats)
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
                .tag(MainTab.settings)
        }
        .onReceive(NotificationCenter.default.publisher(for: .switchMainTab)) { note in
            if let tab = note.userInfo?["tab"] as? MainTab { selection = tab }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openAddRecord)) { _ in
            selection = .records
            addRecordRequest = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openLogPrice)) { _ in
            selection = .records
            logPriceRequest = UUID()
        }
    }

    private var recordsTabIcon: Image {
        guard let image = UIImage(named: "AppLogoIcon") else {
            return Image(systemName: "opticaldisc")
        }

        let size = CGSize(width: 24, height: 24)
        let renderer = UIGraphicsImageRenderer(size: size)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }

        return Image(uiImage: resized.withRenderingMode(.alwaysOriginal))
    }
}

enum MainTab: Hashable {
    case records, scan, lists, stats, settings
}

extension Notification.Name {
    /// Posted to ask MainTabView to switch tabs (e.g. the empty Records
    /// state nudging the user to the Scan tab).
    static let switchMainTab = Notification.Name("dwc.switchMainTab")
    static let openAddRecord = Notification.Name("dwc.openAddRecord")
    static let openLogPrice = Notification.Name("dwc.openLogPrice")
}
