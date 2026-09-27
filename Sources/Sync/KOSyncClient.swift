import Foundation

/// A KOReader sync (kosync) server. Only HTTPS is accepted because every
/// request carries the account key.
struct KOSyncServer: Equatable, Sendable {
    static let standard = KOSyncServer(checkedBaseURL: URL(string: "https://sync.koreader.rocks")!)

    let baseURL: URL

    init(baseURL: URL) throws {
        try self.init(validating: baseURL.absoluteString)
    }

    init(validating text: String) throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil
        else {
            throw KOSyncError.invalidServerURL
        }
        components.scheme = "https"
        var path = components.percentEncodedPath
        while path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path
        guard let url = components.url else {
            throw KOSyncError.invalidServerURL
        }
        baseURL = url
    }

    private init(checkedBaseURL: URL) {
        baseURL = checkedBaseURL
    }

    func endpoint(_ path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw KOSyncError.invalidServerURL
        }
        components.percentEncodedPath += path
        guard let url = components.url else {
            throw KOSyncError.invalidServerURL
        }
        return url
    }
}

struct KOSyncCredentials: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    var username: String
    /// MD5 hex of the password, as KOReader sends it. Never log it.
    var key: String

    init(username: String, key: String) {
        self.username = username
        self.key = key
    }

    init(username: String, password: String) {
        self.init(username: username, key: Self.key(forPassword: password))
    }

    static func key(forPassword password: String) -> String {
        KOReaderDocumentDigest.md5Hex(Data(password.utf8))
    }

    /// The server keys Redis entries by username, so it rejects empty names
    /// and colons; control characters cannot travel in an HTTP header.
    static func isValidUsername(_ username: String) -> Bool {
        !username.isEmpty
            && !username.contains(":")
            && !username.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    var description: String { "KOSyncCredentials(username: \(username), key: <redacted>)" }
    var debugDescription: String { description }
}

struct KOSyncProgress: Codable, Equatable, Sendable {
    var document: String
    /// KOReader XPointer, for example `/body/DocFragment[3]/body/p[12]/text().40`.
    var progress: String
    /// Whole-book progress from 0 to 1.
    var percentage: Double
    var device: String
    var deviceID: String
    /// Server time of the last update, in Unix seconds. Set only by the server.
    var timestamp: Int?

    enum CodingKeys: String, CodingKey {
        case document, progress, percentage, device
        case deviceID = "device_id"
        case timestamp
    }
}

enum KOSyncError: LocalizedError, Equatable {
    case invalidServerURL
    case invalidDocument
    case invalidUsername
    case invalidProgress
    case unauthorized
    case usernameTaken
    case registrationDisabled
    case requestRejected
    case server(status: Int)
    case invalidResponse
    case offline
    case timedOut
    case cannotReachServer
    case secureConnectionFailed
    case network

    var errorDescription: String? {
        switch self {
        case .invalidServerURL:
            "The sync server address is not valid. Enter an https:// address without a username, query, or fragment."
        case .invalidDocument:
            "This book has no valid sync identifier, so its progress cannot be synced. Reopen the book and try again."
        case .invalidUsername:
            "That username cannot be used for sync. Use a name without colons or control characters."
        case .invalidProgress:
            "The reading position could not be prepared for sync. Turn a page and try again."
        case .unauthorized:
            "The sync server did not accept this account. Check the username and password."
        case .usernameTaken:
            "That username is taken on this sync server. Choose another username, or sign in if it is yours."
        case .registrationDisabled:
            "This sync server does not allow new accounts. Sign in with an existing account or use another server."
        case .requestRejected:
            "The sync server rejected the request. Check the account details and try again."
        case let .server(status):
            "The sync server returned an error (HTTP \(status)). Check the server address or try again later."
        case .invalidResponse:
            "The sync server sent a response Pocket Daily could not read. Check that the address points to a KOReader sync server."
        case .offline:
            "You appear to be offline. Reading continues, and progress will sync when you reconnect."
        case .timedOut:
            "The sync server took too long to respond. Try again later."
        case .cannotReachServer:
            "Pocket Daily could not reach the sync server. Check the server address and your connection."
        case .secureConnectionFailed:
            "A secure connection to the sync server could not be established. Check the server address and its certificate."
        case .network:
            "The sync request failed because of a network error. Try again later."
        }
    }
}

/// The transport the client sends requests through, injectable for tests.
protocol KOSyncTransport: Sendable {
    func koSyncData(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: KOSyncTransport {
    func koSyncData(for request: URLRequest) async throws -> (Data, URLResponse) {
        // A redirect could carry the account key to another origin or to
        // plain HTTP, so redirects surface as errors instead.
        try await data(for: request, delegate: KOSyncRedirectRefusal())
    }
}

private final class KOSyncRedirectRefusal: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

/// Client for the KOReader sync server API
/// (https://github.com/koreader/koreader-sync-server).
final class KOSyncClient: Sendable {
    static let acceptHeader = "application/vnd.koreader.v1+json"
    static let requestTimeout: TimeInterval = 15

    let server: KOSyncServer
    private let transport: any KOSyncTransport

    init(server: KOSyncServer = .standard, transport: any KOSyncTransport = URLSession.shared) {
        self.server = server
        self.transport = transport
    }

    /// Creates an account. The server stores the key, never the password.
    func register(_ credentials: KOSyncCredentials) async throws {
        try Self.validate(credentials)
        let body = try Self.encode(RegisterBody(username: credentials.username, password: credentials.key))
        let request = try makeRequest(path: "/users/create", method: "POST", credentials: nil, body: body)
        let (data, status) = try await send(request)
        if status == 402 {
            // 402 means either a taken username (code 2002) or a server with
            // registration turned off (code 2005).
            let code = (try? JSONDecoder().decode(ErrorReply.self, from: data))?.code
            throw code == Self.registrationDisabledCode ? KOSyncError.registrationDisabled : KOSyncError.usernameTaken
        }
        try Self.check(status)
    }

    func authorize(_ credentials: KOSyncCredentials) async throws {
        try Self.validate(credentials)
        let request = try makeRequest(path: "/users/auth", method: "GET", credentials: credentials, body: nil)
        let (_, status) = try await send(request)
        try Self.check(status)
    }

    /// Returns nil when the server has no usable record for the document.
    func fetchProgress(document: String, credentials: KOSyncCredentials) async throws -> KOSyncProgress? {
        guard KOReaderDocumentDigest.isDigest(document) else {
            throw KOSyncError.invalidDocument
        }
        try Self.validate(credentials)
        let request = try makeRequest(
            path: "/syncs/progress/\(document)", method: "GET", credentials: credentials, body: nil
        )
        let (data, status) = try await send(request)
        try Self.check(status)
        return try Self.decodeProgress(data, document: document)
    }

    /// Uploads a position. Returns the server timestamp when it reports one.
    @discardableResult
    func updateProgress(_ progress: KOSyncProgress, credentials: KOSyncCredentials) async throws -> Int? {
        guard KOReaderDocumentDigest.isDigest(progress.document) else {
            throw KOSyncError.invalidDocument
        }
        guard progress.percentage.isFinite, !progress.progress.isEmpty, !progress.device.isEmpty else {
            throw KOSyncError.invalidProgress
        }
        try Self.validate(credentials)
        let body = try Self.encode(UpdateBody(
            document: progress.document,
            progress: progress.progress,
            percentage: progress.percentage,
            device: progress.device,
            deviceID: progress.deviceID
        ))
        let request = try makeRequest(path: "/syncs/progress", method: "PUT", credentials: credentials, body: body)
        let (data, status) = try await send(request)
        try Self.check(status)
        return (try? JSONDecoder().decode(UpdateReply.self, from: data))?.timestamp
    }

    // MARK: Requests

    private func makeRequest(
        path: String,
        method: String,
        credentials: KOSyncCredentials?,
        body: Data?
    ) throws -> URLRequest {
        var request = URLRequest(
            url: try server.endpoint(path),
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: Self.requestTimeout
        )
        request.httpMethod = method
        request.setValue(Self.acceptHeader, forHTTPHeaderField: "Accept")
        if let credentials {
            request.setValue(credentials.username, forHTTPHeaderField: "x-auth-user")
            request.setValue(credentials.key, forHTTPHeaderField: "x-auth-key")
        }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
        }
        return request
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport.koSyncData(for: request)
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CancellationError()
            }
            throw Self.map(error)
        }
        guard let http = response as? HTTPURLResponse else {
            throw KOSyncError.invalidResponse
        }
        return (data, http.statusCode)
    }

    private static func check(_ status: Int) throws {
        switch status {
        case 200 ..< 300:
            return
        case 401:
            throw KOSyncError.unauthorized
        case 402:
            throw KOSyncError.registrationDisabled
        case 403:
            throw KOSyncError.requestRejected
        default:
            throw KOSyncError.server(status: status)
        }
    }

    private static func validate(_ credentials: KOSyncCredentials) throws {
        guard KOSyncCredentials.isValidUsername(credentials.username) else {
            throw KOSyncError.invalidUsername
        }
        guard KOReaderDocumentDigest.isDigest(credentials.key) else {
            throw KOSyncError.unauthorized
        }
    }

    private static func map(_ error: URLError) -> KOSyncError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
            return .offline
        case .timedOut:
            return .timedOut
        case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
            return .cannotReachServer
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
             .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .secureConnectionFailed
        case .badServerResponse, .cannotParseResponse, .cannotDecodeRawData, .cannotDecodeContentData:
            return .invalidResponse
        default:
            return .network
        }
    }

    // MARK: Payloads

    private struct RegisterBody: Encodable {
        let username: String
        let password: String
    }

    private struct UpdateBody: Encodable {
        let document: String
        let progress: String
        let percentage: Double
        let device: String
        let deviceID: String

        enum CodingKeys: String, CodingKey {
            case document, progress, percentage, device
            case deviceID = "device_id"
        }
    }

    private static let registrationDisabledCode = 2005

    private struct ErrorReply: Decodable {
        let code: Int?
    }

    private struct UpdateReply: Decodable {
        let timestamp: Int?
    }

    /// Every field optional: the server omits fields it never stored and
    /// answers `{}` for an unknown document.
    private struct RemoteProgress: Decodable {
        let document: String?
        let progress: String?
        let percentage: Double?
        let device: String?
        let deviceID: String?
        let timestamp: Int?

        enum CodingKeys: String, CodingKey {
            case document, progress, percentage, device
            case deviceID = "device_id"
            case timestamp
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            document = try? container.decodeIfPresent(String.self, forKey: .document)
            progress = try? container.decodeIfPresent(String.self, forKey: .progress)
            if let number = try? container.decodeIfPresent(Double.self, forKey: .percentage) {
                percentage = number
            } else if let text = try? container.decodeIfPresent(String.self, forKey: .percentage) {
                percentage = Double(text)
            } else {
                percentage = nil
            }
            device = try? container.decodeIfPresent(String.self, forKey: .device)
            deviceID = try? container.decodeIfPresent(String.self, forKey: .deviceID)
            if let whole = try? container.decodeIfPresent(Int.self, forKey: .timestamp) {
                timestamp = whole
            } else if let seconds = try? container.decodeIfPresent(Double.self, forKey: .timestamp),
                      seconds.isFinite, abs(seconds) < 1e15 {
                timestamp = Int(seconds)
            } else {
                timestamp = nil
            }
        }
    }

    static func decodeProgress(_ data: Data, document: String) throws -> KOSyncProgress? {
        let remote: RemoteProgress
        do {
            remote = try JSONDecoder().decode(RemoteProgress.self, from: data)
        } catch {
            throw KOSyncError.invalidResponse
        }
        if let echoed = remote.document, echoed.lowercased() != document.lowercased() {
            throw KOSyncError.invalidResponse
        }
        guard let progress = remote.progress, !progress.isEmpty,
              let percentage = remote.percentage, percentage.isFinite
        else {
            return nil
        }
        return KOSyncProgress(
            document: document,
            progress: progress,
            percentage: min(max(percentage, 0), 1),
            device: remote.device ?? "",
            deviceID: remote.deviceID ?? "",
            timestamp: remote.timestamp
        )
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(value)
        } catch {
            throw KOSyncError.invalidProgress
        }
    }
}
