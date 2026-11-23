import XCTest
@testable import AppUnderTest

@MainActor
final class SharedAppSecretsTests: XCTestCase {
    func testAcceptsHTTPSOriginsAndDropsATrailingSlash() {
        XCTAssertEqual(AppSecrets.origin(from: "https://api.example.app")?.absoluteString, "https://api.example.app")
        XCTAssertEqual(AppSecrets.origin(from: " https://api.example.app/ ")?.absoluteString, "https://api.example.app")
        XCTAssertEqual(AppSecrets.origin(from: "https://sync.example.app:8443")?.absoluteString, "https://sync.example.app:8443")
    }

    func testAllowsPlainHTTPOnlyOnLoopback() {
        XCTAssertNotNil(AppSecrets.origin(from: "http://localhost:3147"))
        XCTAssertNotNil(AppSecrets.origin(from: "http://127.0.0.1:8080"))
        XCTAssertNil(AppSecrets.origin(from: "http://api.example.app"))
    }

    func testRejectsUnsetUnresolvedAndPlaceholderValues() {
        for value in [
            "",
            "$(API_URL)",
            "https:/$()/api.example.app",
            "https://your-api.invalid",
            "https://your-instance.powersync.journeyapps.com",
            "api.example.app",
        ] {
            XCTAssertNil(AppSecrets.origin(from: value), value)
        }
    }

    func testRejectsAnythingThatIsNotABareOrigin() {
        for value in [
            "https://api.example.app/v1",
            "https://api.example.app?debug=1",
            "https://api.example.app#fragment",
            "https://user:secret@api.example.app",
        ] {
            XCTAssertNil(AppSecrets.origin(from: value), value)
        }
    }

    func testAuthCallbackSchemeComesFromTheAuthURLType() {
        let info: [String: Any] = ["CFBundleURLTypes": [
            ["CFBundleURLName": "app.other", "CFBundleURLSchemes": ["other"]],
            ["CFBundleURLName": "app.auth", "CFBundleURLSchemes": ["app"]],
        ]]
        XCTAssertEqual(AppSecrets.authCallbackScheme(in: info), "app")
        XCTAssertNil(AppSecrets.authCallbackScheme(in: [:]))
    }

    func testBuiltAppRegistersItsAuthCallbackScheme() {
        XCTAssertEqual(AppSecrets.authRedirectURL.path, "")
        XCTAssertEqual(AppSecrets.authRedirectURL.host, "auth-callback")
        XCTAssertNotEqual(AppSecrets.authRedirectURL.scheme, "invalid")
        XCTAssertEqual(AppSecrets.authRedirectURL.scheme, AuthAppConfiguration.callbackScheme)
    }
}
