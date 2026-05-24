import Foundation
import SwiftUI
import Combine

@MainActor
final class AppServices: ObservableObject {
    let auth: AuthClient
    let sync: PowerSyncManager
    let discogs: DiscogsClient
    let coverArt: CoverArtCache
    let records: RecordsRepository
    let prices: PriceEntriesRepository
    let recordImages: RecordImagesRepository
    let profile: ProfileRepository
    let lists: ListsRepository
    let collections: CollectionsRepository
    let notifications: NotificationsRepository
    let onboarding: OnboardingCoordinator

    /// Set when iOS hands us a notification with a `record_id`; RootView
    /// observes and presents the record detail in a sheet.
    @Published var pendingDeepLinkRecord: VinylRecord?

    /// Set when a notification or deep-link asks us to open a Collection
    /// (e.g. tapping a `collection_invite` push). Settings/RootView present
    /// ManageCollectionsView focused on this Collection.
    @Published var pendingDeepLinkCollectionID: String?

    private var cancellables = Set<AnyCancellable>()

    init() {
        let auth = AuthClient()
        let sync = PowerSyncManager(authClient: auth)
        let discogs = DiscogsClient()
        let coverArt = CoverArtCache(authClient: auth)

        self.auth = auth
        self.sync = sync
        self.discogs = discogs
        self.coverArt = coverArt
        self.records = RecordsRepository(database: sync.database)
        self.prices = PriceEntriesRepository(database: sync.database)
        self.recordImages = RecordImagesRepository(database: sync.database)
        self.profile = ProfileRepository(database: sync.database, auth: auth)
        self.lists = ListsRepository(database: sync.database, auth: auth)
        self.collections = CollectionsRepository(database: sync.database, auth: auth)
        self.notifications = NotificationsRepository(database: sync.database)
        self.onboarding = OnboardingCoordinator()

        for child: any ObservableObject in [auth, sync, discogs, records, prices, recordImages, profile, lists, collections, notifications, onboarding] {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        PushManager.shared.bind(auth: auth)
        Task { await sync.startObservingAuth() }

        NotificationCenter.default.publisher(for: .openRecord)
            .compactMap { $0.userInfo?["record_id"] as? String }
            .sink { [weak self] recordID in
                Task { [weak self] in await self?.openRecordByID(recordID) }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .openCollection)
            .compactMap { $0.userInfo?["collection_id"] as? String }
            .sink { [weak self] collectionID in
                Task { @MainActor [weak self] in
                    self?.pendingDeepLinkCollectionID = collectionID
                }
            }
            .store(in: &cancellables)

        // When the user signs in, start watching their profile and trigger
        // onboarding evaluation. When they sign out, stop watching.
        auth.$state
            .removeDuplicates()
            .sink { [weak self] state in
                guard let self else { return }
                Task { @MainActor in self.applyAuth(state: state) }
            }
            .store(in: &cancellables)
    }

    private func applyAuth(state: AuthClient.State) {
        guard case let .signedIn(userID, _) = state else {
            onboarding.resetForSignOut()
            collections.stopWatching()
            notifications.stopWatching()
            return
        }
        let id = userID.lowerUUID
        profile.startWatching(userID: id)
        lists.startWatching(userID: id)
        collections.startWatching(userID: id)
        notifications.startWatching(userID: id)
        evaluateOnboarding()
        Task { await PushManager.shared.registerIfAuthorized() }
    }

    private func openRecordByID(_ recordID: String) async {
        // Find from local SQLite — works offline because PowerSync syncs.
        if let record = await records.findByID(recordID) {
            await MainActor.run { self.pendingDeepLinkRecord = record }
        }
    }

    func evaluateOnboarding() {
        Task { @MainActor in
            await PushManager.shared.refreshAuthorizationStatus()
            onboarding.reconcile(
                profileLoaded: profile.hasLoadedFromLocal,
                profileDisplayName: profile.profile?.displayName,
                hasDiscogsToken: discogs.hasToken,
                notificationsAuthorized: PushManager.shared.authorizationStatus == .authorized
            )
        }
    }

    /// Persist every Discogs image URL for a record into `record_images`,
    /// then eagerly mirror the bytes into Supabase Storage. Idempotent — if a
    /// row already exists for a given source_url, it's left alone; rows that
    /// already have a storage_path are skipped during mirroring.
    ///
    /// Use this from save sites instead of calling
    /// `recordImages.bulkInsertFromDiscogs` directly so the bytes land in
    /// Storage immediately rather than waiting for the user to swipe to that
    /// carousel slide (which may never happen).
    func ingestDiscogsImages(recordID: String, collectionID: String, sourceURLs: [String]) async {
        guard !sourceURLs.isEmpty else { return }
        await recordImages.bulkInsertFromDiscogs(
            recordID: recordID,
            collectionID: collectionID,
            sourceURLs: sourceURLs
        )
        await mirrorPendingImages(forRecord: recordID)
    }

    /// Mirror every record_images row for this record that has a source_url
    /// but no storage_path yet. Safe to call repeatedly. Detail screens call
    /// this on appear to catch any rows that weren't mirrored at save time.
    func mirrorPendingImages(forRecord recordID: String) async {
        guard let record = await records.findByID(recordID) else { return }
        let rows: [RecordImage]
        do {
            let raw: [RecordImage?] = try await sync.database.getAll(
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
        } catch {
            Log.error(error, category: "appServices.mirrorPending")
            return
        }

        for image in rows {
            await coverArt.mirrorIfNeeded(image: image, record: record) { [weak self] newPath in
                Task { @MainActor [weak self] in
                    await self?.recordImages.updateStoragePath(
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
