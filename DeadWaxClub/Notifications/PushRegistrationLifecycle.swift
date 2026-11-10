import Foundation
import UIKit

@MainActor
protocol RemoteNotificationRegistering: AnyObject {
    func registerForRemoteNotifications()
}

@MainActor
final class SystemRemoteNotificationRegistrar: RemoteNotificationRegistering {
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}

@MainActor
final class PushRegistrationLifecycle {
    private let identityProvider: any PushIdentityProviding
    private let installationIDProvider: any PushInstallationIDProviding
    private let transport: any PushRegistrationTransport
    private let remoteNotificationRegistrar: any RemoteNotificationRegistering
    private let environment: APNSEnvironment
    private let reportError: (Error, String) -> Void

    private var identity: PushIdentity?
    private var latestDeviceToken: Data?

    init(
        identityProvider: any PushIdentityProviding,
        installationIDProvider: any PushInstallationIDProviding,
        transport: any PushRegistrationTransport,
        remoteNotificationRegistrar: any RemoteNotificationRegistering,
        environment: APNSEnvironment,
        reportError: @escaping (Error, String) -> Void
    ) {
        self.identityProvider = identityProvider
        self.installationIDProvider = installationIDProvider
        self.transport = transport
        self.remoteNotificationRegistrar = remoteNotificationRegistrar
        self.environment = environment
        self.reportError = reportError
    }

    func activate(isAuthorized: Bool) async {
        identity = await identityProvider.currentPushIdentity()
        await registerLatestTokenIfPossible()
        registerWithAPNsIfAuthorized(isAuthorized)
    }

    func deactivate() async {
        guard let identity else { return }
        defer { self.identity = nil }

        do {
            try await transport.unregister(
                installationID: try installationIDProvider.installationID(),
                identity: identity
            )
        } catch {
            reportError(error, "push.unregister")
        }
    }

    func sessionEnded() {
        identity = nil
    }

    func receivedDeviceToken(_ data: Data) async {
        latestDeviceToken = data
        await registerLatestTokenIfPossible()
    }

    func refreshRegistration(isAuthorized: Bool) async {
        guard isAuthorized else { return }
        if identity == nil {
            identity = await identityProvider.currentPushIdentity()
        }
        await registerLatestTokenIfPossible()
        remoteNotificationRegistrar.registerForRemoteNotifications()
    }

    private func registerWithAPNsIfAuthorized(_ isAuthorized: Bool) {
        guard isAuthorized else { return }
        remoteNotificationRegistrar.registerForRemoteNotifications()
    }

    private func registerLatestTokenIfPossible() async {
        guard let identity, let latestDeviceToken else { return }
        do {
            try await transport.register(
                installationID: try installationIDProvider.installationID(),
                deviceToken: latestDeviceToken,
                environment: environment,
                identity: identity
            )
        } catch {
            reportError(error, "push.registration")
        }
    }
}
