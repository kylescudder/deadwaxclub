import Combine
import Foundation
import PowerSync

/// Shared account-scoped PowerSync lifecycle. Every account has a separate
/// database and CRUD queue. Signing out closes it without clearing any rows;
/// only explicit account deletion removes that account's local data.
/// The verified legacy owner keeps the original file, including queued writes.
@MainActor
final class PowerSyncManager: ObservableObject {
    private static let requiresWipeKey = "sync.requiresWipeBeforeConnect"
    private let databaseFilename: String
    private let injectedDatabase: (any PowerSyncDatabaseProtocol)?
    private(set) var accountID: UUID?
    /// Recreate feature repositories against the selected database before the
    /// AuthClient publishes its session. Old tasks retain only the old handle.
    var accountDatabaseDidChange: (() async -> Void)?

    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case offline
        case error(String)
    }

    enum AuthAction: Equatable { case none, connect, disconnect }

    /// `.unknown` during bootstrap leaves PowerSync alone. A session that needs
    /// reauthentication cannot authorize uploads, so it disconnects without
    /// clearing until the original account signs in again.
    static func action(for state: AuthClient.State, requiresReauthentication: Bool = false) -> AuthAction {
        if requiresReauthentication { return .disconnect }
        switch state {
        case .unknown: return .none
        case .signedIn: return .connect
        case .signedOut: return .disconnect
        }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var pendingUploadCount = 0
    private(set) var database: PowerSyncDatabaseProtocol

    private let auth: AuthClient
    private let issues: SyncIssueStore
    private var connector: APIConnector?
    private var authCancellables = Set<AnyCancellable>()
    private var statusTask: Task<Void, Never>?
    private var pendingCountTask: Task<Void, Never>?

    init(auth: AuthClient, issues: SyncIssueStore, database: (any PowerSyncDatabaseProtocol)? = nil, databaseFilename: String = SyncAppConfiguration.databaseFilename) {
        self.auth = auth
        self.issues = issues
        self.databaseFilename = databaseFilename
        self.injectedDatabase = database
        self.database = database ?? PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: ":memory:")
        auth.prepareAccount = { [weak self] owner in try await self?.selectAccount(owner) }
        auth.releaseAccount = { [weak self] in try await self?.releaseAccount() }
        auth.deleteLocalAccount = { [weak self] in try await self?.deleteAccountData() }
    }

    /// Serialized by AuthClient's session transition. Never redirect an existing
    /// handle to another account: suspended repository writes must fail closed.
    func selectAccount(_ owner: UUID) async throws {
        guard accountID != owner else { return }
        try await releaseAccount()
        let filename = auth.legacyOwnerID == owner
            ? databaseFilename
            : "\(databaseFilename).account-\(owner.uuidString.lowercased()).sqlite"
        let selected = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: filename)
        do {
            // Initialize before exposing a session, so disk failures cannot unlock
            // the app with an unavailable or previous account's database.
            _ = try await selected.getAll(sql: "select id from profiles limit 0", parameters: [], mapper: { try $0.getString(name: "id") })
            if filename == databaseFilename, UserDefaults.standard.bool(forKey: Self.requiresWipeKey) {
                try await selected.disconnectAndClear()
                UserDefaults.standard.removeObject(forKey: Self.requiresWipeKey)
            }
        } catch {
            try? await selected.close()
            throw error
        }
        database = selected
        accountID = owner
        issues.current = nil
        observeDatabase()
        await accountDatabaseDidChange?()
    }

    func releaseAccount() async throws {
        statusTask?.cancel()
        pendingCountTask?.cancel()
        // close() waits for the old sync connection and upload work to stop.
        // It preserves both SQLite rows and the unacknowledged CRUD queue.
        try await database.close()
        connector = nil
        accountID = nil
        database = PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: ":memory:")
        pendingUploadCount = 0
        status = .idle
        issues.current = nil
        await accountDatabaseDidChange?()
    }

    deinit {
        statusTask?.cancel()
        pendingCountTask?.cancel()
    }

    /// The account(s) that own local data, and whether uploads are queued.
    /// `AuthClient.bootstrap(offlineAccount:)` uses this to bind cached data
    /// to its original owner before any session is adopted.
    func offlineAccount() async throws -> (owners: Set<UUID>, hasPendingWrites: Bool) {
        let legacy = injectedDatabase ?? PowerSyncDatabase(schema: DatabaseSchema.schema, dbFilename: databaseFilename)
        do {
            let rawOwners = try await legacy.getAll(
                sql: SyncAppConfiguration.offlineOwnerQuery,
                parameters: [],
                mapper: { try $0.getString(name: "id") }
            )
            let owners = try Set(rawOwners.map { raw -> UUID in
                guard let id = UUID(uuidString: raw) else {
                    throw APIError(code: "owner_mismatch", message: "Offline account data needs recovery.")
                }
                return id
            })
            let pending = try await legacy.getCrudBatch() != nil
            if injectedDatabase == nil { try await legacy.close() }
            return (owners, pending)
        } catch {
            if injectedDatabase == nil { try? await legacy.close() }
            throw error
        }
    }

    func startObservingAuth() async {
        Publishers.CombineLatest(auth.$state, auth.$requiresReauthentication)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] state, requiresReauthentication in
                Task { @MainActor [weak self] in
                    await self?.reconcile(state, requiresReauthentication: requiresReauthentication)
                }
            }
            .store(in: &authCancellables)

        await reconcile(auth.state, requiresReauthentication: auth.requiresReauthentication)
    }

    private func observeDatabase() {
        statusTask?.cancel()
        let owner = accountID
        let database = database
        statusTask = Task { [weak self] in
            for await update in database.currentStatus.asFlow() {
                guard !Task.isCancelled, self?.accountID == owner else { return }
                await MainActor.run {
                    if let error = update.anyError {
                        self?.status = .error(String(describing: error))
                    } else if update.connected {
                        self?.status = .connected
                    } else if update.connecting {
                        self?.status = .connecting
                    } else if update.hasSynced == true {
                        self?.status = .offline
                    } else {
                        self?.status = .idle
                    }
                }
            }
        }

        pendingCountTask?.cancel()
        pendingCountTask = Task { [weak self] in
            do {
                let stream = try database.watch(
                    sql: "select count(*) as count from ps_crud",
                    parameters: [],
                    mapper: { try $0.getInt(name: "count") }
                )
                for try await rows in stream {
                    guard !Task.isCancelled, self?.accountID == owner else { return }
                    self?.pendingUploadCount = rows.first ?? 0
                }
            } catch {
                Log.error(error, category: "sync.pendingCount")
            }
        }

    }

    private func reconcile(_ state: AuthClient.State, requiresReauthentication: Bool) async {
        guard auth.state == state, auth.requiresReauthentication == requiresReauthentication else { return }
        switch Self.action(for: state, requiresReauthentication: requiresReauthentication) {
        case .connect: await connectIfNeeded()
        case .disconnect: await disconnect()
        case .none: break
        }
    }

    private func connectIfNeeded() async {
        guard connector == nil, let owner = auth.currentUserID, accountID == owner,
              await auth.currentAccessToken(for: owner) != nil else { return }
        guard connector == nil, accountID == owner, auth.currentUserID == owner, auth.canAccessMainApp else { return }
        if let configurationError = AppSecrets.powerSyncConfigurationError {
            status = .error(configurationError)
            return
        }

        status = .connecting
        let connector = APIConnector(auth: auth, issues: issues, owner: owner)
        self.connector = connector
        do {
            try await database.connect(connector: connector)
        } catch {
            guard accountID == owner else { return }
            self.connector = nil
            status = .error(error.localizedDescription)
            Log.error(error, category: "sync.connect")
        }
    }

    func retryConnection() async {
        await connectIfNeeded()
    }

    private func disconnect() async {
        guard connector != nil else { return }
        let owner = accountID
        do {
            try await database.disconnect()
            guard accountID == owner else { return }
            connector = nil
            status = .idle
        } catch {
            Log.error(error, category: "sync.disconnect")
        }
    }

    /// Account deletion is the only automatic destructive path. Other account
    /// databases and their queues are untouched, even if this deletion fails.
    func deleteAccountData() async throws {
        guard let owner = accountID else { return }
        try await database.disconnectAndClear()
        if auth.legacyOwnerID == owner { auth.clearOfflineOwner() }
    }
}
