import Foundation
import UIKit
import UserNotifications

@MainActor
protocol PushNotifications: AnyObject {
    var authorizationStatus: UNAuthorizationStatus { get }
    func requestAuthorization() async -> Bool
    func activate() async
    func deactivate() async
    func receivedDeviceToken(_ data: Data) async
    func refreshRegistration() async
}

/// Coordinates notification authorization, APNs registration, and the active
/// registration transport. The legacy Supabase transport remains the fallback
/// while the shared gateway URL is empty.
@MainActor
final class PushManager: NSObject, ObservableObject, PushNotifications {
    static let shared = PushManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private var registrationLifecycle: PushRegistrationLifecycle?

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    func bind(auth: AuthClient) {
        let configuration = PushGatewayConfiguration.fromBundle
        let gateway: (any PushRegistrationTransport)? = configuration.map {
            GatewayPushRegistrationTransport(
                configuration: $0,
                session: URLSession(configuration: .ephemeral)
            )
        }
        let legacy = LegacyPushRegistrationTransport(auth: auth)
        let transport = PushRegistrationTransportSelector.select(
            configuration: configuration,
            gateway: gateway,
            legacy: legacy
        )
        registrationLifecycle = PushRegistrationLifecycle(
            identityProvider: auth,
            installationIDProvider: KeychainPushInstallationIDProvider(),
            transport: transport,
            remoteNotificationRegistrar: SystemRemoteNotificationRegistrar(),
            environment: .current,
            reportError: { error, category in Log.error(error, category: category) }
        )
    }

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
                await registrationLifecycle?.refreshRegistration(isAuthorized: true)
            }
            return granted
        } catch {
            Log.error(error, category: "push.authorize")
            return false
        }
    }

    func activate() async {
        await refreshAuthorizationStatus()
        await registrationLifecycle?.activate(isAuthorized: isAuthorized)
    }

    func deactivate() async {
        await registrationLifecycle?.deactivate()
    }

    func sessionEnded() {
        registrationLifecycle?.sessionEnded()
    }

    /// Idempotent: after authorization, resubmits the current token and asks
    /// iOS to refresh it. Called on each foreground transition.
    func refreshRegistration() async {
        await refreshAuthorizationStatus()
        await registrationLifecycle?.refreshRegistration(isAuthorized: isAuthorized)
    }

    /// Called from the AppDelegate after iOS hands us a device token.
    func receivedDeviceToken(_ data: Data) async {
        await registrationLifecycle?.receivedDeviceToken(data)
    }

    func didFailToRegister(error: Error) {
        Log.error(error, category: "push.register")
    }

    private var isAuthorized: Bool {
        authorizationStatus == .authorized
            || authorizationStatus == .provisional
            || authorizationStatus == .ephemeral
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
        let userInfo = response.notification.request.content.userInfo
        let kind = userInfo["kind"] as? String

        // Newer pushes from notify-inbox carry an explicit `kind` discriminator.
        // Legacy pushes (record_id only) fall through as price_alert.
        if kind == "collection_invite", let collectionID = userInfo["collection_id"] as? String {
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .openCollection, object: nil, userInfo: ["collection_id": collectionID]
                )
            }
            return
        }

        if let recordID = userInfo["record_id"] as? String {
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
