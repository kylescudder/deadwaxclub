import Foundation
import PowerSync

@MainActor
final class ProfileRepository: ObservableObject {
    @Published private(set) var profile: Profile?

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
                    await MainActor.run { self.profile = next }
                }
            } catch {
                Log.error(error, category: "profile.watch")
            }
        }
    }

    func updateDisplayName(_ name: String) async {
        guard let userID = auth.currentUserID?.uuidString else { return }
        do {
            try await auth.supabase
                .from("profiles")
                .update(["display_name": name])
                .eq("id", value: userID)
                .execute()
        } catch {
            Log.error(error, category: "profile.updateDisplayName")
        }
    }
}
