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
                for try await rows in database.watch(
                    sql: "select * from profiles where id = ? limit 1",
                    parameters: [userID]
                ) {
                    let next = (rows.first as? [String: Any]).flatMap(Profile.from(row:))
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
