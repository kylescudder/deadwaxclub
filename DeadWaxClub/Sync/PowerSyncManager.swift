import Foundation
import PowerSync
import Combine

@MainActor
final class PowerSyncManager: ObservableObject {
    enum SyncStatus: Equatable {
        case idle
        case connecting
        case connected
        case offline
        case error(String)
    }

    @Published private(set) var status: SyncStatus = .idle

    let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient
    private var connector: SupabaseConnector?
    private var cancellables = Set<AnyCancellable>()

    init(authClient: AuthClient) {
        self.auth = authClient
        // dbFilename is a filename, not a path — PowerSync manages the
        // location itself under Application Support/databases.
        self.database = PowerSyncDatabase(
            schema: DatabaseSchema.schema,
            dbFilename: "deadwaxclub.sqlite"
        )
    }

    func startObservingAuth() async {
        auth.$state
            .removeDuplicates()
            .sink { [weak self] state in
                Task { [weak self] in await self?.reconcile(state: state) }
            }
            .store(in: &cancellables)
        await reconcile(state: auth.state)
    }

    private func reconcile(state: AuthClient.State) async {
        switch state {
        case .signedIn:
            await connectIfNeeded()
        case .signedOut:
            await disconnect()
        case .unknown:
            // Transient state during auth bootstrap on every launch.
            // disconnect() calls disconnectAndClear() which wipes the local
            // SQLite *and* the pending upload queue — way too aggressive for
            // what's just "we haven't read the keychain yet". Wait for an
            // explicit signedOut.
            break
        }
    }

    private func connectIfNeeded() async {
        guard connector == nil else { return }
        status = .connecting
        let connector = SupabaseConnector(auth: auth)
        self.connector = connector
        do {
            try await database.connect(connector: connector)
            status = .connected
            Log.breadcrumb("powersync connected", category: "sync")
        } catch {
            status = .error(error.localizedDescription)
            Log.error(error, category: "sync.connect")
        }
    }

    private func disconnect() async {
        // Use the non-clearing disconnect so transient .signedOut states
        // emitted during session refresh don't wipe the local DB and the
        // CRUD upload queue. To wipe on actual sign-out, call wipe()
        // explicitly from the sign-out path.
        do {
            try await database.disconnect()
            connector = nil
            status = .idle
            Log.breadcrumb("powersync disconnected", category: "sync")
        } catch {
            Log.error(error, category: "sync.disconnect")
        }
    }

    /// Tear down PowerSync's local SQLite + pending uploads. Call only when
    /// the user has explicitly signed out via the Settings UI.
    func wipe() async {
        do {
            try await database.disconnectAndClear()
            connector = nil
            status = .idle
            Log.breadcrumb("powersync wiped", category: "sync")
        } catch {
            Log.error(error, category: "sync.wipe")
        }
    }
}
