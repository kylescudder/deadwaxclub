import Foundation
import UIKit

extension AuthClient: PushIdentityProviding {
    func currentPushIdentity() async -> PushIdentity? {
        guard
            let principalID = currentUserID?.lowerUUID,
            let accessToken = await currentAccessToken(),
            currentUserID?.lowerUUID == principalID
        else { return nil }
        return PushIdentity(principalID: principalID, accessToken: accessToken)
    }

    func registerLegacyPushToken(
        _ deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        let payload: [String: String] = [
            "apns_token": deviceToken.map { String(format: "%02x", $0) }.joined(),
            "device_name": UIDevice.current.name,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.deadwaxclub.app",
            "environment": environment.rawValue,
        ]
        _ = try await api.json("api/devices", values: payload, expectedToken: identity.accessToken)
        Log.breadcrumb("apns token uploaded", category: "push")
    }

    func unregisterLegacyPushToken(
        _ deviceToken: Data,
        identity: PushIdentity
    ) async throws {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        _ = try await api.json("api/devices", method: "DELETE", values: ["apns_token": token], expectedToken: identity.accessToken)
    }
}

