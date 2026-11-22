import Foundation
import PowerSync

/// Sends PowerSync's local CRUD queue to the owner-scoped API. This file is
/// identical in every app; the writable tables, permanent error codes and
/// quota replay rules live in `SyncAppConfiguration.swift`.
///
/// The connector is bound to the account that owns the local data, and every
/// request must carry that account's current token. Known permanent
/// validation failures are acknowledged so PowerSync rolls the optimistic
/// local row back to server state. Transient, authentication, RLS and
/// unexpected failures throw and therefore stay queued for automatic retry.
@MainActor
final class APIConnector: PowerSyncBackendConnectorProtocol {
    private let auth: AuthClient
    private let issues: SyncIssueStore
    private let owner: UUID

    init(auth: AuthClient, issues: SyncIssueStore, owner: UUID) {
        self.auth = auth
        self.issues = issues
        self.owner = owner
    }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        guard let endpoint = AppSecrets.powerSyncURL?.absoluteString,
              let token = await auth.currentAccessToken(for: owner) else { return nil }
        struct SyncToken: Decodable { let token: String }
        let data = try await auth.api.request("api/auth/token", expectedToken: token)
        return PowerSyncCredentials(endpoint: endpoint, token: try JSONDecoder().decode(SyncToken.self, from: data).token)
    }

    func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        guard await auth.currentAccessToken(for: owner) != nil else {
            throw URLError(.userAuthenticationRequired)
        }
        guard let batch = try await database.getCrudBatch() else { return }

        for entry in batch.crud {
            guard SyncAppConfiguration.writableTables.contains(entry.table) else {
                throw SyncUploadError.unexpectedWritableTable(entry.table)
            }
            guard let token = await auth.currentAccessToken(for: owner) else {
                throw URLError(.userAuthenticationRequired)
            }

            do {
                try await upload(entry, expectedToken: token)
                try await SyncAppConfiguration.didUpload(entry, database: database)
            } catch {
                guard Self.isPermanentRejection(error) else { throw error }
                Log.error(error, category: "sync.upload.rejected")
                // Completing this batch acknowledges the rejected operation.
                // PowerSync then restores the row from its server-state copy.
                try await SyncAppConfiguration.didReject(entry, error: error, database: database, issues: issues)
            }
        }

        try await batch.complete()
    }

    private func upload(_ entry: CrudEntry, expectedToken token: String) async throws {
        let operation: String
        switch entry.op {
        case .put: operation = "put"
        case .patch: operation = "patch"
        case .delete: operation = "delete"
        }
        _ = try await auth.api.json("api/sync/upload", values: [
            "table": entry.table,
            "id": entry.id.lowercased(),
            "op": operation,
            "data": entry.opData ?? [:],
        ], expectedToken: token)
    }

    /// Only codes that cannot succeed on retry. Never add authentication,
    /// RLS (42501), availability or unknown failures here.
    nonisolated static func isPermanentRejection(_ error: Error) -> Bool {
        guard let code = (error as? APIError)?.code else { return false }
        return SyncAppConfiguration.permanentRejectionCodes.contains(code)
    }
}

enum SyncUploadError: LocalizedError, Equatable {
    case unexpectedWritableTable(String)

    var errorDescription: String? { "PowerSync attempted to upload an unexpected table." }
}
