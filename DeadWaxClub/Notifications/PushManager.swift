import Foundation
import UIKit
import UserNotifications

/// Coordinates APNs registration and uploads the device token to Supabase
/// `device_tokens` so the notify-price-change Edge Function can target it.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    weak var auth: AuthClient?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func bind(auth: AuthClient) { self.auth = auth }

    func refreshAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Request the OS prompt and register for remote notifications if granted.
    /// Returns true if authorized.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound, .badge])
            await refreshAuthorizationStatus()
            if granted {
                UIApplication.shared.registerForRemoteNotifications()
            }
            return granted
        } catch {
            Log.error(error, category: "push.authorize")
            return false
        }
    }

    /// Idempotent: if the user has already granted permission, ensures the
    /// device is registered with APNs so the latest token is uploaded.
    /// Call on sign-in and on app foreground.
    func registerIfAuthorized() async {
        await refreshAuthorizationStatus()
        guard authorizationStatus == .authorized
            || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Called from the AppDelegate after iOS hands us a device token.
    func didRegister(deviceToken data: Data) async {
        let token = data.map { String(format: "%02x", $0) }.joined()
        await upload(apnsToken: token)
    }

    func didFailToRegister(error: Error) {
        Log.error(error, category: "push.register")
    }

    private func upload(apnsToken: String) async {
        guard let auth, let userID = auth.currentUserID?.uuidString else { return }
        let payload: [String: String] = [
            "user_id": userID,
            "apns_token": apnsToken,
            "device_name": UIDevice.current.name,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.deadwaxclub.app",
            "environment": Self.apnsEnvironment,
        ]
        do {
            try await auth.supabase
                .from("device_tokens")
                .upsert(payload, onConflict: "user_id,apns_token")
                .execute()
            Log.breadcrumb("apns token uploaded", category: "push")
        } catch {
            Log.error(error, category: "push.upload")
        }
    }

    /// Detect the right APNs environment for the running build.
    /// Uses the embedded provisioning profile in debug; assumes production
    /// in App Store builds.
    private static var apnsEnvironment: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}

extension PushManager: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let recordID = response.notification.request.content.userInfo["record_id"] as? String
        if let recordID {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .openRecord, object: nil, userInfo: ["record_id": recordID]
                )
            }
        }
    }
}

extension Notification.Name {
    static let openRecord = Notification.Name("deadwaxclub.openRecord")
}
