import Foundation

struct SyncIssue: Identifiable, Equatable, Sendable {
    let id = UUID()
    let title: String
    let message: String
}

@MainActor
final class SyncIssueStore: ObservableObject {
    @Published var current: SyncIssue?

    func reportRejectedRecord(quotaExceeded: Bool) {
        current = SyncIssue(
            title: quotaExceeded ? "Offline record not synced" : "Offline change rejected",
            message: quotaExceeded
                ? "The server rejected this record because your lifetime free allowance was reached. The local copy will be removed."
                : "The server rejected a locally saved record. The local copy will be restored to the server version."
        )
    }

    func reportRejectedChange(table: String) {
        if current?.title == "Offline record not synced" { return }
        current = SyncIssue(
            title: "Offline change not synced",
            message: "The server rejected a locally saved \(table.replacingOccurrences(of: "_", with: " ")) change. Server data will be restored."
        )
    }

    func reportLocalClearFailure() {
        current = SyncIssue(
            title: "Offline data not cleared",
            message: "Deadwax Club could not clear its offline database. It will retry before another account can sync on this device."
        )
    }

    func reportQuotaSnapshotUnavailable() {
        current = SyncIssue(
            title: "Finish syncing first",
            message: "Deadwax Club needs to download your record allowance before you can save offline. Connect to the internet, wait for sync to finish, and try again."
        )
    }
}
