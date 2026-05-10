import Foundation
import PowerSync

@MainActor
final class ProfileRepository: ObservableObject {
    @Published private(set) var profile: Profile?
    /// True after the local watcher has emitted at least once. Lets the
    /// onboarding coordinator distinguish "still loading" from "no row,
    /// please nag the user". Resets to false whenever a new watch starts.
    @Published private(set) var hasLoadedFromLocal: Bool = false

    private let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient
    private var watchTask: Task<Void, Never>?

    init(database: PowerSyncDatabaseProtocol, auth: AuthClient) {
        self.database = database
        self.auth = auth
    }

    deinit { watchTask?.cancel() }

    func startWatching(userID: String) {
        watchTask?.cancel()
        hasLoadedFromLocal = false
        watchTask = Task { [weak self, database] in
            guard let self else { return }
            do {
                let stream = try database.watch(
                    sql: "select * from profiles where id = ? limit 1",
                    parameters: [userID],
                    mapper: { Profile.from(cursor: $0) }
                )
                for try await rows in stream {
                    let next = rows.first.flatMap { $0 }
                    await MainActor.run {
                        self.profile = next
                        self.hasLoadedFromLocal = true
                    }
                }
            } catch {
                Log.error(error, category: "profile.watch")
            }
        }
    }

    func updateDisplayName(_ name: String) async {
        guard let userID = auth.currentUserID?.lowerUUID else { return }
        let now = Date().iso8601
        do {
            // PowerSync exposes tables as views, so ON CONFLICT … DO UPDATE
            // is not supported. Insert-then-update covers the case where
            // the auth-user trigger row hasn't synced down yet.
            try await database.execute(
                sql: """
                insert or ignore into profiles (id, display_name, created_at, updated_at)
                values (?, ?, ?, ?)
                """,
                parameters: [userID, name, now, now]
            )
            try await database.execute(
                sql: "update profiles set display_name = ?, updated_at = ? where id = ?",
                parameters: [name, now, userID]
            )
        } catch {
            Log.error(error, category: "profile.updateDisplayName")
        }
    }
}
