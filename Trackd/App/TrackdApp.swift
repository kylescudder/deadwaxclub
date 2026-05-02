import SwiftUI
import Sentry

@main
struct TrackdApp: App {
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
        }
    }
}
