import Foundation
import PowerSync
import Supabase

/// Bridges PowerSync's backend connector protocol to a Supabase project.
/// - Fetches a fresh JWT for sync via the active Supabase session.
/// - Writes any local mutations back to Postgres tables via PostgREST.
final class SupabaseConnector: PowerSyncBackendConnector {
    private let auth: AuthClient

    init(auth: AuthClient) {
        self.auth = auth
        super.init()
    }

    override func fetchCredentials() async throws -> PowerSyncCredentials? {
        guard let token = await auth.currentAccessToken() else { return nil }
        guard let userID = await auth.currentUserID?.uuidString else { return nil }
        return PowerSyncCredentials(
            endpoint: AppSecrets.powerSyncURL.absoluteString,
            token: token,
            userId: userID
        )
    }

    override func uploadData(database: PowerSyncDatabaseProtocol) async throws {
        guard let batch = try await database.getCrudBatch() else { return }
        let client = await auth.supabase

        for entry in batch.crud {
            let table = client.from(entry.table)
            switch entry.op {
            case .put:
                let payload = entry.opData ?? [:]
                try await table.upsert(payload).execute()
            case .patch:
                guard let payload = entry.opData else { continue }
                try await table.update(payload).eq("id", value: entry.id).execute()
            case .delete:
                try await table.delete().eq("id", value: entry.id).execute()
            }
        }

        try await batch.complete(writeCheckpoint: nil)
    }
}
