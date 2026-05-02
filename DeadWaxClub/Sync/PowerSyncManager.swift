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
        let dbPath = Self.databasePath()
        self.database = PowerSyncDatabase(
            schema: DatabaseSchema.schema,
            dbFilename: dbPath
        )
    }

    private static func databasePath() -> String {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("deadwaxclub.sqlite").path
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
        case .signedOut, .unknown:
            await disconnect()
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
        do {
            try await database.disconnectAndClear()
            connector = nil
            status = .idle
            Log.breadcrumb("powersync disconnected", category: "sync")
        } catch {
            Log.error(error, category: "sync.disconnect")
        }
    }
}
