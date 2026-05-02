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

        // Forward objectWillChange from owned services so SwiftUI views that
        // hold AppServices as @EnvironmentObject re-render when auth/sync
        // state changes.
        for child: ObservableObject in [auth, sync, discogs, records, prices] {
            (child.objectWillChange as? ObservableObjectPublisher)?
                .sink { [weak self] in self?.objectWillChange.send() }
                .store(in: &cancellables)
        }

        Task { await sync.startObservingAuth() }
    }
}
