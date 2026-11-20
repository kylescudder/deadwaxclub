import Foundation
import Security

struct APIError: Error, Decodable, LocalizedError, Sendable {
    let code: String
    let message: String?
    var errorDescription: String? { message ?? "The request could not be completed." }
}

@MainActor
final class APIClient {
    private let session: URLSession
    private let baseURL: URL
    private let configurationError: String?
    init(session: URLSession = .shared, baseURL: URL = AppSecrets.apiURL, configurationError: String? = AppSecrets.apiConfigurationError) {
        self.session = session
        self.baseURL = baseURL
        self.configurationError = configurationError
    }
    var token: String?
    var onUnauthorized: (() -> Void)?

    func request(_ path: String, method: String = "GET", body: Data? = nil, authenticated: Bool = true, contentType: String = "application/json", expectedToken: String? = nil) async throws -> Data {
        guard configurationError == nil else {
            throw APIError(code: "configuration", message: "Auth isn't configured for this build. Please install the latest build.")
        }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if authenticated {
            guard let token, expectedToken == nil || expectedToken == token else {
                throw APIError(code: "sign_in_required", message: "Sign in again to sync your offline changes.")
            }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401, authenticated,
               request.value(forHTTPHeaderField: "Authorization") == token.map({ "Bearer \($0)" }) {
                onUnauthorized?()
            }
            if http.statusCode >= 500 { throw URLError(.resourceUnavailable) }
            throw (try? JSONDecoder().decode(APIError.self, from: data))
                ?? APIError(code: http.statusCode == 401 ? "sign_in_required" : "invalid_request", message: "The request could not be completed.")
        }
        return data
    }

    func json(_ path: String, method: String = "POST", values: [String: Any], authenticated: Bool = true, expectedToken: String? = nil) async throws -> Data {
        try await request(path, method: method, body: JSONSerialization.data(withJSONObject: values), authenticated: authenticated, expectedToken: expectedToken)
    }
}

/// Session persistence is an OS boundary. Unsigned simulator tests supply an
/// in-memory store; release builds always default to the Keychain adapter.
@MainActor
protocol SessionStore {
    func read() throws -> Data?
    func write(_ data: Data?) throws
}

@MainActor
struct KeychainSessionStore: SessionStore {
    func read() throws -> Data? { try SessionKeychain.read() }
    func write(_ data: Data?) throws { try SessionKeychain.write(data) }
}

enum SessionKeychain {
    static func read() throws -> Data? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw URLError(.userAuthenticationRequired) }
        return value as? Data
    }
    static func write(_ data: Data?) throws {
        let status = SecItemDelete(base as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw URLError(.userAuthenticationRequired) }
        guard let data else { return }
        var query = base
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw URLError(.cannotWriteToFile) }
    }
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: AuthAppConfiguration.keychainService, kSecAttrAccount as String: "native-session"]
    }
}
