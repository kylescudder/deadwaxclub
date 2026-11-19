import Foundation
import PowerSync

@MainActor
final class APIConnector: PowerSyncBackendConnectorProtocol {
    private let auth: AuthClient
    private let issues: SyncIssueStore
    private let owner: UUID
    private let preserveRejected: Bool

    init(auth: AuthClient, issues: SyncIssueStore, owner: UUID, preserveRejected: Bool = false) {
        self.auth = auth
        self.issues = issues
        self.owner = owner
        self.preserveRejected = preserveRejected
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
            guard DatabaseSchema.writableTableNames.contains(entry.table) else {
                throw APIError(code: "unexpected_table", message: "Sync encountered an unexpected table.")
            }
            guard let token = await auth.currentAccessToken(for: owner) else {
                throw URLError(.userAuthenticationRequired)
            }
            do {
                let operation: String
                switch entry.op {
                case .put: operation = "put"
                case .patch: operation = "patch"
                case .delete: operation = "delete"
                }
                _ = try await auth.api.json("api/sync/upload", values: [
                    "table": entry.table, "id": entry.id.lowercased(), "op": operation,
                    "data": entry.opData ?? [:],
                ], expectedToken: token)
                if entry.table == "records", entry.op == .put {
                    try await database.execute(
                        sql: "update pending_record_creations set state = 'accepted' where id = ?",
                        parameters: [entry.id]
                    )
                }
            } catch {
                guard !preserveRejected, Self.isPermanentRejection(error) else { throw error }
                Log.error(error, category: "sync.upload.rejected")
                if entry.table == "records" {
                    try await database.execute(sql: "delete from pending_record_creations where id = ?", parameters: [entry.id])
                    issues.reportRejectedRecord(quotaExceeded: (error as? APIError)?.code == "DW001")
                } else {
                    issues.reportRejectedChange(table: entry.table)
                }
            }
        }
        try await batch.complete()
    }

    nonisolated static func isPermanentRejection(_ error: Error) -> Bool {
        guard let code = (error as? APIError)?.code else { return false }
        return ["DW001", "DW002", "DW003", "23502", "23503", "23505", "23514"].contains(code)
    }
}
