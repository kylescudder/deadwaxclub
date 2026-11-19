import Combine
import Foundation
import PowerSync

@MainActor
final class PowerSyncManager: ObservableObject {
    private static let serviceReadyKey = "sync.hermanDatabaseReady"
    private static let legacyDatabase = "deadwaxclub.sqlite"
    private static let hermanDatabase = "deadwaxclub-v2.sqlite"
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

    @Published private(set) var isMigrating = false
    @Published private(set) var requiresReload = false

    let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient
    private let issues: SyncIssueStore
    private var connector: APIConnector?
    private var cancellables = Set<AnyCancellable>()
    private var statusTask: Task<Void, Never>?
    private var pendingCountTask: Task<Void, Never>?

    init(authClient: AuthClient, issues: SyncIssueStore) {
        auth = authClient
        self.issues = issues
        database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: UserDefaults.standard.bool(forKey: Self.serviceReadyKey) ? Self.hermanDatabase : Self.legacyDatabase)
    }

    deinit {
        statusTask?.cancel()
        pendingCountTask?.cancel()
    }

    func offlineAccount() async throws -> (owners: Set<UUID>, hasPendingWrites: Bool) {
        let owners = try await database.getAll(
            sql: "select id from profiles union select user_id as id from pending_record_creations",
            parameters: [],
            mapper: { try $0.getString(name: "id") }
        )
        let ids = Set(try owners.map { owner in
            guard let id = UUID(uuidString: owner) else { throw CocoaError(.fileReadCorruptFile) }
            return id
        })
        let hasPendingWrites = try await database.getCrudBatch() != nil
        return (ids, hasPendingWrites)
    }

    func startObservingAuth() async {
        Publishers.CombineLatest(auth.$state, auth.$requiresReauthentication)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] state, requiresReauthentication in
            Task { @MainActor [weak self] in await self?.reconcile(requiresReauthentication ? .signedOut : state) }
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
        guard connector == nil, !isMigrating, !requiresReload, let owner = auth.currentUserID,
              await auth.currentAccessToken(for: owner) != nil else { return }
        guard connector == nil, auth.currentUserID == owner else { return }
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
        guard AppSecrets.powerSyncURL != nil else {
            status = .error("PowerSync is not configured.")
            return
        }
        if !UserDefaults.standard.bool(forKey: Self.serviceReadyKey) {
            await migrateService(owner: owner)
            return
        }
        status = .connecting
        let connector = APIConnector(auth: auth, issues: issues, owner: owner)
        self.connector = connector
        do { try await database.connect(connector: connector) }
        catch {
            self.connector = nil
            status = .error(error.localizedDescription)
            Log.error(error, category: "sync.connect")
        }
    }

    func retryConnection() async {
        await connectIfNeeded()
    }

    private func migrateService(owner: UUID) async {
        isMigrating = true
        status = .connecting
        defer { isMigrating = false }

        let staged = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: Self.hermanDatabase)
        do {
            struct Profile: Decodable { let id: UUID }
            let profile = try JSONDecoder().decode(Profile.self, from: await auth.api.request("api/me"))
            guard profile.id == owner else { throw URLError(.userAuthenticationRequired) }

            let uploader = APIConnector(auth: auth, issues: issues, owner: owner, preserveRejected: true)
            while try await database.getCrudBatch() != nil {
                try await uploader.uploadData(database: database)
            }
            try await staged.connect(connector: APIConnector(auth: auth, issues: issues, owner: owner))
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await staged.waitForFirstSync() }
                group.addTask {
                    try await Task.sleep(for: .seconds(30))
                    throw URLError(.timedOut)
                }
                _ = try await group.next()
                group.cancelAll()
            }

            while try await database.getCrudBatch() != nil {
                try await uploader.uploadData(database: database)
            }
            let reservations = try await database.getAll(
                sql: "select id, user_id, expected_lifetime_count, state, created_at from pending_record_creations where user_id = ?",
                parameters: [owner.lowerUUID]
            ) { row in
                (try row.getString(name: "id"), try row.getString(name: "user_id"),
                 try row.getInt(name: "expected_lifetime_count"), try row.getString(name: "state"),
                 try row.getString(name: "created_at"))
            }
            try await staged.writeTransaction { transaction in
                try transaction.execute(sql: "delete from pending_record_creations", parameters: [])
                for (id, user, count, state, created) in reservations {
                    try transaction.execute(
                        sql: "insert into pending_record_creations (id, user_id, expected_lifetime_count, state, created_at) values (?, ?, ?, ?, ?)",
                        parameters: [id, user, count, state, created]
                    )
                }
            }
            try await staged.disconnect()
            try await staged.close()
            guard await auth.currentAccessToken(for: owner) != nil else {
                throw URLError(.userAuthenticationRequired)
            }

            // Close the old connection before checking for a write that was
            // already in flight when the migration view replaced the app.
            try await database.close()
            requiresReload = true
            let legacy = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: Self.legacyDatabase)
            let pending = try await legacy.getCrudBatch() != nil
            try await legacy.close()
            guard !pending else { return }
            UserDefaults.standard.set(true, forKey: Self.serviceReadyKey)
        } catch {
            try? await staged.disconnect()
            try? await staged.close()
            status = .error("Couldn't sync offline changes. Your changes are still on this device.")
            Log.error(error, category: "sync.serviceMigration")
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
            let alternate = UserDefaults.standard.bool(forKey: Self.serviceReadyKey) ? Self.legacyDatabase : Self.hermanDatabase
            let other = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: alternate)
            try await other.disconnectAndClear()
            try await other.close()
            auth.clearOfflineOwner()
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
