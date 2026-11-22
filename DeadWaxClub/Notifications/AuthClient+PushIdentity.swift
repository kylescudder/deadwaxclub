import Foundation
import UIKit

/// The signed-in account as a push identity, and the app API's device-token
/// endpoint. This file is identical in every app.
extension AuthClient: PushIdentityProviding {
    func currentPushIdentity() async -> PushIdentity? {
        guard let principalID = currentUserID?.uuidString.lowercased(),
              let accessToken = await currentAccessToken(),
              currentUserID?.uuidString.lowercased() == principalID else { return nil }
        return PushIdentity(principalID: principalID, accessToken: accessToken)
    }

    func registerAPIPushToken(
        _ deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        let payload: [String: String] = [
            "apns_token": deviceToken.apnsHexString,
            "device_name": UIDevice.current.name,
            "bundle_id": Bundle.main.bundleIdentifier ?? PushAppConfiguration.fallbackBundleID,
            "environment": environment.rawValue,
        ]
        _ = try await api.json("api/devices", values: payload, expectedToken: identity.accessToken)
        Log.breadcrumb("apns token uploaded", category: "push")
    }

    func unregisterAPIPushToken(
        _ deviceToken: Data,
        identity: PushIdentity
    ) async throws {
        _ = try await api.json(
            "api/devices",
            method: "DELETE",
            values: ["apns_token": deviceToken.apnsHexString],
            expectedToken: identity.accessToken
        )
    }
}

private extension Data {
    var apnsHexString: String { map { String(format: "%02x", $0) }.joined() }
}
