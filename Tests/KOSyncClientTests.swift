import XCTest
@testable import Pocket

/// KOReader sync server client: request shape, status mapping, and decoding
/// against the semantics of github.com/koreader/koreader-sync-server.
final class KOSyncClientTests: XCTestCase {
    private let document = "0123456789abcdef0123456789abcdef"
    private let credentials = KOSyncCredentials(username: "reader", password: "password")
    private var client: KOSyncClient!

    override func setUpWithError() throws {
        KOSyncStubProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KOSyncStubProtocol.self]
        client = KOSyncClient(
            server: try KOSyncServer(validating: "https://sync.example.com"),
            transport: URLSession(configuration: configuration)
        )
    }

    override func tearDown() {
        KOSyncStubProtocol.reset()
    }

    private func respond(_ status: Int, _ body: String = "{}") {
        KOSyncStubProtocol.handler = { _ in .response(status, Data(body.utf8)) }
    }

    private func onlyRequest(file: StaticString = #filePath, line: UInt = #line) throws -> KOSyncStubProtocol.Recorded {
        XCTAssertEqual(KOSyncStubProtocol.requests.count, 1, file: file, line: line)
        return try XCTUnwrap(KOSyncStubProtocol.requests.first, file: file, line: line)
    }

    private func assertThrows<T>(
        _ expected: KOSyncError,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let error as KOSyncError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
        }
    }

    private func jsonObject(_ data: Data?) throws -> [String: AnyHashable] {
        let object = try JSONSerialization.jsonObject(with: XCTUnwrap(data))
        return try XCTUnwrap(object as? [String: AnyHashable])
    }

    // MARK: Server and credentials

    func testServerAcceptsHTTPSAndTrimsTrailingSlash() throws {
        XCTAssertEqual(try KOSyncServer(validating: "https://sync.example.com/").baseURL.absoluteString,
                       "https://sync.example.com")
        XCTAssertEqual(try KOSyncServer(validating: " HTTPS://sync.example.com:8443/kosync// ").baseURL.absoluteString,
                       "https://sync.example.com:8443/kosync")
        XCTAssertEqual(KOSyncServer.standard.baseURL.absoluteString, "https://sync.koreader.rocks")
        XCTAssertEqual(try KOSyncServer(baseURL: XCTUnwrap(URL(string: "https://a.example/"))).baseURL.absoluteString,
                       "https://a.example")
    }

    func testServerRejectsInsecureOrAmbiguousAddresses() {
        for text in [
            "http://sync.example.com",
            "https://user:pass@sync.example.com",
            "https://user@sync.example.com",
            "https://sync.example.com/?x=1",
            "https://sync.example.com/#top",
            "sync.example.com",
            "https://",
            "ftp://sync.example.com",
            "",
        ] {
            XCTAssertThrowsError(try KOSyncServer(validating: text), text) { error in
                XCTAssertEqual(error as? KOSyncError, .invalidServerURL, text)
            }
        }
    }

    func testCredentialKeyIsPasswordMD5AndNeverDescribed() {
        XCTAssertEqual(KOSyncCredentials.key(forPassword: "password"), "5f4dcc3b5aa765d61d8327deb882cf99")
        XCTAssertEqual(credentials.key, "5f4dcc3b5aa765d61d8327deb882cf99")
        XCTAssertFalse(String(describing: credentials).contains(credentials.key))
        XCTAssertFalse(String(reflecting: credentials).contains(credentials.key))
    }

    func testUsernameValidation() {
        XCTAssertTrue(KOSyncCredentials.isValidUsername("reader"))
        XCTAssertTrue(KOSyncCredentials.isValidUsername("독자"))
        XCTAssertFalse(KOSyncCredentials.isValidUsername(""))
        XCTAssertFalse(KOSyncCredentials.isValidUsername("user:one"))
        XCTAssertFalse(KOSyncCredentials.isValidUsername("user\none"))
    }

    // MARK: Register

    func testRegisterPostsUsernameAndKey() async throws {
        respond(201, #"{"username":"reader"}"#)
        try await client.register(credentials)
        let request = try onlyRequest()
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, "https://sync.example.com/users/create")
        XCTAssertEqual(request.headers["Accept"], "application/vnd.koreader.v1+json")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertNil(request.headers["x-auth-user"])
        XCTAssertNil(request.headers["x-auth-key"])
        XCTAssertEqual(request.timeout, 15)
        XCTAssertEqual(try jsonObject(request.body), [
            "username": "reader",
            "password": "5f4dcc3b5aa765d61d8327deb882cf99",
        ])
    }

    func testRegisterDistinguishesTakenUsernameFromDisabledRegistration() async {
        respond(402, #"{"code":2002,"message":"Username is already registered."}"#)
        await assertThrows(.usernameTaken) { try await self.client.register(self.credentials) }
        respond(402, #"{"code":2005,"message":"User registration is disabled."}"#)
        await assertThrows(.registrationDisabled) { try await self.client.register(self.credentials) }
        respond(402, "not json")
        await assertThrows(.usernameTaken) { try await self.client.register(self.credentials) }
    }

    func testRegisterRejectsInvalidUsernameWithoutRequest() async {
        await assertThrows(.invalidUsername) {
            try await self.client.register(KOSyncCredentials(username: "a:b", password: "x"))
        }
        XCTAssertTrue(KOSyncStubProtocol.requests.isEmpty)
    }

    // MARK: Authorize

    func testAuthorizeSendsAuthHeaders() async throws {
        respond(200, #"{"authorized":"OK"}"#)
        try await client.authorize(credentials)
        let request = try onlyRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, "https://sync.example.com/users/auth")
        XCTAssertEqual(request.headers["Accept"], "application/vnd.koreader.v1+json")
        XCTAssertEqual(request.headers["x-auth-user"], "reader")
        XCTAssertEqual(request.headers["x-auth-key"], "5f4dcc3b5aa765d61d8327deb882cf99")
        XCTAssertNil(request.headers["Content-Type"])
        XCTAssertNil(request.body)
    }

    func testAuthorizeMapsUnauthorized() async {
        respond(401, #"{"code":2001,"message":"Unauthorized"}"#)
        await assertThrows(.unauthorized) { try await self.client.authorize(self.credentials) }
        XCTAssertEqual(KOSyncError.unauthorized.errorDescription?.contains("Check the username and password"), true)
    }

    func testServerPathPrefixIsKept() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [KOSyncStubProtocol.self]
        let prefixed = KOSyncClient(
            server: try KOSyncServer(validating: "https://example.com/kosync/"),
            transport: URLSession(configuration: configuration)
        )
        respond(200, #"{"authorized":"OK"}"#)
        try await prefixed.authorize(credentials)
        XCTAssertEqual(try onlyRequest().url, "https://example.com/kosync/users/auth")
    }

    // MARK: Fetch

    func testFetchDecodesServerRecord() async throws {
        respond(200, """
        {"percentage":0.5,"progress":"/body/DocFragment[3]/body/p[12]/text().40","device":"X3",\
        "device_id":"abc","timestamp":1727400000,"document":"\(document)"}
        """)
        let progress = try await client.fetchProgress(document: document, credentials: credentials)
        let request = try onlyRequest()
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url, "https://sync.example.com/syncs/progress/\(document)")
        XCTAssertEqual(request.headers["x-auth-user"], "reader")
        XCTAssertEqual(request.headers["x-auth-key"], credentials.key)
        XCTAssertEqual(progress, KOSyncProgress(
            document: document,
            progress: "/body/DocFragment[3]/body/p[12]/text().40",
            percentage: 0.5,
            device: "X3",
            deviceID: "abc",
            timestamp: 1_727_400_000
        ))
    }

    func testFetchEmptyRecordIsNil() async throws {
        respond(200, "{}")
        let progress = try await client.fetchProgress(document: document, credentials: credentials)
        XCTAssertNil(progress)
    }

    func testFetchIncompleteRecordIsNil() async throws {
        respond(200, #"{"percentage":0.5,"device":"X3","document":"\#(document)"}"#)
        let missingPosition = try await client.fetchProgress(document: document, credentials: credentials)
        XCTAssertNil(missingPosition)
        respond(200, #"{"progress":"/body/DocFragment[1]","document":"\#(document)"}"#)
        let missingPercentage = try await client.fetchProgress(document: document, credentials: credentials)
        XCTAssertNil(missingPercentage)
    }

    func testFetchToleratesMissingDeviceIDAndClampsPercentage() async throws {
        respond(200, #"{"percentage":1.2,"progress":"/body/DocFragment[9]","device":"KOReader"}"#)
        let progress = try await client.fetchProgress(document: document, credentials: credentials)
        XCTAssertEqual(progress?.deviceID, "")
        XCTAssertEqual(progress?.percentage, 1)
        XCTAssertNil(progress?.timestamp)
        XCTAssertEqual(progress?.document, document)
    }

    func testFetchRejectsMalformedOrMismatchedResponses() async {
        respond(200, "<html>")
        await assertThrows(.invalidResponse) {
            try await self.client.fetchProgress(document: self.document, credentials: self.credentials)
        }
        respond(200, "[]")
        await assertThrows(.invalidResponse) {
            try await self.client.fetchProgress(document: self.document, credentials: self.credentials)
        }
        respond(200, #"{"percentage":0.5,"progress":"/body","document":"ffffffffffffffffffffffffffffffff"}"#)
        await assertThrows(.invalidResponse) {
            try await self.client.fetchProgress(document: self.document, credentials: self.credentials)
        }
    }

    func testFetchValidatesDocumentBeforeRequest() async {
        for bad in ["", "../users/auth", "0123456789abcdef0123456789abcde", "0123456789abcdef0123456789abcdeg"] {
            await assertThrows(.invalidDocument) {
                try await self.client.fetchProgress(document: bad, credentials: self.credentials)
            }
        }
        XCTAssertTrue(KOSyncStubProtocol.requests.isEmpty)
    }

    // MARK: Update

    func testUpdatePutsProgressBody() async throws {
        respond(200, #"{"document":"\#(document)","timestamp":1727400123}"#)
        let timestamp = try await client.updateProgress(
            KOSyncProgress(
                document: document,
                progress: "/body/DocFragment[3]/body/p[12]/text().40",
                percentage: 0.4312,
                device: "Pocket Daily iPhone",
                deviceID: "fedcba9876543210fedcba9876543210",
                timestamp: 99
            ),
            credentials: credentials
        )
        XCTAssertEqual(timestamp, 1_727_400_123)
        let request = try onlyRequest()
        XCTAssertEqual(request.method, "PUT")
        XCTAssertEqual(request.url, "https://sync.example.com/syncs/progress")
        XCTAssertEqual(request.headers["Accept"], "application/vnd.koreader.v1+json")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["x-auth-user"], "reader")
        XCTAssertEqual(request.headers["x-auth-key"], credentials.key)
        XCTAssertEqual(try jsonObject(request.body), [
            "document": document,
            "progress": "/body/DocFragment[3]/body/p[12]/text().40",
            "percentage": 0.4312,
            "device": "Pocket Daily iPhone",
            "device_id": "fedcba9876543210fedcba9876543210",
        ])
    }

    func testUpdateRejectsInvalidInputWithoutRequest() async {
        let valid = KOSyncProgress(
            document: document, progress: "/body/DocFragment[1]", percentage: 0.1,
            device: "Pocket Daily Mac", deviceID: "id", timestamp: nil
        )
        var badDocument = valid
        badDocument.document = "book.epub"
        await assertThrows(.invalidDocument) {
            try await self.client.updateProgress(badDocument, credentials: self.credentials)
        }
        var badPercentage = valid
        badPercentage.percentage = .nan
        await assertThrows(.invalidProgress) {
            try await self.client.updateProgress(badPercentage, credentials: self.credentials)
        }
        var badPosition = valid
        badPosition.progress = ""
        await assertThrows(.invalidProgress) {
            try await self.client.updateProgress(badPosition, credentials: self.credentials)
        }
        XCTAssertTrue(KOSyncStubProtocol.requests.isEmpty)
    }

    // MARK: Errors

    func testStatusMapping() async {
        let progress = KOSyncProgress(
            document: document, progress: "/body/DocFragment[1]", percentage: 0.1,
            device: "Pocket Daily iPad", deviceID: "id", timestamp: nil
        )
        let cases: [(Int, KOSyncError)] = [
            (401, .unauthorized),
            (402, .registrationDisabled),
            (403, .requestRejected),
            (404, .server(status: 404)),
            (406, .server(status: 406)),
            (500, .server(status: 500)),
            (502, .server(status: 502)),
        ]
        for (status, expected) in cases {
            respond(status, #"{"code":1000,"message":"Cannot connect to redis server."}"#)
            await assertThrows(expected) {
                try await self.client.updateProgress(progress, credentials: self.credentials)
            }
        }
    }

    func testServerErrorMessageDoesNotEchoBody() async {
        respond(500, #"{"message":"internal secret detail"}"#)
        do {
            try await client.authorize(credentials)
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? KOSyncError, .server(status: 500))
            XCTAssertFalse(error.localizedDescription.contains("internal secret detail"))
            XCTAssertTrue(error.localizedDescription.contains("500"))
        }
    }

    func testNetworkErrorMapping() async {
        let cases: [(URLError.Code, KOSyncError)] = [
            (.notConnectedToInternet, .offline),
            (.networkConnectionLost, .offline),
            (.timedOut, .timedOut),
            (.cannotFindHost, .cannotReachServer),
            (.cannotConnectToHost, .cannotReachServer),
            (.serverCertificateUntrusted, .secureConnectionFailed),
            (.secureConnectionFailed, .secureConnectionFailed),
            (.resourceUnavailable, .network),
        ]
        for (code, expected) in cases {
            KOSyncStubProtocol.handler = { _ in .failure(URLError(code)) }
            await assertThrows(expected) { try await self.client.authorize(self.credentials) }
        }
    }

    func testRedirectIsNotFollowed() async {
        KOSyncStubProtocol.handler = { request in
            request.url?.scheme == "http" ? .response(200, Data("{}".utf8)) : .redirect("http://evil.example/users/auth")
        }
        await assertThrows(.server(status: 307)) { try await self.client.authorize(self.credentials) }
        XCTAssertEqual(KOSyncStubProtocol.requests.map(\.url), ["https://sync.example.com/users/auth"])
    }

    func testCancellationIsNotReportedAsSyncError() async {
        KOSyncStubProtocol.handler = { _ in .failure(URLError(.cancelled)) }
        do {
            try await client.authorize(credentials)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
    }

    func testEveryErrorExplainsRecovery() {
        let errors: [KOSyncError] = [
            .invalidServerURL, .invalidDocument, .invalidUsername, .invalidProgress, .unauthorized,
            .usernameTaken, .registrationDisabled, .requestRejected, .server(status: 503),
            .invalidResponse, .offline, .timedOut, .cannotReachServer, .secureConnectionFailed, .network,
        ]
        for error in errors {
            let message = try? XCTUnwrap(error.errorDescription)
            XCTAssertNotNil(message)
            XCTAssertGreaterThanOrEqual(message?.split(separator: ".").count ?? 0, 2, "\(error)")
        }
        XCTAssertTrue(KOSyncError.usernameTaken.errorDescription?.contains("That username is taken") == true)
    }
}

final class KOSyncStubProtocol: URLProtocol, @unchecked Sendable {
    struct Recorded {
        let method: String
        let url: String
        let headers: [String: String]
        let body: Data?
        let timeout: TimeInterval
    }

    enum Reply {
        case response(Int, Data)
        case redirect(String)
        case failure(URLError)
    }

    nonisolated(unsafe) static var handler: (URLRequest) -> Reply = { _ in .response(200, Data("{}".utf8)) }
    nonisolated(unsafe) static var requests: [Recorded] = []

    static func reset() {
        handler = { _ in .response(200, Data("{}".utf8)) }
        requests = []
    }

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(Recorded(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? request.httpBodyStream.map(Self.readAll),
            timeout: request.timeoutInterval
        ))
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        switch Self.handler(request) {
        case let .response(status, data):
            guard let response = HTTPURLResponse(
                url: url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .redirect(location):
            guard let target = URL(string: location),
                  let response = HTTPURLResponse(
                      url: url, statusCode: 307, httpVersion: "HTTP/1.1", headerFields: ["Location": location]
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            var next = request
            next.url = target
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
