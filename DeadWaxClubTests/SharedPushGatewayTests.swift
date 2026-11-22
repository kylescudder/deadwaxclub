import Foundation
import XCTest
#if canImport(Diald)
@testable import Diald
#else
@testable import DeadWaxClub
#endif

/// The shared push gateway configuration and transport
/// (`docs/push-gateway.md`).

@MainActor
final class SharedPushGatewayTests: XCTestCase {
    private let installationID = UUID(uuidString: "550d5a6b-7248-49da-a4dc-92db45608c07")!
    private let identity = PushIdentity(
        principalID: "principal-must-not-be-sent",
        accessToken: "test-access-token"
    )

    func testRegisterSendsCanonicalRequestAndPreservesLeadingTokenBytes() async throws {
        let captured = CapturedRequestStore()
        URLProtocolStub.setHandler { request in
            captured.set(request)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        try await makeTransport(baseURL: "https://push.example.com/").register(
            installationID: installationID,
            deviceToken: Data([0x00, 0x0a, 0xff]),
            environment: .sandbox,
            identity: identity
        )

        let request = try XCTUnwrap(captured.get())
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://push.example.com/v1/apps/exampleapp/installations/550d5a6b-7248-49da-a4dc-92db45608c07"
        )
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["apns_token"] as? String, "000aff")
        XCTAssertEqual(json["apns_environment"] as? String, "sandbox")
        XCTAssertNil(json["principal_id"])
        XCTAssertNil(json["bundle_id"])
        XCTAssertNil(json["team_id"])
        XCTAssertEqual(Set(json.keys), ["version", "platform", "apns_token", "apns_environment"])
    }

    func testUnregisterSendsCanonicalBodylessRequest() async throws {
        let captured = CapturedRequestStore()
        URLProtocolStub.setHandler { request in
            captured.set(request)
            return (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 204,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        try await makeTransport().unregister(
            installationID: installationID,
            identity: identity
        )

        let request = try XCTUnwrap(captured.get())
        XCTAssertEqual(
            request.url?.absoluteString,
            "https://push.example.com/v1/apps/exampleapp/installations/550d5a6b-7248-49da-a4dc-92db45608c07/account-link"
        )
        XCTAssertEqual(request.httpMethod, "DELETE")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertNil(request.httpBody)
    }

    func testEvery2xxResponseSucceeds() async throws {
        URLProtocolStub.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 299,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        try await makeTransport().register(
            installationID: installationID,
            deviceToken: Data([0x01]),
            environment: .production,
            identity: identity
        )
    }

    func testNon2xxResponseIsTypedFailure() async {
        URLProtocolStub.setHandler { request in
            (
                HTTPURLResponse(
                    url: request.url!,
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }

        do {
            try await makeTransport().register(
                installationID: installationID,
                deviceToken: Data([0x01]),
                environment: .production,
                identity: identity
            )
            XCTFail("Expected an HTTP status error")
        } catch {
            XCTAssertEqual(error as? PushGatewayError, .httpStatus(503))
        }
    }

    func testNonHTTPResponseIsTypedFailure() async {
        URLProtocolStub.setHandler { request in
            (
                URLResponse(
                    url: request.url!,
                    mimeType: nil,
                    expectedContentLength: 0,
                    textEncodingName: nil
                ),
                Data()
            )
        }

        do {
            try await makeTransport().unregister(
                installationID: installationID,
                identity: identity
            )
            XCTFail("Expected an invalid response error")
        } catch {
            XCTAssertEqual(error as? PushGatewayError, .invalidResponse)
        }
    }

    func testEmptyOrMissingURLDisablesGateway() {
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: nil, applicationID: "exampleapp"))
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: "", applicationID: "exampleapp"))
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: "   ", applicationID: "exampleapp"))
    }

    func testMalformedURLDisablesGateway() {
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: "not a url", applicationID: "exampleapp"))
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: "ftp://push.example.com", applicationID: "exampleapp"))
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: "https:///missing-host", applicationID: "exampleapp"))
    }

    func testPlaintextURLsDisableGatewayIncludingLocalhost() {
        for url in ["http://push.example.com", "http://localhost:8080", "http://127.0.0.1"] {
            let configuration = PushGatewayConfiguration.make(rawURL: url, applicationID: "exampleapp")
            XCTAssertNil(configuration)
            XCTAssertEqual(PushRegistrationTransportKind.selected(for: configuration), .api)
        }
    }

    func testMissingOrInvalidApplicationIDDisablesGateway() {
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: "https://push.example.com", applicationID: nil))
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: "https://push.example.com", applicationID: ""))
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: "https://push.example.com", applicationID: "Example App"))
        XCTAssertNil(PushGatewayConfiguration.make(rawURL: "https://push.example.com", applicationID: "d"))
    }

    func testValidConfigurationIsParsedExactly() throws {
        let configuration = try XCTUnwrap(PushGatewayConfiguration.make(
            rawURL: "https://push.example.com/base/",
            applicationID: "exampleapp"
        ))

        XCTAssertEqual(configuration.baseURL.absoluteString, "https://push.example.com/base/")
        XCTAssertEqual(configuration.applicationID, "exampleapp")
    }

    func testTransportSelectionUsesExactlyOneConfiguredPath() {
        XCTAssertEqual(PushRegistrationTransportKind.selected(for: nil), .api)
        let configuration = PushGatewayConfiguration(
            baseURL: URL(string: "https://push.example.com")!,
            applicationID: "exampleapp"
        )
        XCTAssertEqual(PushRegistrationTransportKind.selected(for: configuration), .gateway)
    }

    func testInfoDictionaryKeysConfigureTheGateway() {
        XCTAssertNil(PushGatewayConfiguration.from(infoDictionary: ["PUSH_GATEWAY_APPLICATION_ID": "exampleapp"]))
        XCTAssertNil(PushGatewayConfiguration.from(infoDictionary: ["PUSH_GATEWAY_URL": "", "PUSH_GATEWAY_APPLICATION_ID": "exampleapp"]))
        XCTAssertNil(PushGatewayConfiguration.from(infoDictionary: ["PUSH_GATEWAY_URL": "https://push.example.com"]))
        XCTAssertNil(PushGatewayConfiguration.from(infoDictionary: ["PUSH_GATEWAY_URL": "push.example.com", "PUSH_GATEWAY_APPLICATION_ID": "exampleapp"]))
        let configuration = PushGatewayConfiguration.from(infoDictionary: [
            "PUSH_GATEWAY_URL": "https://push.example.com/base/",
            "PUSH_GATEWAY_APPLICATION_ID": "exampleapp",
        ])
        XCTAssertEqual(configuration?.baseURL.absoluteString, "https://push.example.com/base/")
        XCTAssertEqual(configuration?.applicationID, "exampleapp")
    }

    private func makeTransport(
        baseURL: String = "https://push.example.com"
    ) -> GatewayPushRegistrationTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return GatewayPushRegistrationTransport(
            configuration: PushGatewayConfiguration(
                baseURL: URL(string: baseURL)!,
                applicationID: "exampleapp"
            ),
            session: URLSession(configuration: configuration)
        )
    }
}

private final class CapturedRequestStore: @unchecked Sendable {
    private let lock = NSLock()
    private var request: URLRequest?

    func set(_ request: URLRequest) {
        lock.lock()
        self.request = request
        lock.unlock()
    }

    func get() -> URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return request
    }
}

private final class URLProtocolHandlerStorage: @unchecked Sendable {
    typealias Handler = (URLRequest) throws -> (URLResponse, Data)

    private let lock = NSLock()
    private var handler: Handler?

    func set(_ handler: Handler?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func response(for request: URLRequest) throws -> (URLResponse, Data) {
        lock.lock()
        let handler = handler
        lock.unlock()
        guard let handler else { throw URLError(.badServerResponse) }
        return try handler(request)
    }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    private static let storage = URLProtocolHandlerStorage()

    static func setHandler(_ handler: @escaping URLProtocolHandlerStorage.Handler) {
        storage.set(handler)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let (response, data) = try Self.storage.response(for: request.materializingHTTPBody())
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !data.isEmpty {
                client?.urlProtocol(self, didLoad: data)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private extension URLRequest {
    func materializingHTTPBody() -> URLRequest {
        guard httpBody == nil, let stream = httpBodyStream else { return self }
        stream.open()
        defer { stream.close() }

        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            body.append(contentsOf: buffer.prefix(count))
        }

        var copy = self
        copy.httpBody = body
        return copy
    }
}
