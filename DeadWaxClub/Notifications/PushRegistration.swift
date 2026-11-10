import Foundation

struct PushGatewayConfiguration: Equatable, Sendable {
    let baseURL: URL
    let applicationID: String

    static var fromBundle: PushGatewayConfiguration? {
        from(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    static func from(infoDictionary: [String: Any]) -> PushGatewayConfiguration? {
        guard
            let rawURL = infoDictionary["PUSH_GATEWAY_URL"] as? String,
            !rawURL.isEmpty,
            let baseURL = URL(string: rawURL),
            ["https", "http"].contains(baseURL.scheme?.lowercased() ?? ""),
            baseURL.host != nil,
            let applicationID = infoDictionary["PUSH_GATEWAY_APPLICATION_ID"] as? String,
            applicationID.range(
                of: #"^[a-z0-9][a-z0-9-]{1,62}[a-z0-9]$"#,
                options: .regularExpression
            ) != nil
        else { return nil }

        return PushGatewayConfiguration(baseURL: baseURL, applicationID: applicationID)
    }
}

struct PushIdentity: Equatable, Sendable {
    let principalID: String
    let accessToken: String
}

@MainActor
protocol PushIdentityProviding: AnyObject {
    func currentPushIdentity() async -> PushIdentity?
}

protocol PushInstallationIDProviding: Sendable {
    func installationID() throws -> UUID
}

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

enum APNSEnvironment: String, Codable, Sendable {
    case sandbox
    case production

    static var current: APNSEnvironment {
        #if DEBUG
        return .sandbox
        #else
        return .production
        #endif
    }
}

protocol PushRegistrationTransport: Sendable {
    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws
}

struct GatewayPushRegistrationTransport: PushRegistrationTransport {
    let configuration: PushGatewayConfiguration
    let session: URLSession

    func register(
        installationID: UUID,
        deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        let url = installationURL(installationID: installationID)
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(RegisterInstallationRequest(
            version: 1,
            platform: "ios",
            apnsToken: deviceToken.hexadecimalString,
            apnsEnvironment: environment
        ))

        let (_, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
    }

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws {
        let url = installationURL(installationID: installationID)
            .appending(path: "account-link")
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(identity.accessToken)", forHTTPHeaderField: "Authorization")

        let (_, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
    }

    private func installationURL(installationID: UUID) -> URL {
        configuration.baseURL
            .appending(path: "v1/apps")
            .appending(path: configuration.applicationID)
            .appending(path: "installations")
            .appending(path: installationID.uuidString.lowercased())
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PushGatewayError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw PushGatewayError.httpStatus(http.statusCode)
        }
    }
}

private struct RegisterInstallationRequest: Encodable {
    let version: Int
    let platform: String
    let apnsToken: String
    let apnsEnvironment: APNSEnvironment

    enum CodingKeys: String, CodingKey {
        case version
        case platform
        case apnsToken = "apns_token"
        case apnsEnvironment = "apns_environment"
    }
}

enum PushGatewayError: Error, Equatable {
    case invalidResponse
    case httpStatus(Int)
}

actor LegacyPushRegistrationTransport: PushRegistrationTransport {
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
        try await auth.registerLegacyPushToken(
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
        try await auth.unregisterLegacyPushToken(latestDeviceToken, identity: identity)
    }
}

enum PushRegistrationTransportSelector {
    static func select(
        configuration: PushGatewayConfiguration?,
        gateway: (any PushRegistrationTransport)?,
        legacy: any PushRegistrationTransport
    ) -> any PushRegistrationTransport {
        if configuration != nil, let gateway {
            return gateway
        }
        return legacy
    }
}

private extension Data {
    var hexadecimalString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
