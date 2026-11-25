import Foundation
import SwiftUI
import Combine

@MainActor
final class AppServices: ObservableObject {
    nonisolated static let freeRecordLimit = 5

    let auth: AuthClient
    let sync: PowerSyncManager
    let syncIssues: SyncIssueStore
    let billing: BillingRepository
    private(set) var discogs: DiscogsClient
    private(set) var coverArt: CoverArtCache
    private(set) var records: RecordsRepository
    private(set) var prices: PriceEntriesRepository
    private(set) var recordImages: RecordImagesRepository
    private(set) var profile: ProfileRepository
    private(set) var lists: ListsRepository
    private(set) var collections: CollectionsRepository
    private(set) var notifications: NotificationsRepository
    let onboarding: OnboardingCoordinator

    /// Set when iOS hands us a notification with a `record_id`; RootView
    /// observes and presents the record detail in a sheet.
    @Published var pendingDeepLinkRecord: VinylRecord?

    /// Set when a notification or deep-link asks us to open a Collection
    /// (e.g. tapping a `collection_invite` push). Settings/RootView present
    /// ManageCollectionsView focused on this Collection.
    @Published var pendingDeepLinkCollectionID: String?
    /// An invite email's link was opened; RootView shows the invites once signed in.
    @Published var showsInvites = false

    /// The creation allowance the shared paywall reports.
    var creationQuota: any CreationQuotaProviding { records }

    private var cancellables = Set<AnyCancellable>()
    private var accountCancellables = Set<AnyCancellable>()

    init(auth: AuthClient = AuthClient(), databaseFilename: String = SyncAppConfiguration.databaseFilename) {
        Log.breadcrumb("app services initializing", category: "app.lifecycle")
        let syncIssues = SyncIssueStore()
        let sync = PowerSyncManager(auth: auth, issues: syncIssues, databaseFilename: databaseFilename)
        let billing = BillingRepository(auth: auth)
        let discogs = DiscogsClient()
        let coverArt = CoverArtCache(authClient: auth)

        self.auth = auth
        self.sync = sync
        self.syncIssues = syncIssues
        self.billing = billing
        self.discogs = discogs
        self.coverArt = coverArt
        self.records = RecordsRepository(database: sync.database, issues: syncIssues, auth: auth, billing: billing, owner: sync.accountID)
        self.prices = PriceEntriesRepository(database: sync.database)
        self.recordImages = RecordImagesRepository(database: sync.database)
        self.profile = ProfileRepository(database: sync.database, auth: auth)
        self.lists = ListsRepository(database: sync.database, auth: auth, owner: sync.accountID)
        self.collections = CollectionsRepository(database: sync.database, auth: auth, owner: sync.accountID)
        self.notifications = NotificationsRepository(database: sync.database)
        self.onboarding = OnboardingCoordinator()

        for child: any ObservableObject in [auth, sync, syncIssues, billing, onboarding] {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        let pushManager = PushManager.shared
        pushManager.bind(auth: auth)
        auth.beforeSessionInvalidation = { [weak pushManager] in
            await pushManager?.deactivate()
        }
        auth.afterSessionInvalidationFailure = { [weak pushManager] in
            await pushManager?.activate()
        }
        auth.deleteLocalAccount = { [weak self, weak sync] in
            try await sync?.deleteAccountData()
            self?.discogs.clearToken()
            self?.coverArt.removeAccountCache()
        }
        sync.accountDatabaseDidChange = { [weak self] in self?.replaceAccountRepositories() }
        bindAccountPublishers()
        billing.start()
        Task { await sync.startObservingAuth() }

        NotificationCenter.default.publisher(for: .openRecord)
            .compactMap { $0.userInfo?["record_id"] as? String }
            .sink { [weak self] recordID in
                Log.event("record deeplink received", category: "app.deeplink", metadata: ["recordID": recordID])
                Task { [weak self] in await self?.openRecordByID(recordID) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openCollection)
            .compactMap { $0.userInfo?["collection_id"] as? String }
            .sink { [weak self] collectionID in
                Task { @MainActor [weak self] in
                    Log.event("collection deeplink received", category: "app.deeplink", metadata: ["collectionID": collectionID])
                    self?.pendingDeepLinkCollectionID = collectionID
                }
            }
            .store(in: &cancellables)

        // When the user signs in, start watching their profile and trigger
        // onboarding evaluation. When they sign out, stop watching.
        auth.$state.combineLatest(auth.$requiresReauthentication)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .sink { [weak self] state, _ in
                guard let self else { return }
                Task { @MainActor in self.applyAuth(state: state) }
            }
            .store(in: &cancellables)

    }

    private func replaceAccountRepositories() {
        records.stopWatching()
        prices.stopWatching()
        recordImages.stopWatching()
        profile.stopWatching()
        lists.stopWatching()
        collections.stopWatching()
        notifications.stopWatching()
        SpotlightIndex.clearAll()
        pendingDeepLinkRecord = nil
        pendingDeepLinkCollectionID = nil
        onboarding.resetForSignOut()
        billing.resetForSignOut()
        records = RecordsRepository(database: sync.database, issues: syncIssues, auth: auth, billing: billing, owner: sync.accountID)
        prices = PriceEntriesRepository(database: sync.database)
        recordImages = RecordImagesRepository(database: sync.database)
        profile = ProfileRepository(database: sync.database, auth: auth)
        lists = ListsRepository(database: sync.database, auth: auth, owner: sync.accountID)
        collections = CollectionsRepository(database: sync.database, auth: auth, owner: sync.accountID)
        notifications = NotificationsRepository(database: sync.database)
        coverArt = CoverArtCache(authClient: auth, owner: sync.accountID, legacyOwner: auth.legacyOwnerID)
        discogs = DiscogsClient(owner: sync.accountID, legacyOwner: auth.legacyOwnerID)
        bindAccountPublishers()
        objectWillChange.send()
    }

    private func bindAccountPublishers() {
        accountCancellables.removeAll()
        for child: any ObservableObject in [discogs, records, prices, recordImages, profile, lists, collections, notifications] {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &accountCancellables)
        }
        profile.$profile
            .map { $0?.isPremiumAccount == true }
            .removeDuplicates()
            .sink { [weak billing] isPremiumAccount in
                billing?.setAccessOverride(isPremiumAccount)
            }
            .store(in: &accountCancellables)
    }

    private func applyAuth(state: AuthClient.State) {
        guard auth.state == state else { return }
        Log.event("app services applying auth state", category: "app.auth", metadata: ["state": state.loggingDescription])
        guard auth.canAccessMainApp, case let .signedIn(userID, _) = state else {
            PushManager.shared.sessionEnded()
            onboarding.resetForSignOut()
            billing.resetForSignOut()
            records.stopWatching()
            prices.stopWatching()
            recordImages.stopWatching()
            profile.stopWatching()
            lists.stopWatching()
            collections.stopWatching()
            notifications.stopWatching()
            return
        }
        onboarding.selectAccount(userID)
        let id = userID.lowerUUID
        profile.startWatching(userID: id)
        lists.startWatching(userID: id)
        collections.startWatching(userID: id)
        notifications.startWatching(userID: id)
        Task { await billing.syncEntitlements() }
        evaluateOnboarding()
        Task {
            guard auth.state == state else { return }
            await PushManager.shared.activate()
        }
    }

    func canCreateNewRecord() async -> Bool {
        guard let userID = auth.currentUserID?.lowerUUID else {
            Log.warning("record creation limit check failed: no authenticated user", category: "billing.limit")
            return false
        }
        let status: RecordCreationStatus
        do {
            if sync.status == .offline || auth.requiresReauthentication {
                status = try await records.localRecordCreationStatus(userID: userID)
            } else {
                do {
                    status = try await records.recordCreationStatus()
                } catch where RecordCreationFailure.isConnectivityFailure(error) {
                    status = try await records.localRecordCreationStatus(userID: userID)
                }
            }
        } catch RecordCreationError.quotaSnapshotUnavailable {
            syncIssues.reportQuotaSnapshotUnavailable()
            return false
        } catch {
            Log.error(error, category: "billing.limit")
            return false
        }
        if RecordCreationAuthorization.allowsUnlimited(
            billingIsSubscribed: billing.isSubscribed,
            snapshotHasVerifiedEntitlement: status.hasVerifiedEntitlement
        ) {
            Log.breadcrumb("record creation allowed by verified subscription snapshot", category: "billing.limit")
            return true
        }
        let allowed = status.lifetimeRecordCount < status.freeLimit
        Log.event("record creation limit checked", category: "billing.limit", metadata: [
            "count": status.lifetimeRecordCount,
            "limit": status.freeLimit,
            "allowed": allowed,
        ])
        return allowed
    }

    private func openRecordByID(_ recordID: String) async {
        guard let owner = auth.currentUserID, !auth.isPasswordRecovery else { return }
        // Find from local SQLite — works offline because PowerSync syncs.
        if let record = await records.findByID(recordID) {
            guard auth.currentUserID == owner, !auth.isPasswordRecovery else { return }
            Log.event("record deeplink resolved", category: "app.deeplink", metadata: ["recordID": recordID])
            await MainActor.run { self.pendingDeepLinkRecord = record }
        } else {
            Log.warning("record deeplink could not be resolved", category: "app.deeplink")
        }
    }

    func evaluateOnboarding() {
        guard auth.canAccessMainApp, let owner = auth.currentUserID else { return }
        Log.breadcrumb("onboarding evaluation scheduled", category: "onboarding")
        Task { @MainActor in
            await PushManager.shared.refreshAuthorizationStatus()
            guard auth.canAccessMainApp, auth.currentUserID == owner else { return }
            let notificationsAuthorized = PushManager.shared.authorizationStatus == .authorized
            Log.event("onboarding evaluation running", category: "onboarding", metadata: [
                "profileLoaded": profile.hasLoadedFromLocal,
                "hasDisplayName": profile.profile?.displayName?.isEmpty == false,
                "hasDiscogsToken": discogs.hasToken,
                "notificationsAuthorized": notificationsAuthorized,
            ])
            onboarding.reconcile(
                profileLoaded: profile.hasLoadedFromLocal,
                profileDisplayName: profile.profile?.displayName,
                hasDiscogsToken: discogs.hasToken,
                notificationsAuthorized: notificationsAuthorized
            )
        }
    }

    /// Persist every Discogs image URL for a record into `record_images`,
    /// then eagerly mirror the bytes into the Deadwax API's cover store. Idempotent — if a
    /// row already exists for a given source_url, it's left alone; rows that
    /// already have a storage_path are skipped during mirroring.
    ///
    /// Use this from save sites instead of calling
    /// `recordImages.bulkInsertFromDiscogs` directly so the bytes land in
    /// Storage immediately rather than waiting for the user to swipe to that
    /// carousel slide (which may never happen).
    func ingestDiscogsImages(recordID: String, collectionID: String, sourceURLs: [String]) async {
        guard !sourceURLs.isEmpty, auth.canAccessMainApp, let owner = auth.currentUserID else { return }
        let imageRepository = recordImages
        Log.event("discogs image ingestion started", category: "images.ingest", metadata: [
            "recordID": recordID,
            "collectionID": collectionID,
            "sourceCount": sourceURLs.count,
        ])
        await imageRepository.bulkInsertFromDiscogs(
            recordID: recordID,
            collectionID: collectionID,
            sourceURLs: sourceURLs
        )
        guard auth.canAccessMainApp, auth.currentUserID == owner else { return }
        await mirrorPendingImages(forRecord: recordID)
        Log.event("discogs image ingestion completed", category: "images.ingest", metadata: ["recordID": recordID])
    }

    /// Mirror every record_images row for this record that has a source_url
    /// but no storage_path yet. Safe to call repeatedly. Detail screens call
    /// this on appear to catch any rows that weren't mirrored at save time.
    func mirrorPendingImages(forRecord recordID: String) async {
        guard auth.canAccessMainApp else { return }
        let recordRepository = records
        let imageRepository = recordImages
        let database = sync.database
        let coverArt = coverArt
        Log.event("pending image mirror started", category: "images.mirror", metadata: ["recordID": recordID])
        guard let record = await recordRepository.findByID(recordID) else {
            Log.warning("pending image mirror skipped: record not found", category: "images.mirror")
            return
        }
        let rows: [RecordImage]
        do {
            let raw: [RecordImage?] = try await database.getAll(
                sql: """
                select * from record_images
                where record_id = ?
                  and kind = 'discogs'
                  and source_url is not null
                  and (storage_path is null or storage_path = '')
                order by position asc
                """,
                parameters: [recordID],
                mapper: { RecordImage.from(cursor: $0) }
            )
            rows = raw.compactMap { $0 }
            Log.event("pending image mirror rows loaded", category: "images.mirror", metadata: [
                "recordID": recordID,
                "count": rows.count,
            ])
        } catch {
            Log.error(error, category: "appServices.mirrorPending")
            return
        }

        for image in rows {
            await coverArt.mirrorIfNeeded(image: image, record: record) { newPath in
                Log.event("pending image mirrored", category: "images.mirror", metadata: [
                    "recordID": recordID,
                    "imageID": image.id,
                ])
                Task { @MainActor in
                    await imageRepository.updateStoragePath(
                        imageID: image.id,
                        storagePath: newPath
                    )
                }
            }
        }
    }
}

extension Notification.Name {
    /// Posted when a push notification with kind=collection_invite is tapped,
    /// or when a deep link routes to a specific Collection. UserInfo contains
    /// `collection_id`.
    static let openCollection = Notification.Name("dwc.openCollection")
}

private extension AuthClient.State {
    var loggingDescription: String {
        switch self {
        case .unknown:
            return "unknown"
        case .signedOut:
            return "signedOut"
        case .signedIn:
            return "signedIn"
        }
    }
}
