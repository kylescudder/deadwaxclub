import Combine
import Foundation
import PowerSync

@MainActor
final class PowerSyncManager: ObservableObject {
    private static let requiresWipeKey = "sync.requiresWipeBeforeConnect"

    enum SyncStatus: Equatable {
        case idle, connecting, connected, offline
        case error(String)
    }

    enum AuthAction: Equatable { case none, connect, disconnect }

    static func action(for state: AuthClient.State) -> AuthAction {
        switch state {
        case .unknown: .none
        case .signedIn: .connect
        case .signedOut: .disconnect
        }
    }

    @Published private(set) var status: SyncStatus = .idle
    @Published private(set) var pendingUploadCount = 0

    let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient
    private let issues: SyncIssueStore
    private var connector: SupabaseConnector?
    private var cancellables = Set<AnyCancellable>()
    private var statusTask: Task<Void, Never>?
    private var pendingCountTask: Task<Void, Never>?

    init(authClient: AuthClient, issues: SyncIssueStore) {
        auth = authClient
        self.issues = issues
        database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: "deadwaxclub.sqlite")
    }

    deinit {
        statusTask?.cancel()
        pendingCountTask?.cancel()
    }

    func startObservingAuth() async {
        auth.$state.removeDuplicates().sink { [weak self] state in
            Task { @MainActor [weak self] in await self?.reconcile(state) }
        }.store(in: &cancellables)

        let database = database
        statusTask = Task { [weak self] in
            for await update in database.currentStatus.asFlow() {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    if let error = update.anyError { self?.status = .error(String(describing: error)) }
                    else if update.connected { self?.status = .connected }
                    else if update.connecting { self?.status = .connecting }
                    else if update.hasSynced == true { self?.status = .offline }
                    else { self?.status = .idle }
                }
            }
        }

        pendingCountTask = Task { [weak self] in
            do {
                let stream = try database.watch(
                    sql: "select count(*) as count from ps_crud", parameters: [],
                    mapper: { try $0.getInt(name: "count") }
                )
                for try await rows in stream {
                    guard !Task.isCancelled else { return }
                    self?.pendingUploadCount = rows.first ?? 0
                }
            } catch { Log.error(error, category: "sync.pendingCount") }
        }
        await reconcile(auth.state)
    }

    private func reconcile(_ state: AuthClient.State) async {
        switch Self.action(for: state) {
        case .connect: await connectIfNeeded()
        case .disconnect: await disconnect()
        case .none: break
        }
    }

    private func connectIfNeeded() async {
        guard connector == nil else { return }
        if UserDefaults.standard.bool(forKey: Self.requiresWipeKey) {
            do {
                try await database.disconnectAndClear()
                UserDefaults.standard.removeObject(forKey: Self.requiresWipeKey)
                pendingUploadCount = 0
            } catch {
                status = .error("Offline data must be cleared before syncing another account.")
                Log.error(error, category: "sync.preconnectWipe")
                return
            }
        }
        status = .connecting
        let connector = SupabaseConnector(auth: auth, issues: issues)
        self.connector = connector
        do { try await database.connect(connector: connector) }
        catch {
            self.connector = nil
            status = .error(error.localizedDescription)
            Log.error(error, category: "sync.connect")
        }
    }

    private func disconnect() async {
        guard connector != nil else { return }
        do {
            try await database.disconnect()
            connector = nil
            status = .idle
        } catch { Log.error(error, category: "sync.disconnect") }
    }

    /// Persist the guard before clearing. A failed clear blocks any later
    /// account from connecting until the wipe succeeds.
    func wipe() async {
        UserDefaults.standard.set(true, forKey: Self.requiresWipeKey)
        do {
            try await database.disconnectAndClear()
            UserDefaults.standard.removeObject(forKey: Self.requiresWipeKey)
            connector = nil
            status = .idle
            pendingUploadCount = 0
        } catch {
            Log.error(error, category: "sync.wipe")
            issues.reportLocalClearFailure()
        }
    }
}
