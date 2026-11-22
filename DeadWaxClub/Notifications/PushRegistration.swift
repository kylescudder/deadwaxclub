import Foundation
import Security
import UIKit

/// Shared adapters around the push registration core. This file is identical
/// in every app; the Keychain item comes from `PushAppConfiguration`.

/// The gateway installation ID, created once per device and kept in the
/// Keychain so it survives reinstalls and sign-outs.
struct KeychainPushInstallationIDProvider: PushInstallationIDProviding {
    static let account = "push-gateway.installation-id"

    private let store: any PushInstallationIDStoring

    init(store: any PushInstallationIDStoring = SecurityPushInstallationIDStore()) {
        self.store = store
    }

    func installationID() throws -> UUID {
        if let stored = try store.read(account: Self.account),
           let identifier = UUID(uuidString: stored) {
            return identifier
        }

        let identifier = UUID()
        try store.write(account: Self.account, value: identifier.uuidString.lowercased())
        return identifier
    }
}

protocol PushInstallationIDStoring: Sendable {
    func read(account: String) throws -> String?
    func write(account: String, value: String) throws
}

/// Generic-password Keychain storage. The service and accessibility are app
/// hooks so each app keeps finding the item it already stored.
struct SecurityPushInstallationIDStore: PushInstallationIDStoring {
    private let service: String?
    private let accessibility: String

    init(
        service: String? = PushAppConfiguration.installationIDKeychainService,
        accessibility: String = PushAppConfiguration.installationIDKeychainAccessibility
    ) {
        self.service = service
        self.accessibility = accessibility
    }

    func read(account: String) throws -> String? {
        var query = itemQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else {
            throw PushInstallationIDStoreError.keychainStatus(status)
        }
        guard let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw PushInstallationIDStoreError.invalidStoredValue
        }
        return value
    }

    func write(account: String, value: String) throws {
        let key = itemQuery(account: account)
        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: accessibility,
        ]

        let updateStatus = SecItemUpdate(key as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw PushInstallationIDStoreError.keychainStatus(updateStatus)
        }

        var insertion = key
        attributes.forEach { insertion[$0.key] = $0.value }
        let addStatus = SecItemAdd(insertion as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw PushInstallationIDStoreError.keychainStatus(addStatus)
        }
    }

    private func itemQuery(account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: account,
        ]
        if let service {
            query[kSecAttrService as String] = service
        }
        return query
    }
}

enum PushInstallationIDStoreError: Error, Equatable {
    case keychainStatus(OSStatus)
    case invalidStoredValue
}

/// Registers the APNs token with the app API's `/api/devices` when the push
/// gateway is not configured. Unregistering removes the last token this
/// process tried to register.
@MainActor
final class APIPushRegistrationTransport: PushRegistrationTransport {
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
        try await auth.registerAPIPushToken(deviceToken, environment: environment, identity: identity)
    }

    func unregister(
        installationID: UUID,
        identity: PushIdentity
    ) async throws {
        guard let auth, let latestDeviceToken else { return }
        try await auth.unregisterAPIPushToken(latestDeviceToken, identity: identity)
    }
}

/// Exactly one registration path is active: the gateway when it is
/// configured, otherwise the app API.
enum PushRegistrationTransportKind: Equatable {
    case gateway
    case api

    static func selected(for configuration: PushGatewayConfiguration?) -> Self {
        configuration == nil ? .api : .gateway
    }
}

@MainActor
final class SystemRemoteNotificationRegistrar: RemoteNotificationRegistering {
    func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
