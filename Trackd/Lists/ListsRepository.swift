import Foundation
import PowerSync

/// Stub repository — full lists feature is implemented in a later commit.
/// Kept here so AppServices can wire it now and views can be added incrementally.
@MainActor
final class ListsRepository: ObservableObject {
    @Published private(set) var lists: [VinylList] = []

    private let database: PowerSyncDatabaseProtocol
    private let auth: AuthClient

    init(database: PowerSyncDatabaseProtocol, auth: AuthClient) {
        self.database = database
        self.auth = auth
    }
}
