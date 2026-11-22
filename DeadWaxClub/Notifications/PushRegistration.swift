import Foundation

protocol PushInstallationIDStoring: Sendable {
    func readInstallationID() throws -> String?
    func writeInstallationID(_ value: String) throws
}

struct KeychainPushInstallationIDStore: PushInstallationIDStoring {
    private let account = "push-gateway.installation-id"

    func readInstallationID() throws -> String? {
        try Keychain.read(key: account)
    }

    func writeInstallationID(_ value: String) throws {
        try Keychain.write(key: account, value: value)
    }
}

struct KeychainPushInstallationIDProvider: PushInstallationIDProviding {
    private let store: any PushInstallationIDStoring

    init(store: any PushInstallationIDStoring = KeychainPushInstallationIDStore()) {
        self.store = store
    }

    func installationID() throws -> UUID {
        if let stored = try store.readInstallationID(),
           let installationID = UUID(uuidString: stored) {
            return installationID
        }

        let installationID = UUID()
        try store.writeInstallationID(installationID.uuidString.lowercased())
        return installationID
    }
}

actor APIPushRegistrationTransport: PushRegistrationTransport {
    private weak var auth: AuthClient?
    private var latestDeviceToken: Data?

    init(auth: AuthClient) {
        self.auth = auth
    }

    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        latestDeviceToken = deviceToken
        guard let auth else { return }
        try await auth.registerAPIPushToken(
            deviceToken,
            environment: environment,
            identity: identity
        )
    }

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws {
        guard let auth, let latestDeviceToken else { return }
        try await auth.unregisterAPIPushToken(latestDeviceToken, identity: identity)
    }
}

enum PushRegistrationTransportSelector {
    static func select(
        configuration: PushGatewayConfiguration?,
        gateway: (any PushRegistrationTransport)?,
        api: any PushRegistrationTransport
    ) -> any PushRegistrationTransport {
        if configuration != nil, let gateway {
            return gateway
        }
        return api
    }
}
