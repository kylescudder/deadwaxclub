import XCTest
@testable import DeadWaxClub

final class PushGatewayConfigurationTests: XCTestCase {
    func testMissingOrEmptyURLDisablesGateway() {
        XCTAssertNil(PushGatewayConfiguration.from(infoDictionary: [
            "PUSH_GATEWAY_APPLICATION_ID": "deadwaxclub",
        ]))
        XCTAssertNil(PushGatewayConfiguration.from(infoDictionary: [
            "PUSH_GATEWAY_URL": "",
            "PUSH_GATEWAY_APPLICATION_ID": "deadwaxclub",
        ]))
    }

    func testMalformedURLDisablesGatewayWithoutCrashing() {
        for value in ["not a url", "push.example.com", "ftp://push.example.com"] {
            XCTAssertNil(PushGatewayConfiguration.from(infoDictionary: [
                "PUSH_GATEWAY_URL": value,
                "PUSH_GATEWAY_APPLICATION_ID": "deadwaxclub",
            ]))
        }
    }

    func testMissingOrInvalidApplicationIDDisablesGateway() {
        XCTAssertNil(PushGatewayConfiguration.from(infoDictionary: [
            "PUSH_GATEWAY_URL": "https://push.example.com",
        ]))
        XCTAssertNil(PushGatewayConfiguration.from(infoDictionary: [
            "PUSH_GATEWAY_URL": "https://push.example.com",
            "PUSH_GATEWAY_APPLICATION_ID": "Deadwax Club",
        ]))
    }

    func testValidConfigurationIsParsedExactly() {
        let configuration = PushGatewayConfiguration.from(infoDictionary: [
            "PUSH_GATEWAY_URL": "https://push.example.com/base/",
            "PUSH_GATEWAY_APPLICATION_ID": "deadwaxclub",
        ])

        XCTAssertEqual(configuration?.baseURL.absoluteString, "https://push.example.com/base/")
        XCTAssertEqual(configuration?.applicationID, "deadwaxclub")
    }
}

