import Foundation
import XCTest
@testable import DeadWaxClub

@MainActor
final class AccountCoverArtTests: XCTestCase {
    func testLegacyCoverIsAvailableOfflineOnlyToItsOriginalAccount() throws {
        let owner = UUID(), other = UUID()
        let id = UUID().uuidString.lowercased()
        let legacy = CoverArtCache.coversDir.appendingPathComponent("\(id).jpg")
        try FileManager.default.createDirectory(at: CoverArtCache.coversDir, withIntermediateDirectories: true)
        try Data("existing-cover".utf8).write(to: legacy)
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: CoverArtCache.coversDir.appendingPathComponent(owner.uuidString.lowercased()))
            try? FileManager.default.removeItem(at: CoverArtCache.coversDir.appendingPathComponent(other.uuidString.lowercased()))
        }
        let record = VinylRecord(id: id, collectionID: UUID().uuidString, status: .owned, title: "Offline record", artist: "Test artist", createdAt: Date(), updatedAt: Date())
        let auth = AuthClient()
        let original = CoverArtCache(authClient: auth, owner: owner, legacyOwner: owner)
        let originalURL = try XCTUnwrap(original.displayURL(for: record))
        XCTAssertTrue(originalURL.isFileURL)
        XCTAssertEqual(try Data(contentsOf: originalURL), Data("existing-cover".utf8))
        let different = CoverArtCache(authClient: auth, owner: other, legacyOwner: owner)
        XCTAssertNil(different.displayURL(for: record))
    }
}
