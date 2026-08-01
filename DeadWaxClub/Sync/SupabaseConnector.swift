import Foundation
import PowerSync
import Supabase

/// Bridges PowerSync's backend connector protocol to a Supabase project.
/// - Fetches a fresh JWT for sync via the active Supabase session.
/// - Writes any local mutations back to Postgres tables via PostgREST.
final class SupabaseConnector: PowerSyncBackendConnectorProtocol, @unchecked Sendable {
    private static let recordQuotaExceededCode = "DW001"
    private let auth: AuthClient

    init(auth: AuthClient) {
        self.auth = auth
    }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        guard let token = await auth.currentAccessToken() else { return nil }
        return PowerSyncCredentials(
            endpoint: AppSecrets.powerSyncURL.absoluteString,
            token: token
        )
    }

    func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        // A validation rejection must acknowledge only its own entry. Keeping
        // this at one lets a quota-rejected create be retired without
        // discarding or wedging later mutations in the queue.
        guard let batch = try await database.getCrudBatch(limit: 1),
              let entry = batch.crud.first else { return }
        let client = auth.supabase

        do {
            let table = client.from(entry.table)
            switch entry.op {
            case .put:
                // PowerSync keeps the row's primary key in `entry.id`, not
                // inside `opData`. Merge it back into the payload before
                // upserting — otherwise PostgREST sends an INSERT with a
                // null id and Postgres rejects it (FK or RLS, depending on
                // the table) with a misleading 42501.
                var payload = entry.opData ?? [:]
                if entry.table == "profiles" {
                    sanitizeProfilePayload(&payload)
                }
                payload["id"] = entry.id
                try await table.upsert(payload).execute()
            case .patch:
                guard var payload = entry.opData else { break }
                if entry.table == "profiles" {
                    sanitizeProfilePayload(&payload)
                }
                guard !payload.isEmpty else { break }
                try await table.update(payload).eq("id", value: entry.id).execute()
            case .delete:
                try await table.delete().eq("id", value: entry.id).execute()
            }
        } catch {
            guard isTerminalQuotaRejection(error, for: entry) else {
                // Network, authentication, and unexpected server failures
                // deliberately remain queued for PowerSync's normal retry.
                throw error
            }

            try await retireRejectedRecord(id: entry.id, database: database)
            try await batch.complete(writeCheckpoint: nil)
            Task { @MainActor in
                NotificationCenter.default.post(name: .recordCreationLimitReached, object: nil)
            }
            Log.event("record creation quota rejected and retired", category: "sync.quota", metadata: [
                "recordID": entry.id,
                "sqlState": Self.recordQuotaExceededCode,
            ])
            return
        }

        try await batch.complete(writeCheckpoint: nil)
    }

    private func isTerminalQuotaRejection(_ error: Error, for entry: any CrudEntry) -> Bool {
        guard entry.table == "records" else { return false }
        guard case .put = entry.op else { return false }
        return (error as? PostgrestError)?.code == Self.recordQuotaExceededCode
    }

    private func retireRejectedRecord(id: String, database: PowerSyncDatabaseProtocol) async throws {
        let now = Date().iso8601
        // The rejected record never existed remotely. Retire it and any local
        // dependants through managed views so PowerSync writes compensating
        // mutations and the UI immediately reconciles to the server state.
        try await database.execute(
            sql: "delete from record_images where record_id = ?",
            parameters: [id]
        )
        try await database.execute(
            sql: "update price_entries set deleted_at = ?, updated_at = ? where record_id = ? and deleted_at is null",
            parameters: [now, now, id]
        )
        try await database.execute(
            sql: "update records set deleted_at = ?, updated_at = ? where id = ? and deleted_at is null",
            parameters: [now, now, id]
        )
    }

    private func sanitizeProfilePayload<Value>(_ payload: inout [String: Value]) {
        payload.removeValue(forKey: "created_at")
        payload.removeValue(forKey: "is_premium_account")
    }
}

extension Notification.Name {
    static let recordCreationLimitReached = Notification.Name("dwc.recordCreationLimitReached")
}
