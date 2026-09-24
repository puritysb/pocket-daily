import XCTest
@testable import Pocket

final class ContentPreparationHTTPTests: XCTestCase {
    private func target() throws -> ContentRevision {
        try ContentRevision(cards: [.init(id: "a", title: "A", question: "Text")])
    }
    private func client(body: Data, status: Int = 200) -> (CrossPointClient, URLSession) {
        PreparationURLProtocol.configure(body: body, status: status)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PreparationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return (CrossPointClient(session: session), session)
    }
    private func response(_ target: ContentRevision, id: String = "1234ABCD") -> Data {
        Data("{\"schema\":1,\"deviceID\":\"\(id)\",\"revision\":\"\(target.revision)\",\"fileCount\":1,\"verifiedMask\":1}".utf8)
    }

    func testPostsExpectedIdentityAndRevisionAndDecodesVerifiedFile() async throws {
        let target = try target()
        let (client, session) = client(body: response(target))
        defer { session.invalidateAndCancel() }
        let receipt = try await client.inspectPreparedContent(target, deviceID: "1234ABCD", host: "reader.test", port: 8080)
        XCTAssertEqual(receipt.verifiedFiles.map(\.path), target.files.map(\.path))
        let request = try XCTUnwrap(PreparationURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/pocket/v1/content/prepare")
        XCTAssertEqual(request.url?.port, 8080)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Connection"), "close")
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") }),
                       ["deviceID": "1234ABCD", "revision": target.revision])
        XCTAssertNil(request.httpBody)
    }

    func testBusyAndUnavailableDoNotRetryOrProduceReceipt() async throws {
        for status in [409, 503] {
            let (client, session) = client(body: Data("Another file transfer is active".utf8), status: status)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await client.inspectPreparedContent(target(), deviceID: "1234ABCD", host: "reader.test", port: 80)
                XCTFail("Expected HTTP failure")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains("Another file transfer is active"))
                XCTAssertEqual(PreparationURLProtocol.requests.count, 1)
            }
        }
    }

    func testStorageCopyFailureIsReportedWithoutRetry() async throws {
        let message = "Reader could not copy or verify staged content. Check the SD card and free space."
        let (client, session) = client(body: Data(message.utf8), status: 503)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await client.inspectPreparedContent(target(), deviceID: "1234ABCD", host: "reader.test", port: 80)
            XCTFail("Storage failure must not become a missing-file receipt")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(message))
            XCTAssertEqual(PreparationURLProtocol.requests.count, 1)
        }
    }

    func testMalformedOrOtherReaderReceiptCannotAuthorizeSkipping() async throws {
        let target = try target()
        for body in [Data("not json".utf8), response(target, id: "9999FFFF"), Data(repeating: 32, count: 513)] {
            let (client, session) = client(body: body)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await client.inspectPreparedContent(target, deviceID: "1234ABCD", host: "reader.test", port: 80)
                XCTFail("Expected invalid receipt")
            } catch {
                XCTAssertEqual(PreparationURLProtocol.requests.count, 1)
            }
        }
    }

    func testInvalidIdentityNeverReachesTransport() async throws {
        let (client, session) = client(body: Data())
        defer { session.invalidateAndCancel() }
        for id in ["", "1234", "1234abcd", "1234ABCZ", "1234ABCD&revision=x"] {
            do {
                _ = try await client.inspectPreparedContent(target(), deviceID: id, host: "reader.test", port: 80)
                XCTFail("Expected invalid identity")
            } catch {
                XCTAssertTrue(PreparationURLProtocol.requests.isEmpty)
            }
        }
    }

    func testStateUsesGETAndExplicitNullMeansNoActive() async throws {
        let body = Data("{\"schema\":1,\"deviceID\":\"1234ABCD\",\"capabilities\":3,\"active\":null}".utf8)
        let (client, session) = client(body: body)
        defer { session.invalidateAndCancel() }
        let state = try await client.contentState(deviceID: "1234ABCD", host: "reader.test", port: 80)
        XCTAssertNil(state.active)
        XCTAssertEqual(state.capabilities, 3)
        let request = try XCTUnwrap(PreparationURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.path, "/api/pocket/v1/content/state")
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.count, 1)
    }

    func testStateRejectsAbsentOrInvalidActiveRecordInsteadOfReturningEmpty() async throws {
        let target = try target()
        for suffix in ["", ",\"active\":{}", ",\"active\":{\"revision\":\"\(target.revision)\",\"generation\":0}",
                       ",\"active\":{\"revision\":\"bad\",\"generation\":1}"] {
            let body = Data("{\"schema\":1,\"deviceID\":\"1234ABCD\",\"capabilities\":3\(suffix)}".utf8)
            let (client, session) = client(body: body)
            defer { session.invalidateAndCancel() }
            do {
                _ = try await client.contentState(deviceID: "1234ABCD", host: "reader.test", port: 80)
                XCTFail("Invalid state must not be converted to no-active")
            } catch {
                XCTAssertEqual(PreparationURLProtocol.requests.count, 1)
            }
        }
    }

    func testActivationPostsOnceAndChecksReturnedSelection() async throws {
        let target = try target()
        let body = Data("{\"schema\":1,\"deviceID\":\"1234ABCD\",\"capabilities\":3,\"active\":{\"revision\":\"\(target.revision)\",\"generation\":2}}".utf8)
        let (client, session) = client(body: body)
        defer { session.invalidateAndCancel() }
        try await client.activateContent(target, deviceID: "1234ABCD", host: "reader.test", port: 80)
        XCTAssertEqual(PreparationURLProtocol.requests.count, 1)
        let request = try XCTUnwrap(PreparationURLProtocol.requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/api/pocket/v1/content/activate")
        let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "revision" })?.value, target.revision)
    }

    func testActivationFailureOrEmptySelectionNeverRetries() async throws {
        let target = try target()
        for status in [200, 503] {
            let body = Data("{\"schema\":1,\"deviceID\":\"1234ABCD\",\"capabilities\":3,\"active\":null}".utf8)
            let (client, session) = client(body: body, status: status)
            defer { session.invalidateAndCancel() }
            do {
                try await client.activateContent(target, deviceID: "1234ABCD", host: "reader.test", port: 80)
                XCTFail("Activation must remain unconfirmed")
            } catch {
                XCTAssertEqual(PreparationURLProtocol.requests.count, 1)
            }
        }
    }

    func testPresentationUsesOnePostThenReadOnlyStatusAndPinsGeneration() async throws {
        let target = try target()
        let active = ContentActiveReceipt(revision: target.revision, generation: 3)
        let body = Data("{\"schema\":1,\"deviceID\":\"1234ABCD\",\"revision\":\"\(target.revision)\",\"generation\":3,\"phase\":\"rendered\"}".utf8)
        let (client, session) = client(body: body)
        defer { session.invalidateAndCancel() }
        let painted = try await client.presentContent(active, deviceID: "1234ABCD", host: "reader.test", port: 8080)
        XCTAssertEqual(painted.phase, .rendered)
        _ = try await client.contentPresentation(active, deviceID: "1234ABCD", host: "reader.test", port: 8080)
        let requests = PreparationURLProtocol.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/pocket/v1/content/present", "/api/pocket/v1/content/presentation"])
        for request in requests {
            let query = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(query.first(where: { $0.name == "deviceID" })?.value, "1234ABCD")
            XCTAssertEqual(query.first(where: { $0.name == "revision" })?.value, active.revision)
        }
        do {
            _ = try await client.contentPresentation(.init(revision: active.revision, generation: 4), deviceID: "1234ABCD", host: "reader.test", port: 8080)
            XCTFail("Stale rendered receipt")
        } catch { XCTAssertEqual(PreparationURLProtocol.requests.count, 3) }
    }
}

private final class PreparationURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var body = Data()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { captured } }
    static func configure(body: Data, status: Int) {
        lock.withLock { self.body = body; self.status = status; captured = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.lock.withLock {
            Self.captured.append(request)
            return (Self.status, Self.body)
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: nil,
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.1)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
