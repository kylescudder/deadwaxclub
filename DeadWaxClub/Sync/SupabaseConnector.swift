import Foundation
import PowerSync
import Supabase

/// Uploads only explicitly approved client-writable tables. Permanent product
/// validation failures are acknowledged and surfaced; connectivity, auth,
/// RLS, credential, and unexpected failures remain queued for retry.
final class SupabaseConnector: PowerSyncBackendConnectorProtocol, @unchecked Sendable {
    private static let writableTables = DatabaseSchema.writableTableNames

    private let auth: AuthClient
    private let issues: SyncIssueStore

    init(auth: AuthClient, issues: SyncIssueStore) {
        self.auth = auth
        self.issues = issues
    }

    func fetchCredentials() async throws -> PowerSyncCredentials? {
        guard let token = await auth.currentAccessToken() else { return nil }
        return PowerSyncCredentials(endpoint: AppSecrets.powerSyncURL.absoluteString, token: token)
    }

    func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        guard let batch = try await database.getCrudBatch() else { return }
        for entry in batch.crud {
            guard Self.writableTables.contains(entry.table) else {
                throw SyncUploadError.unexpectedWritableTable(entry.table)
            }
            do {
                try await upload(entry)
                if entry.table == "records", entry.op == .put {
                    try? await database.execute(
                        sql: "update pending_record_creations set state = 'accepted' where id = ?",
                        parameters: [entry.id]
                    )
                }
            } catch {
                guard Self.isPermanentRejection(error) else { throw error }
                let quotaExceeded = (error as? PostgrestError)?.code == "DW001"
                Log.error(error, category: "sync.upload.rejected")
                if entry.table == "records" {
                    try? await database.execute(
                        sql: "delete from pending_record_creations where id = ?",
                        parameters: [entry.id]
                    )
                    await issues.reportRejectedRecord(quotaExceeded: quotaExceeded)
                } else {
                    await issues.reportRejectedChange(table: entry.table)
                }
            }
        }
        try await batch.complete()
    }

    private func upload(_ entry: CrudEntry) async throws {
        let table = auth.supabase.from(entry.table)
        switch entry.op {
        case .put:
            var payload = entry.opData ?? [:]
            sanitize(&payload, table: entry.table, isPatch: false)
            payload["id"] = entry.id
            if entry.table == "records" {
                do {
                    // BEFORE INSERT updates the durable quota ledger. Upsert
                    // would run it even when resolving an existing UUID.
                    try await table.insert(payload).execute()
                } catch {
                    if Self.isUniqueViolation(error), try await serverRecordExists(id: entry.id) { return }
                    throw error
                }
            } else {
                try await table.upsert(payload).execute()
            }
        case .patch:
            guard var payload = entry.opData else { return }
            sanitize(&payload, table: entry.table, isPatch: true)
            guard !payload.isEmpty else { return }
            try await table.update(payload).eq("id", value: entry.id).execute()
        case .delete:
            try await table.delete().eq("id", value: entry.id).execute()
        }
    }

    private func serverRecordExists(id: String) async throws -> Bool {
        struct ExistingID: Decodable { let id: String }
        let rows: [ExistingID] = try await auth.supabase.from("records")
            .select("id").eq("id", value: id).limit(1).execute().value
        return !rows.isEmpty
    }

    private func sanitize<Value>(_ payload: inout [String: Value], table: String, isPatch: Bool) {
        if table == "profiles" {
            payload.removeValue(forKey: "created_at")
            payload.removeValue(forKey: "is_premium_account")
        }
        if table == "records" { payload.removeValue(forKey: "created_by") }
        if table == "price_entries" {
            payload.removeValue(forKey: "previous_min_cents")
            payload.removeValue(forKey: "is_new_low")
        }
        if isPatch {
            switch table {
            case "collections": payload.removeValue(forKey: "created_by")
            case "lists": payload.removeValue(forKey: "owner_id")
            case "price_entries": payload.removeValue(forKey: "owner_id")
            case "record_images": payload.removeValue(forKey: "uploaded_by")
            default: break
            }
        }
    }

    static func isPermanentRejection(_ error: Error) -> Bool {
        guard let error = error as? PostgrestError else { return false }
        if ["DW001", "DW002", "DW003"].contains(error.code) { return true }
        return ["23502", "23503", "23505", "23514"].contains(error.code)
    }

    private static func isUniqueViolation(_ error: Error) -> Bool {
        (error as? PostgrestError)?.code == "23505"
    }
}

private enum SyncUploadError: LocalizedError {
    case unexpectedWritableTable(String)
    var errorDescription: String? {
        switch self {
        case .unexpectedWritableTable(let table):
            "PowerSync attempted to upload an unexpected table: \(table)"
        }
    }
}
