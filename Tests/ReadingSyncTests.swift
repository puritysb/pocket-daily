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

    private final class Cloud: UbiquitousValues {
        var values: [String: Any] = [:]
        func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
        var dictionaryRepresentation: [String: Any] { values }
        func synchronize() -> Bool { true }
    }

    private let ownID = String(repeating: "a", count: 32)
    private var cloud: Cloud!
    private var cloudAvailable = false
    private let digest = String(repeating: "b", count: 32)
    private var transport: Transport!
    private var sync: ReadingSync!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        transport = Transport()
        defaults = UserDefaults(suiteName: "ReadingSyncTests-\(UUID().uuidString)")
        let store = KOSyncAccountStore(settings: Settings(), secrets: Secrets(), deviceName: "Pocket Daily iPhone",
                                       makeDeviceID: { [ownID] in ownID })
        cloud = Cloud()
        sync = ReadingSync(store: store, defaults: defaults, transport: transport,
                           iCloud: ICloudProgressStore(values: cloud), iCloudAvailable: { [unowned self] in cloudAvailable },
                           readerPositions: ReaderPositionStore(defaults: defaults))
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
        XCTAssertEqual(sync.statusLine, "Server sync needs you to sign in again")
        transport.reply = { _ in (522, "error code: 522") }
        _ = await sync.suggestion(for: book, current: local(0))
        XCTAssertEqual(sync.statusLine, "The sync server is not responding; positions will sync later")
    }

    // MARK: Serverless channels

    func testICloudCarriesPositionsBetweenAppleDevices() async throws {
        try sync.disconnect()
        cloudAvailable = true
        transport.requests = []
        await sync.pushNow(local(0.3), for: book)
        XCTAssertTrue(transport.requests.isEmpty, "Without an account nothing reaches a server")
        let stored = try XCTUnwrap(cloud.values[ICloudProgressStore.prefix + digest] as? [String: Any])
        XCTAssertEqual(stored["device_id"] as? String, ownID)
        let own = await sync.suggestion(for: book, current: local(0.1))
        XCTAssertNil(own, "This device's own iCloud record is not offered back")

        cloud.values[ICloudProgressStore.prefix + digest] = [
            "progress": "/body/DocFragment[5]/body/p/text().2", "percentage": 0.7,
            "device": "Pocket Daily iPad", "device_id": String(repeating: "c", count: 32), "timestamp": 1_800_000_000,
        ]
        let fromPad = await sync.suggestion(for: book, current: local(0.3))
        XCTAssertEqual(fromPad?.source, .iCloud)
        XCTAssertEqual(fromPad?.device, "Pocket Daily iPad")
        sync.iCloudEnabled = false
        let disabled = await sync.suggestion(for: book, current: local(0.3))
        XCTAssertNil(disabled)
    }

    func testICloudRejectsMalformedRecords() {
        let store = ICloudProgressStore(values: cloud)
        cloud.values[ICloudProgressStore.prefix + digest] = ["progress": "bad", "percentage": 0.5, "device": "x"]
        XCTAssertNil(store.record(for: digest))
        cloud.values[ICloudProgressStore.prefix + digest] = ["progress": "/body/DocFragment[1]/body", "percentage": Double.nan, "device": "x"]
        XCTAssertNil(store.record(for: digest))
        XCTAssertNil(store.record(for: "not-a-digest"))
    }

    func testReaderExchangeStoresReaderPositionsAndOffersFurtherOnes() async throws {
        try sync.disconnect()
        var ahead = book
        ahead.position = local(0.8)
        var behindBook = book
        behindBook.documentDigest = String(repeating: "d", count: 32)
        behindBook.position = local(0.1)
        let json = """
        {"v":1,"deviceID":"X3-1","books":[
          {"path":"/Books/a.epub","document":"\(digest)","progress":"/body/DocFragment[2]/body/p[4]/text().0","percentage":0.5,"updated":0,"seq":3},
          {"path":"/Books/b.epub","document":"\(behindBook.documentDigest)","progress":"/body/DocFragment[9]/body/p/text().1","percentage":0.6,"updated":0,"seq":4},
          {"path":"/Books/c.epub","document":"zz","progress":null,"percentage":0.2}
        ]}
        """
        let list = try ReaderReadingList.decode(Data(json.utf8), deviceID: "X3-1")
        XCTAssertEqual(list.books.count, 2, "Malformed entries are dropped")
        let outgoing = sync.exchange(with: list, readerName: "X3", library: [ahead, behindBook])
        XCTAssertEqual(outgoing.map(\.document), [digest], "Only books further along here are offered to the reader")
        XCTAssertEqual(outgoing.first?.percentage ?? 0, 0.8, accuracy: 0.0001)

        let suggestion = await sync.suggestion(for: behindBook, current: behindBook.position)
        XCTAssertEqual(suggestion?.source, .reader("X3"))
        XCTAssertEqual(suggestion?.position.xpointer, "/body/DocFragment[9]/body/p/text().1")
        sync.dismiss(suggestion!)
        _ = sync.exchange(with: list, readerName: "X3", library: [ahead, behindBook])
        let again = await sync.suggestion(for: behindBook, current: behindBook.position)
        XCTAssertNil(again, "A dismissed reader position stays dismissed across exchanges")

        sync.readerExchangeEnabled = false
        XCTAssertTrue(sync.exchange(with: list, readerName: "X3", library: [ahead]).isEmpty)
    }

    func testReaderListAcceptsFirmwareShapes() throws {
        let json = """
        {"v":1,"deviceID":"X3-1","books":[
          {"path":"/Books/a.epub","document":"\(digest.uppercased())","filenameDocument":"","progress":null,"percentage":0.25,"updated":0,"seq":1},
          {"path":"/Books/b.epub","document":"\(digest)","filenameDocument":"","progress":"/body/DocFragment[2]/body/p[3]","percentage":0.5,"updated":0,"seq":2}
        ]}
        """
        let list = try ReaderReadingList.decode(Data(json.utf8), deviceID: "X3-1")
        XCTAssertEqual(list.books.map(\.document), [digest, digest], "Upper-case digests are normalized")
        XCTAssertNil(list.books[0].progress)
        XCTAssertEqual(list.books[1].progress, "/body/DocFragment[2]/body/p[3]", "Element-only positions are kept")
    }

    func testReaderListRejectsOtherReadersAndOversizedReplies() {
        let json = #"{"v":1,"deviceID":"other","books":[]}"#
        XCTAssertThrowsError(try ReaderReadingList.decode(Data(json.utf8), deviceID: "X3-1"))
        XCTAssertThrowsError(try ReaderReadingList.decode(Data(repeating: 32, count: 9000), deviceID: "X3-1"))
    }

    func testServerHealthExplainsPublicOutage() async {
        transport.reply = { request in request.url?.path == "/healthcheck" ? (200, #"{"state":"OK"}"#) : (404, "") }
        await sync.checkServer("https://sync.example.com")
        XCTAssertEqual(sync.serverHealth, .available)
        transport.reply = { _ in (522, "error code: 522") }
        await sync.checkServer(KOSyncServer.standard.baseURL.absoluteString)
        guard case .unavailable(let message) = sync.serverHealth else { return XCTFail("Expected an outage") }
        XCTAssertTrue(message.contains("public KOReader sync server is not responding"))
        await sync.checkServer("http://insecure.example.com")
        guard case .unavailable = sync.serverHealth else { return XCTFail("Plain HTTP is rejected") }
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
