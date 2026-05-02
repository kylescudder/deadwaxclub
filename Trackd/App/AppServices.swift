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

        for child: ObservableObject in [auth, sync, discogs, records, prices, profile, lists, onboarding] {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        PushManager.shared.bind(auth: auth)
        Task { await sync.startObservingAuth() }

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
