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
            }
        }
        .task { await services.auth.bootstrap() }
        .animation(.easeInOut(duration: 0.2), value: services.auth.state)
    }
}

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack { RecordsListView() }
                .tabItem { Label("Records", systemImage: "opticaldisc") }
            NavigationStack { ScannerTabView() }
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            NavigationStack { SettingsView() }
                .tabItem { Label("Settings", systemImage: "gear") }
        }
    }
}
