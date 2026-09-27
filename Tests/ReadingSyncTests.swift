import XCTest
@testable import Pocket

/// Continuation rules on top of the KOSync client: only another device's
/// further position is offered, own records and dismissed ones are ignored,
/// and only XPointer positions are uploaded.
@MainActor
final class ReadingSyncTests: XCTestCase {
    private final class Settings: KOSyncSettingsStorage {
        var values: [String: Any] = [:]
        func string(forKey key: String) -> String? { values[key] as? String }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
    }

    private final class Secrets: KOSyncSecretStorage {
        var items: [String: String] = [:]
        func secret(forAccount account: String) throws -> String? { items[account] }
        func setSecret(_ secret: String, forAccount account: String) throws { items[account] = secret }
        func removeSecret(forAccount account: String) throws { items[account] = nil }
    }

    private final class Transport: KOSyncTransport, @unchecked Sendable {
        var reply: (URLRequest) -> (Int, String) = { _ in (200, "{}") }
        var requests: [URLRequest] = []
        func koSyncData(for request: URLRequest) async throws -> (Data, URLResponse) {
            requests.append(request)
            let (status, body) = reply(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(body.utf8), response)
        }
    }

    private let ownID = String(repeating: "a", count: 32)
    private let digest = String(repeating: "b", count: 32)
    private var transport: Transport!
    private var sync: ReadingSync!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        transport = Transport()
        defaults = UserDefaults(suiteName: "ReadingSyncTests-\(UUID().uuidString)")
        let store = KOSyncAccountStore(settings: Settings(), secrets: Secrets(), deviceName: "Pocket Daily iPhone",
                                       makeDeviceID: { [ownID] in ownID })
        sync = ReadingSync(store: store, defaults: defaults, transport: transport)
        try await sync.connect(server: "https://sync.example.com", username: "reader", password: "secret", create: false)
        transport.requests = []
    }

    private var book: LibraryBook {
        LibraryBook(id: UUID(), title: "Book", author: "", language: "en", fileName: "book.epub", byteCount: 1,
                    documentDigest: digest, origin: .imported, addedAt: Date(), lastOpenedAt: nil, hasCover: false,
                    position: nil)
    }

    private func remote(device: String = "X3", deviceID: String = "x3", percentage: Double, timestamp: Int = 1_800_000_000) {
        transport.reply = { _ in
            (200, """
            {"document":"\(self.digest)","progress":"/body/DocFragment[4]/body/p[3]/text().12","percentage":\(percentage),
             "device":"\(device)","device_id":"\(deviceID)","timestamp":\(timestamp)}
            """)
        }
    }

    private func local(_ fraction: Double) -> ReadingPosition {
        ReadingPosition(fraction: fraction, xpointer: "/body/DocFragment[2]/body/p/text().0", cfi: nil, chapter: nil,
                        updatedAt: Date())
    }

    func testOffersFurtherPositionFromAnotherDevice() async {
        remote(percentage: 0.43)
        let suggestion = await sync.suggestion(for: book, current: local(0.10))
        XCTAssertEqual(suggestion?.device, "X3")
        XCTAssertEqual(suggestion?.position.fraction ?? 0, 0.43, accuracy: 0.0001)
        XCTAssertEqual(suggestion?.position.xpointer, "/body/DocFragment[4]/body/p[3]/text().12")
        XCTAssertEqual(transport.requests.first?.url?.path, "/syncs/progress/\(digest)")
    }

    func testIgnoresOwnBehindAndDismissedRecords() async {
        remote(deviceID: ownID, percentage: 0.9)
        let own = await sync.suggestion(for: book, current: local(0.1))
        XCTAssertNil(own)
        remote(percentage: 0.3)
        let behind = await sync.suggestion(for: book, current: local(0.5))
        XCTAssertNil(behind)
        remote(percentage: 0.8)
        let offered = await sync.suggestion(for: book, current: local(0.5))
        sync.dismiss(offered!)
        let dismissed = await sync.suggestion(for: book, current: local(0.5))
        XCTAssertNil(dismissed)
        remote(percentage: 0.8, timestamp: 1_800_000_500)
        let newer = await sync.suggestion(for: book, current: local(0.5))
        XCTAssertNotNil(newer, "A new remote record is offered again")
    }

    func testMissingDeviceIDFallsBackToDeviceName() async {
        remote(device: "Pocket Daily iPhone", deviceID: "", percentage: 0.9)
        let own = await sync.suggestion(for: book, current: local(0.1))
        XCTAssertNil(own)
        remote(device: "KOReader", deviceID: "", percentage: 0.9)
        let other = await sync.suggestion(for: book, current: local(0.1))
        XCTAssertNotNil(other)
    }

    func testUploadsOnlyXPointerPositionsAndSkipsRepeats() async throws {
        transport.reply = { _ in (200, #"{"document":"x","timestamp":1}"#) }
        var position = local(0.25)
        position.xpointer = nil
        await sync.pushNow(position, for: book)
        XCTAssertTrue(transport.requests.isEmpty, "A percentage alone is never uploaded")

        await sync.pushNow(local(0.25), for: book)
        XCTAssertEqual(transport.requests.count, 1)
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.httpMethod, "PUT")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["document"] as? String, digest)
        XCTAssertEqual(body["device_id"] as? String, ownID)
        XCTAssertEqual(body["device"] as? String, "Pocket Daily iPhone")

        await sync.pushNow(local(0.25), for: book)
        XCTAssertEqual(transport.requests.count, 1, "An unchanged position is not uploaded twice")
    }

    func testFileNameMatchingUsesFileNameDigest() async {
        sync.matching = .fileName
        XCTAssertEqual(sync.document(for: book), KOReaderDocumentDigest.filenameMD5("book.epub"))
        sync.matching = .binary
        XCTAssertEqual(sync.document(for: book), digest)
    }

    func testFailuresOnlyChangeTheStatusLine() async {
        transport.reply = { _ in (401, "{}") }
        let suggestion = await sync.suggestion(for: book, current: local(0))
        XCTAssertNil(suggestion)
        XCTAssertEqual(sync.statusLine, "Sync needs you to sign in again")
    }
}

final class ReaderSyncSettingsTests: XCTestCase {
    func testAppliedCountParsesCrossPointReply() {
        XCTAssertEqual(CrossPointClient.appliedCount(Data("Applied 4 setting(s)".utf8)), 4)
        XCTAssertEqual(CrossPointClient.appliedCount(Data("Applied 0 setting(s)".utf8)), 0)
        XCTAssertEqual(CrossPointClient.appliedCount(Data("Invalid JSON".utf8)), 0)
        XCTAssertEqual(CrossPointClient.appliedCount(Data(repeating: 65, count: 300)), 0)
    }
}
