import Foundation

/// Deadwax Club's sync issue copy, layered on the shared `SyncIssueStore`.
extension SyncIssueStore {
    private static let recordNotSyncedTitle = "Offline record not synced"

    func reportRejectedRecord(quotaExceeded: Bool) {
        report(SyncIssue(
            title: quotaExceeded ? Self.recordNotSyncedTitle : "Offline change rejected",
            message: quotaExceeded
                ? "The server rejected this record because your lifetime free allowance was reached. The local copy will be removed."
                : "The server rejected a locally saved record. The local copy will be restored to the server version."
        ))
    }

    /// Never replaces the more important "record not synced" issue.
    func reportRejectedChange(table: String) {
        if current?.title == Self.recordNotSyncedTitle { return }
        report(SyncIssue(
            title: "Offline change not synced",
            message: "The server rejected a locally saved \(table.replacingOccurrences(of: "_", with: " ")) change. Server data will be restored."
        ))
    }

    func reportQuotaSnapshotUnavailable() {
        report(SyncIssue(
            title: "Finish syncing first",
            message: "Deadwax Club needs to download your record allowance before you can save offline. Connect to the internet, wait for sync to finish, and try again."
        ))
    }
}
