import Foundation
import PowerSync

/// Deadwax Club's values for the shared sync core (`PowerSyncManager`,
/// `APIConnector`, `SyncIssueStore`). The local schema and table
/// classification live in `DatabaseSchema.swift`.
enum SyncAppConfiguration {
    static let databaseFilename = "deadwaxclub-v2.sqlite"

    /// Every account that owns local rows or pending creations.
    static let offlineOwnerQuery = "select id from profiles union select user_id as id from pending_record_creations"

    /// Tables PowerSync may upload. Read-only snapshots (members, quota,
    /// entitlement) must never enter the CRUD queue.
    static let writableTables = DatabaseSchema.writableTableNames

    /// `DW001` lifetime limit, `DW002`/`DW003` record validation, and Postgres
    /// not-null, foreign-key, unique and check violations.
    static let permanentRejectionCodes: Set<String> = ["DW001", "DW002", "DW003", "23502", "23503", "23505", "23514"]

    static let localClearFailureMessage =
        "Deadwax Club could not clear its offline database. It will retry before another account can sync on this device."

    /// An accepted record insert confirms its pending creation reservation.
    /// A failed local update throws, so the batch is retried; the API accepts
    /// the replay only after confirming the same record ID exists.
    @MainActor
    static func didUpload(_ entry: CrudEntry, database: PowerSyncDatabaseProtocol) async throws {
        guard entry.table == "records", entry.op == .put else { return }
        try await database.execute(
            sql: "update pending_record_creations set state = 'accepted' where id = ?",
            parameters: [entry.id]
        )
    }

    /// A rejected record releases its reservation; PowerSync restores the row.
    @MainActor
    static func didReject(
        _ entry: CrudEntry,
        error: Error,
        database: PowerSyncDatabaseProtocol,
        issues: SyncIssueStore
    ) async throws {
        if entry.table == "records" {
            try await database.execute(sql: "delete from pending_record_creations where id = ?", parameters: [entry.id])
            issues.reportRejectedRecord(quotaExceeded: (error as? APIError)?.code == "DW001")
        } else {
            issues.reportRejectedChange(table: entry.table)
        }
    }
}
