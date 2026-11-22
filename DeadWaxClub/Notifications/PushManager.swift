import Foundation
import UIKit
import UserNotifications

/// Shared push coordinator: notification authorization, APNs registration
/// through `PushRegistrationLifecycle`, and the notification-center delegate.
/// This file is identical in every app; the app decides where a tapped
/// notification goes in `PushAppConfiguration.route(for:)`.
///
/// Registration uses the shared push gateway when `PUSH_GATEWAY_URL` is
/// configured, otherwise the app API's `/api/devices` endpoint.
@MainActor
final class PushManager: NSObject, ObservableObject {
    static let shared = PushManager()

    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let notificationCenter: UNUserNotificationCenter
    private var registrationLifecycle: PushRegistrationLifecycle?
    private var sessionGeneration = UUID()

    private override init() {
        notificationCenter = .current()
        super.init()
        notificationCenter.delegate = self
        Task { await refreshAuthorizationStatus() }
    }

    /// A manager around an existing lifecycle. It does not become the
    /// notification-center delegate.
    init(
        registrationLifecycle: PushRegistrationLifecycle,
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        self.registrationLifecycle = registrationLifecycle
        self.notificationCenter = notificationCenter
        super.init()
    }

    func bind(auth: AuthClient) {
        guard registrationLifecycle == nil else { return }
        let configuration = PushGatewayConfiguration.fromBundle
        let transport: any PushRegistrationTransport
        switch PushRegistrationTransportKind.selected(for: configuration) {
        case .gateway:
            guard let configuration else { return }
            transport = GatewayPushRegistrationTransport(
                configuration: configuration,
                session: URLSession(configuration: .ephemeral)
            )
        case .api:
            transport = APIPushRegistrationTransport(auth: auth)
        }
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
        let settings = await notificationCenter.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Shows the system prompt and, if granted, registers the current account
    /// for remote notifications. Returns whether permission was granted.
    @discardableResult
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
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

    /// Starts registration for the signed-in account.
    func activate() async {
        let generation = sessionGeneration
        await refreshAuthorizationStatus()
        guard generation == sessionGeneration else { return }
        await registrationLifecycle?.activate(isAuthorized: isAuthorized)
    }

    /// Unregisters before the session is invalidated.
    func deactivate() async {
        sessionGeneration = UUID()
        await registrationLifecycle?.deactivate()
    }

    /// Forgets the account after an observed sign-out, without a request.
    func sessionEnded() {
        sessionGeneration = UUID()
        registrationLifecycle?.sessionEnded()
    }

    /// Idempotent: resubmits the current token and asks iOS to refresh it.
    /// Called on each foreground transition.
    func refreshRegistration() async {
        await refreshAuthorizationStatus()
        await registrationLifecycle?.refreshRegistration(isAuthorized: isAuthorized)
    }

    /// Called from `AppDelegate` when iOS hands over a device token.
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

/// Where a tapped notification should go: a `NotificationCenter` post that
/// the app's composition root or views handle.
struct PushRoute: Equatable, Sendable {
    let name: Notification.Name
    let userInfo: [String: String]
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
        guard let route = PushAppConfiguration.route(for: response.notification.request.content.userInfo) else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: route.name, object: nil, userInfo: route.userInfo)
        }
    }
}
