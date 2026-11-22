import Combine
import Foundation
import PowerSync

/// Shared PowerSync connection lifecycle. This file is identical in every app;
/// the database filename and offline-owner query live in
/// `SyncAppConfiguration.swift` and the schema in `DatabaseSchema.swift`.
///
/// Transient auth changes (a signed-out refresh, or a session that needs
/// reauthentication) only disconnect, keeping local data and the upload
/// queue. `wipe()` is the only path that clears them, and it is reserved for
/// explicit sign-out, password-reset sign-out and account deletion.
@MainActor
final class PowerSyncManager: ObservableObject {
    private static let requiresWipeKey = "sync.requiresWipeBeforeConnect"

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
    let database: PowerSyncDatabaseProtocol

    private let auth: AuthClient
    private let issues: SyncIssueStore
    private var connector: APIConnector?
    private var authCancellables = Set<AnyCancellable>()
    private var statusTask: Task<Void, Never>?
    private var pendingCountTask: Task<Void, Never>?

    init(auth: AuthClient, issues: SyncIssueStore, database: (any PowerSyncDatabaseProtocol)? = nil) {
        self.auth = auth
        self.issues = issues
        self.database = database ?? PowerSyncDatabase(
            schema: DatabaseSchema.schema,
            dbFilename: SyncAppConfiguration.databaseFilename
        )
    }

    deinit {
        statusTask?.cancel()
        pendingCountTask?.cancel()
    }

    /// The account(s) that own local data, and whether uploads are queued.
    /// `AuthClient.bootstrap(offlineAccount:)` uses this to bind cached data
    /// to its original owner before any session is adopted.
    func offlineAccount() async throws -> (owners: Set<UUID>, hasPendingWrites: Bool) {
        let rawOwners = try await database.getAll(
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
        return (owners, try await database.getCrudBatch() != nil)
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

        statusTask?.cancel()
        let database = database
        statusTask = Task { [weak self] in
            for await update in database.currentStatus.asFlow() {
                guard !Task.isCancelled else { return }
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
                    guard !Task.isCancelled else { return }
                    self?.pendingUploadCount = rows.first ?? 0
                }
            } catch {
                Log.error(error, category: "sync.pendingCount")
            }
        }

        await reconcile(auth.state, requiresReauthentication: auth.requiresReauthentication)
    }

    private func reconcile(_ state: AuthClient.State, requiresReauthentication: Bool) async {
        switch Self.action(for: state, requiresReauthentication: requiresReauthentication) {
        case .connect: await connectIfNeeded()
        case .disconnect: await disconnect()
        case .none: break
        }
    }

    private func connectIfNeeded() async {
        guard connector == nil, let owner = auth.currentUserID,
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
        do {
            try await database.disconnect()
            connector = nil
            status = .idle
        } catch {
            Log.error(error, category: "sync.disconnect")
        }
    }

    /// Persist the guard before clearing. A failed clear blocks any later
    /// account from connecting until the wipe succeeds.
    func wipe() async {
        UserDefaults.standard.set(true, forKey: Self.requiresWipeKey)
        do {
            try await database.disconnectAndClear()
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
