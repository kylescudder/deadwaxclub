import SwiftUI
import Sentry

@main
struct TrackdApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()
    @AppStorage("appearance") private var appearance: Appearance = .system

    init() {
        AppBootstrap.configureSentry()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .preferredColorScheme(appearance.colorScheme)
                .tint(Theme.Colors.accent)
                .task {
                    // Make AppServices reachable from AppIntents (which run
                    // outside the SwiftUI environment).
                    IntentBridge.services = services
                }
        }
    }
}
