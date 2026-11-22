import Foundation

@MainActor
protocol RemoteNotificationRegistering: AnyObject {
    func registerForRemoteNotifications()
}

@MainActor
final class PushRegistrationLifecycle {
    private let identityProvider: any PushIdentityProviding
    private let installationIDProvider: any PushInstallationIDProviding
    private let transport: any PushRegistrationTransport
    private let remoteNotificationRegistrar: any RemoteNotificationRegistering
    private let environment: APNSEnvironment
    private let reportError: (Error, String) -> Void

    private var pendingOperation: Task<Void, Never>?
    private var generation = UUID()
    private var isActive = false

    private(set) var identity: PushIdentity?
    private(set) var latestDeviceToken: Data?

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
        isActive = true
        await refreshIdentityAndRegistration(isAuthorized: isAuthorized)
    }

    func deactivate() async {
        let previousIdentity = identity
        sessionEnded()
        // Drain the PUT before DELETE; canceling a request cannot undo a
        // registration that the remote gateway has already accepted.
        await enqueue {
            guard let previousIdentity else { return }
            guard let identity = await self.identityProvider.currentPushIdentity(),
                  identity.principalID == previousIdentity.principalID else {
                self.reportError(PushLifecycleError.identityUnavailable, "push.unregister")
                return
            }
            do {
                try await self.transport.unregister(
                    installationID: self.installationIDProvider.installationID(),
                    identity: identity
                )
            } catch {
                self.reportError(error, "push.unregister")
            }
        }
    }

    func sessionEnded() {
        generation = UUID()
        isActive = false
        identity = nil
    }

    func receivedDeviceToken(_ data: Data) async {
        latestDeviceToken = data
        guard isActive else { return }
        await refreshIdentityAndRegistration(isAuthorized: false)
    }

    func refreshRegistration(isAuthorized: Bool) async {
        guard isActive, isAuthorized else { return }
        await refreshIdentityAndRegistration(isAuthorized: true)
    }

    private func refreshIdentityAndRegistration(isAuthorized: Bool) async {
        let generation = generation
        await enqueue {
            guard self.generation == generation else { return }
            let identity = await self.identityProvider.currentPushIdentity()
            guard self.generation == generation else { return }
            self.identity = identity
            await self.registerLatestTokenIfPossible()
            guard self.generation == generation, isAuthorized else { return }
            self.remoteNotificationRegistrar.registerForRemoteNotifications()
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = pendingOperation
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        pendingOperation = task
        await task.value
    }

    private func registerLatestTokenIfPossible() async {
        guard let identity, let latestDeviceToken else { return }
        do {
            try await transport.register(
                installationID: installationIDProvider.installationID(),
                deviceToken: latestDeviceToken,
                environment: environment,
                identity: identity
            )
        } catch {
            reportError(error, "push.registration")
        }
    }
}

private enum PushLifecycleError: Error {
    case identityUnavailable
}
