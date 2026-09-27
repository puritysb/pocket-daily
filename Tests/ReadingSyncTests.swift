import XCTest
@testable import Pocket

/// Continuation without a server: iCloud records and reader exchange offer
/// only another device's further position; own and dismissed records are
/// ignored, and only XPointer positions are shared.
@MainActor
final class ReadingSyncTests: XCTestCase {
    private final class Cloud: UbiquitousValues {
        var values: [String: Any] = [:]
        func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
        func set(_ value: Any?, forKey key: String) { values[key] = value }
        func removeObject(forKey key: String) { values[key] = nil }
        var dictionaryRepresentation: [String: Any] { values }
        func synchronize() -> Bool { true }
    }

    private let ownID = String(repeating: "a", count: 32)
    private let digest = String(repeating: "b", count: 32)
    private var cloud: Cloud!
    private var cloudAvailable = true
    private var sync: ReadingSync!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "ReadingSyncTests-\(UUID().uuidString)")
        cloud = Cloud()
        sync = ReadingSync(defaults: defaults, deviceName: "Pocket Daily iPhone", deviceID: ownID,
                           iCloud: ICloudProgressStore(values: cloud), iCloudAvailable: { [unowned self] in cloudAvailable },
                           readerPositions: ReaderPositionStore(defaults: defaults))
    }

    private var book: LibraryBook {
        LibraryBook(id: UUID(), title: "Book", author: "", language: "en", fileName: "book.epub", byteCount: 1,
                    documentDigest: digest, origin: .imported, addedAt: Date(), lastOpenedAt: nil, hasCover: false,
                    position: nil)
    }

    private func local(_ fraction: Double) -> ReadingPosition {
        ReadingPosition(fraction: fraction, xpointer: "/body/DocFragment[2]/body/p/text().0", cfi: nil, chapter: nil,
                        updatedAt: Date())
    }

    private func remote(device: String = "Pocket Daily iPad", deviceID: String = String(repeating: "c", count: 32),
                        percentage: Double, timestamp: Int = 1_800_000_000) {
        cloud.values[ICloudProgressStore.prefix + digest] = [
            "progress": "/body/DocFragment[5]/body/p/text().2", "percentage": percentage,
            "device": device, "device_id": deviceID, "timestamp": timestamp,
        ]
    }

    // MARK: iCloud

    func testICloudCarriesPositionsBetweenAppleDevices() async throws {
        await sync.pushNow(local(0.3), for: book)
        let stored = try XCTUnwrap(cloud.values[ICloudProgressStore.prefix + digest] as? [String: Any])
        XCTAssertEqual(stored["device_id"] as? String, ownID)
        XCTAssertEqual(stored["progress"] as? String, "/body/DocFragment[2]/body/p/text().0")
        let own = await sync.suggestion(for: book, current: local(0.1))
        XCTAssertNil(own, "This device's own record is not offered back")

        remote(percentage: 0.7)
        let fromPad = await sync.suggestion(for: book, current: local(0.3))
        XCTAssertEqual(fromPad?.source, .iCloud)
        XCTAssertEqual(fromPad?.device, "Pocket Daily iPad")
        XCTAssertEqual(fromPad?.position.xpointer, "/body/DocFragment[5]/body/p/text().2")
        sync.iCloudEnabled = false
        let disabled = await sync.suggestion(for: book, current: local(0.3))
        XCTAssertNil(disabled)
    }

    func testOffersOnlyFurtherUndismissedPositions() async {
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
        XCTAssertNotNil(newer, "A new record is offered again")
    }

    func testMissingDeviceIDFallsBackToDeviceName() async {
        remote(device: "Pocket Daily iPhone", deviceID: "", percentage: 0.9)
        let own = await sync.suggestion(for: book, current: local(0.1))
        XCTAssertNil(own)
        remote(device: "Pocket Daily Mac", deviceID: "", percentage: 0.9)
        let other = await sync.suggestion(for: book, current: local(0.1))
        XCTAssertNotNil(other)
    }

    func testSharesOnlyXPointerPositionsAndSkipsWithoutICloud() async {
        var position = local(0.25)
        position.xpointer = nil
        await sync.pushNow(position, for: book)
        XCTAssertNil(cloud.values[ICloudProgressStore.prefix + digest], "Progress alone is never shared")
        cloudAvailable = false
        await sync.pushNow(local(0.25), for: book)
        XCTAssertNil(cloud.values[ICloudProgressStore.prefix + digest], "Nothing is written without iCloud")
    }

    func testICloudRejectsMalformedRecords() {
        let store = ICloudProgressStore(values: cloud)
        cloud.values[ICloudProgressStore.prefix + digest] = ["progress": "bad", "percentage": 0.5, "device": "x"]
        XCTAssertNil(store.record(for: digest))
        cloud.values[ICloudProgressStore.prefix + digest] = ["progress": "/body/DocFragment[1]/body", "percentage": Double.nan, "device": "x"]
        XCTAssertNil(store.record(for: digest))
        XCTAssertNil(store.record(for: "not-a-digest"))
    }

    // MARK: Reader exchange

    func testReaderExchangeStoresReaderPositionsAndOffersFurtherOnes() async throws {
        cloudAvailable = false
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
        XCTAssertEqual(outgoing.first?.device, "Pocket Daily iPhone")

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
}
