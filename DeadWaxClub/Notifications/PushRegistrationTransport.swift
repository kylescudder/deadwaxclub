import Foundation

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

enum APNSEnvironment: String, Codable, Sendable {
    case sandbox
    case production

    static var current: APNSEnvironment {
        #if DEBUG
        .sandbox
        #else
        .production
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
