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
    let profile: ProfileRepository
    let lists: ListsRepository
    let onboarding: OnboardingCoordinator

    /// Set when iOS hands us a notification with a `record_id`; RootView
    /// observes and presents the record detail in a sheet.
    @Published var pendingDeepLinkRecord: VinylRecord?

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
        self.profile = ProfileRepository(database: sync.database, auth: auth)
        self.lists = ListsRepository(database: sync.database, auth: auth)
        self.onboarding = OnboardingCoordinator()

        for child: any ObservableObject in [auth, sync, discogs, records, prices, profile, lists, onboarding] {
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
            onboarding.current = nil
            return
        }
        let id = userID.uuidString
        profile.startWatching(userID: id)
        lists.startWatching(userID: id)
        evaluateOnboarding()
        Task { await PushManager.shared.registerIfAuthorized() }
    }

    private func openRecordByID(_ recordID: String) async {
        // Find from local SQLite — works offline because PowerSync syncs.
        do {
            let rows = try await sync.database.getAll(
                sql: "select * from records where id = ? limit 1",
                parameters: [recordID],
                mapper: { VinylRecord.from(cursor: $0) }
            )
            if let r = rows.compactMap({ $0 }).first {
                await MainActor.run { self.pendingDeepLinkRecord = r }
            }
        } catch {
            Log.error(error, category: "deeplink")
        }
    }

    func evaluateOnboarding() {
        Task { @MainActor in
            await PushManager.shared.refreshAuthorizationStatus()
            onboarding.reconcile(
                profileDisplayName: profile.profile?.displayName,
                hasDiscogsToken: discogs.hasToken,
                notificationsAuthorized: PushManager.shared.authorizationStatus == .authorized
            )
        }
    }
}
