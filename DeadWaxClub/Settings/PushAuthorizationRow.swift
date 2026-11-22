import SwiftUI
import UIKit

/// The Settings row for push notification permission: its state, the
/// system prompt, or a link to iOS Settings when it was denied. This file is
/// identical in every app; the copy lives in `PushAppConfiguration`.
struct PushAuthorizationRow: View {
    @ObservedObject private var push = PushManager.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        switch push.authorizationStatus {
        case .authorized, .ephemeral, .provisional:
            Label(PushAppConfiguration.settingsAllowedText, systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .denied:
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Label(PushAppConfiguration.settingsDeniedText, systemImage: "xmark.seal")
                    .foregroundStyle(.red)
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                        openURL(url)
                    }
                }
            }
        case .notDetermined:
            Button(PushAppConfiguration.settingsEnableTitle) {
                Task { await push.requestAuthorization() }
            }
        @unknown default:
            Text(PushAppConfiguration.settingsUnknownText)
        }
    }
}
