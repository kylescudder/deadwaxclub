import Foundation
import UIKit

extension AuthClient: PushIdentityProviding {
    func currentPushIdentity() async -> PushIdentity? {
        guard
            let principalID = currentUserID?.lowerUUID,
            let accessToken = await currentAccessToken()
        else { return nil }
        return PushIdentity(principalID: principalID, accessToken: accessToken)
    }

    func registerLegacyPushToken(
        _ deviceToken: Data,
        environment: APNSEnvironment,
        identity: PushIdentity
    ) async throws {
        let payload: [String: String] = [
            "user_id": identity.principalID,
            "apns_token": deviceToken.map { String(format: "%02x", $0) }.joined(),
            "device_name": UIDevice.current.name,
            "bundle_id": Bundle.main.bundleIdentifier ?? "com.deadwaxclub.app",
            "environment": environment.rawValue,
        ]
        try await supabase
            .from("device_tokens")
            .upsert(payload, onConflict: "user_id,apns_token")
            .execute()
        Log.breadcrumb("apns token uploaded", category: "push")
    }

    func unregisterLegacyPushToken(
        _ deviceToken: Data,
        identity: PushIdentity
    ) async throws {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        try await supabase
            .from("device_tokens")
            .delete()
            .eq("user_id", value: identity.principalID)
            .eq("apns_token", value: token)
            .execute()
    }
}

