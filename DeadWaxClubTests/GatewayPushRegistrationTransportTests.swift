import Foundation
import XCTest
@testable import DeadWaxClub

final class GatewayPushRegistrationTransportTests: XCTestCase {
    private let installationID = UUID(uuidString: "550d5a6b-7248-49da-a4dc-92db45608c07")!
    private let identity = PushIdentity(
        principalID: "principal-must-not-be-sent",
        accessToken: "test-access-token"
    )

    override func tearDown() {
        PushURLProtocol.handler.clear()
        super.tearDown()
    }

    @MainActor
    func testRegisterSendsCanonicalRequestAndPreservesLeadingZeroBytes() async throws {
        let request = RequestCapture()
        PushURLProtocol.handler.set { received in
            request.record(received)
            return Self.response(for: received, statusCode: 204)
        }
        let transport = makeTransport(baseURL: "https://push.example.com/")

        try await transport.register(
            installationID: installationID,
            deviceToken: Data([0x00, 0x0a, 0xff]),
            environment: .sandbox,
            identity: identity
        )

        let captured = try XCTUnwrap(request.value)
        XCTAssertEqual(
            captured.url?.absoluteString,
            "https://push.example.com/v1/apps/deadwaxclub/installations/550d5a6b-7248-49da-a4dc-92db45608c07"
        )
        XCTAssertEqual(captured.httpMethod, "PUT")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Content-Type"), "application/json")

        let body = try XCTUnwrap(captured.httpBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["version"] as? Int, 1)
        XCTAssertEqual(json["platform"] as? String, "ios")
        XCTAssertEqual(json["apns_token"] as? String, "000aff")
        XCTAssertEqual(json["apns_environment"] as? String, "sandbox")
        XCTAssertNil(json["principal_id"])
        XCTAssertNil(json["bundle_id"])
        XCTAssertNil(json["team_id"])
        XCTAssertNil(json["key_id"])
        XCTAssertNil(json["supabase_url"])
    }

    @MainActor
    func testTrailingSlashDoesNotCreateDoubleSlash() async throws {
        let request = RequestCapture()
        PushURLProtocol.handler.set { received in
            request.record(received)
            return Self.response(for: received, statusCode: 200)
        }

        try await makeTransport(baseURL: "https://push.example.com/").register(
            installationID: installationID,
            deviceToken: Data([0x01]),
            environment: .production,
            identity: identity
        )

        XCTAssertEqual(request.value?.url?.path, "/v1/apps/deadwaxclub/installations/550d5a6b-7248-49da-a4dc-92db45608c07")
        XCTAssertFalse(request.value?.url?.absoluteString.contains(".com//") == true)
    }

    @MainActor
    func testUnregisterSendsDeleteWithoutBodyOrToken() async throws {
        let request = RequestCapture()
        PushURLProtocol.handler.set { received in
            request.record(received)
            return Self.response(for: received, statusCode: 204)
        }

        try await makeTransport().unregister(
            installationID: installationID,
            identity: identity
        )

        let captured = try XCTUnwrap(request.value)
        XCTAssertEqual(
            captured.url?.absoluteString,
            "https://push.example.com/v1/apps/deadwaxclub/installations/550d5a6b-7248-49da-a4dc-92db45608c07/account-link"
        )
        XCTAssertEqual(captured.httpMethod, "DELETE")
        XCTAssertEqual(captured.value(forHTTPHeaderField: "Authorization"), "Bearer test-access-token")
        XCTAssertNil(captured.httpBody)
        XCTAssertFalse(captured.url?.absoluteString.contains("000aff") == true)
    }

    @MainActor
    func testNonHTTPResponseIsTypedFailure() async {
        PushURLProtocol.handler.set { request in
            URLResponse(
                url: request.url!,
                mimeType: nil,
                expectedContentLength: 0,
                textEncodingName: nil
            )
        }

        do {
            try await makeTransport().unregister(
                installationID: installationID,
                identity: identity
            )
            XCTFail("Expected invalid response")
        } catch {
            XCTAssertEqual(error as? PushGatewayError, .invalidResponse)
        }
    }

    @MainActor
    func testNonSuccessStatusIsTypedFailure() async {
        PushURLProtocol.handler.set { request in
            Self.response(for: request, statusCode: 503)
        }

        do {
            try await makeTransport().register(
                installationID: installationID,
                deviceToken: Data([0x01]),
                environment: .sandbox,
                identity: identity
            )
            XCTFail("Expected HTTP status failure")
        } catch {
            XCTAssertEqual(error as? PushGatewayError, .httpStatus(503))
        }
    }

    private func makeTransport(
        baseURL: String = "https://push.example.com"
    ) -> GatewayPushRegistrationTransport {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [PushURLProtocol.self]
        return GatewayPushRegistrationTransport(
            configuration: PushGatewayConfiguration(
                baseURL: URL(string: baseURL)!,
                applicationID: "deadwaxclub"
            ),
            session: URLSession(configuration: sessionConfiguration)
        )
    }

    private static func response(for request: URLRequest, statusCode: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/2",
            headerFields: nil
        )!
    }
}

private final class PushURLProtocol: URLProtocol, @unchecked Sendable {
    static let handler = PushURLProtocolHandler()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let response = try Self.handler.response(for: request.materializingHTTPBody())
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
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

private final class PushURLProtocolHandler: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> URLResponse

    private let lock = NSLock()
    private var value: Handler?

    func set(_ handler: @escaping Handler) {
        lock.lock()
        value = handler
        lock.unlock()
    }

    func clear() {
        lock.lock()
        value = nil
        lock.unlock()
    }

    func response(for request: URLRequest) throws -> URLResponse {
        lock.lock()
        let handler = value
        lock.unlock()
        guard let handler else { throw URLError(.badServerResponse) }
        return try handler(request)
    }
}

private final class RequestCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?

    var value: URLRequest? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func record(_ request: URLRequest) {
        lock.lock()
        stored = request
        lock.unlock()
    }
}
