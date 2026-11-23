import Foundation
import XCTest
@testable import AppUnderTest

/// Deadwax's notification-tap routing (`PushAppConfiguration.route(for:)`).
final class PushRoutingTests: XCTestCase {
    func testCollectionInviteOpensTheCollection() {
        let route = PushAppConfiguration.route(for: ["kind": "collection_invite", "collection_id": "c1", "record_id": "r1"])
        XCTAssertEqual(route, PushRoute(name: .openCollection, userInfo: ["collection_id": "c1"]))
    }

    func testPriceAlertOpensTheRecord() {
        XCTAssertEqual(
            PushAppConfiguration.route(for: ["kind": "price_alert", "record_id": "r1"]),
            PushRoute(name: .openRecord, userInfo: ["record_id": "r1"])
        )
        XCTAssertEqual(
            PushAppConfiguration.route(for: ["record_id": "r1"]),
            PushRoute(name: .openRecord, userInfo: ["record_id": "r1"])
        )
    }

    func testInviteWithoutCollectionFallsBackToRecordOrNothing() {
        XCTAssertEqual(
            PushAppConfiguration.route(for: ["kind": "collection_invite", "record_id": "r1"]),
            PushRoute(name: .openRecord, userInfo: ["record_id": "r1"])
        )
        XCTAssertNil(PushAppConfiguration.route(for: ["kind": "collection_invite"]))
        XCTAssertNil(PushAppConfiguration.route(for: [:]))
    }
}
