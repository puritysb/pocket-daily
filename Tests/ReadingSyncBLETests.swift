import XCTest
@testable import Pocket

/// Reading Sync over BLE v1: record formats, list reassembly, offer chunking,
/// and the background link's state machine driven without hardware.
final class ReadingSyncBLEProtocolTests: XCTestCase {
    private let id = "0A1B2C3D"

    func testCommandsAreBoundedRecords() throws {
        XCTAssertEqual(ReadingSyncBLE.readList(requestID: id), Data("READ_LIST 0A1B2C3D".utf8))
        XCTAssertNil(ReadingSyncBLE.readList(requestID: "0a1b2c3d"), "Request IDs are uppercase hex")
        XCTAssertNil(ReadingSyncBLE.readList(requestID: "0A1B2C3"))
        XCTAssertEqual(ReadingSyncBLE.offer(requestID: id, total: 300, crc: 0xAB), Data("OFFER 0A1B2C3D 300 000000AB".utf8))
        XCTAssertNil(ReadingSyncBLE.offer(requestID: id, total: 1025, crc: 0), "Offers are at most 1024 bytes")
        XCTAssertNil(ReadingSyncBLE.offer(requestID: id, total: 0, crc: 0))
        XCTAssertEqual(ReadingSyncBLE.write(requestID: id, seq: 2, chunk: Data("a b".utf8)), Data("W 0A1B2C3D 2 a b".utf8))
        XCTAssertNil(ReadingSyncBLE.write(requestID: id, seq: 0, chunk: Data(repeating: 0x41, count: 181)))
        XCTAssertNil(ReadingSyncBLE.write(requestID: id, seq: 0, chunk: Data("a\nb".utf8)))
        XCTAssertNil(ReadingSyncBLE.write(requestID: id, seq: -1, chunk: Data("a".utf8)))
        let longest = try XCTUnwrap(ReadingSyncBLE.write(requestID: id, seq: 9999, chunk: Data(repeating: 0x41, count: 180)))
        XCTAssertLessThanOrEqual(longest.count, NearbySyncProtocol.maximumRecordBytes)
    }

    func testEventsParseAndMalformedRecordsAreRejected() throws {
        XCTAssertEqual(try ReadingSyncBLE.parseEvent(Data("D 0A1B2C3D 7 {\"a\": 1, \"b\"".utf8)),
                       .data(id: id, seq: 7, chunk: Data("{\"a\": 1, \"b\"".utf8)), "A chunk keeps its spaces")
        XCTAssertEqual(try ReadingSyncBLE.parseEvent(Data("D 0A1B2C3D 0  leading".utf8)),
                       .data(id: id, seq: 0, chunk: Data(" leading".utf8)), "Only one space separates fields")
        XCTAssertEqual(try ReadingSyncBLE.parseEvent(Data("END 0A1B2C3D 412 cbf43926".utf8)),
                       .end(id: id, total: 412, crc: 0xCBF4_3926))
        XCTAssertEqual(try ReadingSyncBLE.parseEvent(Data("END 0A1B2C3D 412 CBF43926".utf8)),
                       .end(id: id, total: 412, crc: 0xCBF4_3926))
        XCTAssertEqual(try ReadingSyncBLE.parseEvent(Data("OK 0A1B2C3D".utf8)), .ok(id: id))
        XCTAssertEqual(try ReadingSyncBLE.parseEvent(Data("ERR 0A1B2C3D UNKNOWN_DOCUMENT".utf8)),
                       .error(id: id, code: "UNKNOWN_DOCUMENT"))
        XCTAssertNil(try ReadingSyncBLE.parseEvent(Data("AP 0A1B2C3D Pocket-1 ABCDEF123456 192.168.4.1 80 0 600".utf8)),
                     "Other Nearby Sync events are not reading-sync records")

        let malformed = [
            "D 0A1B2C3D 1", "D 0A1B2C3D 1 ", "D 0a1b2c3d 1 x", "D 0A1B2C3D -1 x", "D 0A1B2C3D 01 x", "D 0A1B2C3D x x",
            "D 0A1B2C3D 1 " + String(repeating: "x", count: 181), "END 0A1B2C3D 12", "END 0A1B2C3D 12 CBF4392",
            "END 0A1B2C3D 12 CBF4392G", "END 0A1B2C3D 99999 CBF43926", "OK 0A1B2C3D extra", "OK", "ERR 0A1B2C3D",
            "ERR 0A1B2C3D bad code", "D 0A1B2C3D 1 a\nb",
        ]
        for record in malformed {
            XCTAssertThrowsError(try ReadingSyncBLE.parseEvent(Data(record.utf8)), record)
        }
        XCTAssertThrowsError(try ReadingSyncBLE.parseEvent(Data(repeating: 0x44, count: 221)))
    }

    func testCRC32MatchesIEEE() {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    func testStatusCarriesReadingCapabilityAndWindow() throws {
        let status = try PocketDeviceStatus(record: "V=1;MODEL=X3;ID=89ABCDEF;FW=1.7.1;CAP=AP,HTTP,SD,COMMIT1,READ1;WIN=1")
        XCTAssertTrue(status.capabilities.contains(ReadingSyncBLE.capability))
        XCTAssertEqual(status.exchangeWindow, true)
        XCTAssertEqual(try PocketDeviceStatus(record: "V=1;MODEL=X4;ID=1;CAP=AP;WIN=0").exchangeWindow, false)
        let legacy = try PocketDeviceStatus(record: "V=1;MODEL=X3;ID=89ABCDEF;FW=1.4.1;CAP=AP,HTTP,SD,COMMIT1")
        XCTAssertNil(legacy.exchangeWindow)
        XCTAssertFalse(legacy.capabilities.contains(ReadingSyncBLE.capability))
    }

    func testListReassemblesOutOfOrderAndRejectsGapsConflictsAndChecksums() throws {
        let body = Data(#"{"v":1,"deviceID":"89ABCDEF","books":[]}"#.utf8)
        let parts = ReadingSyncBLE.chunks(body, limit: 10)
        var assembler = ReadingListAssembler(requestID: id)
        for (seq, chunk) in parts.enumerated().reversed() { try assembler.add(seq: seq, chunk: chunk) }
        try assembler.add(seq: 1, chunk: parts[1])
        XCTAssertEqual(try assembler.finish(total: body.count, crc: CRC32.checksum(body)), body,
                       "Out of order and repeated chunks reassemble")
        XCTAssertThrowsError(try assembler.finish(total: body.count + 1, crc: CRC32.checksum(body)))
        XCTAssertThrowsError(try assembler.finish(total: body.count, crc: CRC32.checksum(body) ^ 1))
        XCTAssertThrowsError(try assembler.add(seq: 0, chunk: Data("different".utf8)), "A conflicting chunk")

        var gap = ReadingListAssembler(requestID: id)
        for (seq, chunk) in parts.enumerated() where seq != 2 { try gap.add(seq: seq, chunk: chunk) }
        XCTAssertThrowsError(try gap.finish(total: body.count, crc: CRC32.checksum(body)), "A missing chunk")

        var huge = ReadingListAssembler(requestID: id)
        let chunk = Data(repeating: 0x20, count: 180)
        XCTAssertThrowsError(try (0...46).forEach { try huge.add(seq: $0, chunk: chunk) }, "More than 8 KiB")
    }

    func testOffersSplitIntoBoundedRecordsOnCharacterBoundaries() throws {
        let body = Data((#"{"device":""# + String(repeating: "가나다", count: 90) + #""}"#).utf8)
        XCTAssertLessThanOrEqual(body.count, ReadingSyncBLE.maximumOfferBytes)
        let records = try XCTUnwrap(ReadingSyncBLE.offerRecords(requestID: id, body: body))
        XCTAssertEqual(records.first, Data("OFFER \(id) \(body.count) \(ReadingSyncBLE.hex(CRC32.checksum(body)))".utf8))
        var rebuilt = Data()
        for (seq, record) in records.dropFirst().enumerated() {
            XCTAssertLessThanOrEqual(record.count, NearbySyncProtocol.maximumRecordBytes)
            XCTAssertNotNil(String(data: record, encoding: .utf8), "Every record is valid UTF-8")
            let prefix = Data("W \(id) \(seq) ".utf8)
            XCTAssertEqual(record.prefix(prefix.count), prefix)
            let chunk = record.dropFirst(prefix.count)
            XCTAssertLessThanOrEqual(chunk.count, ReadingSyncBLE.maximumChunkBytes)
            rebuilt.append(chunk)
        }
        XCTAssertEqual(rebuilt, body)
        XCTAssertNil(ReadingSyncBLE.offerRecords(requestID: id, body: Data(repeating: 0x41, count: 1025)))
        XCTAssertNil(ReadingSyncBLE.offerRecords(requestID: id, body: Data()))
    }

    func testOfferBodyIsTheHTTPBody() throws {
        let record = PositionRecord(document: String(repeating: "b", count: 32), progress: "/body/DocFragment[2]/body/p/text().0",
                                    percentage: 0.5, device: "Pocket Daily iPhone", deviceID: "x", timestamp: nil)
        let body = try CrossPointClient.readingOfferBody(record, identity: "89ABCDEF")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["deviceID"] as? String, "89ABCDEF")
        XCTAssertEqual(object["document"] as? String, record.document)
        XCTAssertEqual(object["progress"] as? String, record.progress)
        XCTAssertEqual(object["percentage"] as? Double, 0.5)
        XCTAssertEqual(object["device"] as? String, "Pocket Daily iPhone")
        XCTAssertEqual(object.count, 5)
        XCTAssertFalse(body.contains(0x0A))
    }

    func testReadingListWithoutPathsDecodes() throws {
        let digest = String(repeating: "b", count: 32)
        let json = #"{"v":1,"deviceID":"89ABCDEF","books":[{"document":"\#(digest)","filenameDocument":"","progress":"/body/DocFragment[2]/body/p[3]","percentage":0.5,"updated":0,"seq":2}]}"#
        let list = try ReaderReadingList.decode(Data(json.utf8), deviceID: "89ABCDEF")
        XCTAssertEqual(list.books.count, 1)
        XCTAssertNil(list.books[0].path)
    }
}

@MainActor
final class ReaderBluetoothLinkTests: XCTestCase {
    final class FakeTransport: ReaderLinkTransport {
        var onEvent: ((ReaderLinkTransportEvent) -> Void)?
        var isAvailable = true
        var known: Set<UUID> = []
        var connectedOnRequest = false
        private(set) var activations = 0
        private(set) var connects: [UUID] = []
        private(set) var cancels = 0
        private(set) var prepares = 0
        private(set) var writes: [Data] = []

        func activate() { activations += 1 }
        func connect(to peripheral: UUID) -> Bool {
            connects.append(peripheral)
            guard known.contains(peripheral) else { return false }
            if connectedOnRequest { onEvent?(.connected(peripheral)) }
            return true
        }
        func cancelConnection() { cancels += 1 }
        func prepareSession() { prepares += 1 }
        func write(_ record: Data) { writes.append(record) }
        func send(_ event: ReaderLinkTransportEvent) { onEvent?(event) }
    }

    final class ManualScheduler: ReaderLinkScheduling {
        final class Timer: ReaderLinkTimer {
            let seconds: TimeInterval
            let keepAwake: Bool
            var action: (@MainActor () -> Void)?
            init(seconds: TimeInterval, keepAwake: Bool, action: @escaping @MainActor () -> Void) {
                self.seconds = seconds
                self.keepAwake = keepAwake
                self.action = action
            }
            func cancel() { action = nil }
        }
        private(set) var timers: [Timer] = []
        func schedule(after seconds: TimeInterval, keepAwake: Bool,
                      _ action: @escaping @MainActor () -> Void) -> ReaderLinkTimer {
            let timer = Timer(seconds: seconds, keepAwake: keepAwake, action: action)
            timers.append(timer)
            return timer
        }
        var pending: [Timer] { timers.filter { $0.action != nil } }
        /// Fires the pending timers scheduled for exactly `seconds`.
        func fire(_ seconds: TimeInterval) {
            for timer in pending where timer.seconds == seconds {
                let action = timer.action
                timer.action = nil
                action?()
            }
        }
    }

    private let peripheral = UUID()
    private let readerID = "89ABCDEF"
    private let digest = String(repeating: "b", count: 32)
    private let otherDigest = String(repeating: "d", count: 32)
    private var defaults: UserDefaults!
    private var sync: ReadingSync!
    private var transport: FakeTransport!
    private var scheduler: ManualScheduler!
    private var library: [LibraryBook] = []
    private var libraryLoads = 0
    /// Distinct values so each timer can be fired on its own.
    private let timing = ReaderBluetoothLink.Timing(prepare: 1, step: 2, session: 3, cooldown: 4)

    override func setUp() async throws {
        defaults = UserDefaults(suiteName: "ReaderBluetoothLinkTests-\(UUID().uuidString)")
        sync = ReadingSync(defaults: defaults, deviceName: "Pocket Daily iPhone", deviceID: String(repeating: "a", count: 32),
                           iCloud: ICloudProgressStore(values: NoCloud()), iCloudAvailable: { false },
                           readerPositions: ReaderPositionStore(defaults: defaults))
        transport = FakeTransport()
        transport.known = [peripheral]
        scheduler = ManualScheduler()
        library = [book(digest, fraction: 0.8), book(otherDigest, fraction: 0.1)]
        libraryLoads = 0
    }

    private final class NoCloud: UbiquitousValues {
        func dictionary(forKey key: String) -> [String: Any]? { nil }
        func set(_ value: Any?, forKey key: String) {}
        func removeObject(forKey key: String) {}
        var dictionaryRepresentation: [String: Any] { [:] }
        func synchronize() -> Bool { true }
    }

    private func book(_ digest: String, fraction: Double) -> LibraryBook {
        LibraryBook(id: UUID(), title: "Book", author: "", language: "en", fileName: "book.epub", byteCount: 1,
                    documentDigest: digest, origin: .imported, addedAt: Date(), lastOpenedAt: nil, hasCover: false,
                    position: ReadingPosition(fraction: fraction, xpointer: "/body/DocFragment[4]/body/p/text().0",
                                              cfi: nil, chapter: nil, updatedAt: Date()))
    }

    private func makeLink(remember: Bool = true) -> ReaderBluetoothLink {
        let store = RememberedBluetoothReaderStore(defaults: defaults)
        if remember { store.reader = RememberedBluetoothReader(peripheralID: peripheral, readerID: readerID, model: "X3") }
        return ReaderBluetoothLink(transport: transport, store: store, sync: sync,
                                   books: { [unowned self] in libraryLoads += 1; return library },
                                   scheduler: scheduler, timing: timing)
    }

    private func status(id: String? = nil, capabilities: String = "AP,HTTP,SD,COMMIT1,READ1") -> Data {
        Data("V=1;MODEL=X3;ID=\(id ?? readerID);FW=1.7.1;CAP=\(capabilities);WIN=1".utf8)
    }

    private var listJSON: Data {
        Data(#"{"v":1,"deviceID":"89ABCDEF","books":[{"document":"\#(digest)","filenameDocument":"","progress":"/body/DocFragment[2]/body/p[4]/text().0","percentage":0.5,"updated":0,"seq":3},{"document":"\#(otherDigest)","filenameDocument":"","progress":"/body/DocFragment[9]/body/p/text().1","percentage":0.6,"updated":0,"seq":4}]}"#.utf8)
    }

    private func requestID(_ record: Data?) throws -> String {
        let text = try XCTUnwrap(record.flatMap { String(data: $0, encoding: .utf8) })
        return String(text.split(separator: " ")[1])
    }

    /// Connects, answers the status and returns the READ_LIST request ID.
    private func connect(_ link: ReaderBluetoothLink, status: Data? = nil) throws -> String? {
        transport.send(.connected(peripheral))
        XCTAssertEqual(link.phase, .preparing)
        transport.send(.ready(status: status ?? self.status()))
        guard link.phase == .listing else { return nil }
        XCTAssertEqual(transport.writes.last.flatMap { String(data: $0, encoding: .utf8) }?.hasPrefix("READ_LIST "), true)
        transport.send(.wrote(nil))
        return try requestID(transport.writes.last)
    }

    private func sendList(_ body: Data, id: String, crc: UInt32? = nil) {
        for (seq, chunk) in ReadingSyncBLE.chunks(body).enumerated() {
            transport.send(.received(Data("D \(id) \(seq) ".utf8) + chunk))
        }
        transport.send(.received(Data("END \(id) \(body.count) \(ReadingSyncBLE.hex(crc ?? CRC32.checksum(body)))".utf8)))
    }

    /// Acknowledges every write of the current offer; returns the reassembled body.
    private func completeOfferWrites(from index: Int) -> Data {
        var body = Data()
        var next = index
        while next < transport.writes.count {
            let record = transport.writes[next]
            if let text = String(data: record, encoding: .utf8), text.hasPrefix("W ") {
                let prefix = text.split(separator: " ", maxSplits: 3).prefix(3).joined(separator: " ") + " "
                body.append(record.dropFirst(prefix.utf8.count))
            }
            next += 1
            transport.send(.wrote(nil))
        }
        return body
    }

    func testWithoutAPairedReaderBluetoothIsNeverStarted() {
        let link = makeLink(remember: false)
        link.start()
        XCTAssertEqual(link.phase, .off)
        XCTAssertEqual(transport.activations, 0, "No central, so no permission prompt, before a pairing")
        link.remember(peripheral: peripheral, readerID: readerID, model: "X3")
        XCTAssertEqual(link.phase, .waiting)
        XCTAssertEqual(transport.connects, [peripheral])
        XCTAssertEqual(RememberedBluetoothReaderStore(defaults: defaults).reader?.readerID, readerID, "Remembered across launches")
    }

    func testSettingsSetupPairsOnceThenEndsTheConnectionAndForgetStops() async {
        let link = makeLink(remember: false)
        link.start()
        var requested = 0, ended = 0
        link.requestSetupConnection = { requested += 1 }
        link.endSetupConnection = { ended += 1 }
        link.beginSetup()
        XCTAssertEqual(link.setup, .searching)
        XCTAssertEqual(requested, 1)
        // The shell remembers the reader when the Nearby Sync connection authenticates.
        link.remember(peripheral: peripheral, readerID: readerID, model: "X3")
        XCTAssertEqual(link.setup, .paired("X3"))
        await Task.yield()
        XCTAssertEqual(ended, 1, "Setup needs no hotspot: the connection ends once remembered")
        XCTAssertEqual(link.phase, .waiting)

        link.forget()
        XCTAssertNil(link.rememberedReader)
        XCTAssertNil(RememberedBluetoothReaderStore(defaults: defaults).reader)
        XCTAssertEqual(link.phase, .off)

        link.beginSetup()
        link.cancelSetup()
        XCTAssertEqual(link.setup, .idle)
        XCTAssertEqual(ended, 2)
    }

    func testListEndBeforeWriteAcknowledgementWaitsBeforeOffering() async throws {
        let link = makeLink()
        link.start()
        transport.send(.connected(peripheral))
        transport.send(.ready(status: status()))
        let id = try requestID(transport.writes.last)
        sendList(listJSON, id: id)
        await Task.yield()
        XCTAssertEqual(link.phase, .listing)
        XCTAssertEqual(transport.writes.count, 1)
        XCTAssertEqual(libraryLoads, 0)
        transport.send(.wrote(nil))
        await link.mergeTask?.value
        XCTAssertEqual(link.phase, .offering)
        XCTAssertEqual(transport.writes.count, 2, "Only OFFER; its W chunks wait for its own acknowledgement")
        transport.send(.wrote(nil))
        XCTAssertEqual(transport.writes.count, 3)
    }

    func testDemoBindingCancelsSynchronouslyAndBlocksLaunch() {
        let model = PocketModel()
        model.isDemoMode = true
        let link = makeLink()
        link.bindAppState(to: model)
        link.start()
        XCTAssertEqual(transport.activations, 0)
        model.isDemoMode = false
        XCTAssertEqual(link.phase, .waiting)
        model.isDemoMode = true
        XCTAssertEqual(link.phase, .off)
        XCTAssertEqual(transport.cancels, 1)
    }

    func testReaderWorkPreemptsBLEUntilCancellationDrains() async throws {
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(delay: .seconds(30)))
        let link = makeLink()
        link.bindAppState(to: model)
        link.start()
        let id = try XCTUnwrap(try connect(link))
        sendList(listJSON, id: id)
        await link.mergeTask?.value
        XCTAssertEqual(link.phase, .offering)
        model.findOnLocalNetwork(retryIfMissing: false)
        XCTAssertEqual(link.phase, .off, "HTTP work takes ownership before its Task starts")
        model.cancelConnectionAttempt()
        XCTAssertEqual(link.phase, .off, "Cancellation keeps the lane reserved while I/O drains")
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(link.phase, .waiting)
    }

    func testForgetDuringOfferDoesNotRearmOrCountUnconfirmedWrites() async throws {
        let link = makeLink()
        link.start()
        let id = try XCTUnwrap(try connect(link))
        sendList(listJSON, id: id)
        await link.mergeTask?.value
        XCTAssertEqual(link.phase, .offering)
        link.forget()
        XCTAssertEqual(link.phase, .off)
        XCTAssertTrue(scheduler.pending.isEmpty)
        XCTAssertNil(sync.lastReaderExchange, "Forgetting during an offer is not a completed exchange")
        XCTAssertNil(link.lastCompletedAt)
        transport.send(.wrote(nil))
        XCTAssertEqual(link.phase, .off)
    }

    func testSuccessfulExchangeMergesOffersAndReArms() async throws {
        let link = makeLink()
        link.start()
        XCTAssertEqual(link.phase, .waiting)
        let id = try XCTUnwrap(try connect(link))
        sendList(listJSON, id: id)
        XCTAssertEqual(link.phase, .merging)
        await link.mergeTask?.value
        XCTAssertEqual(libraryLoads, 1)
        XCTAssertEqual(link.phase, .offering)

        let offerIndex = transport.writes.count - 1
        let offer = try XCTUnwrap(String(data: transport.writes[offerIndex], encoding: .utf8))
        XCTAssertTrue(offer.hasPrefix("OFFER "))
        let offerID = try requestID(transport.writes[offerIndex])
        let body = completeOfferWrites(from: offerIndex)
        let expected = try CrossPointClient.readingOfferBody(
            PositionRecord(document: digest, progress: "/body/DocFragment[4]/body/p/text().0", percentage: 0.8,
                           device: "Pocket Daily iPhone", deviceID: "", timestamp: nil), identity: readerID)
        XCTAssertEqual(body, expected, "Only the book further along here is offered, as the HTTP body")
        XCTAssertTrue(offer.hasSuffix(" \(expected.count) \(ReadingSyncBLE.hex(CRC32.checksum(expected)))"))
        XCTAssertNil(sync.lastReaderExchange, "Not recorded before the reader confirms")

        transport.send(.received(Data("OK \(offerID)".utf8)))
        XCTAssertEqual(sync.lastReaderExchange?.received, 2)
        XCTAssertEqual(sync.lastReaderExchange?.sent, 1)
        XCTAssertEqual(sync.lastReaderExchange?.device, "X3")
        XCTAssertNotNil(link.lastCompletedAt)
        XCTAssertEqual(link.rememberedReader?.lastExchangeAt, link.lastCompletedAt)
        XCTAssertEqual(RememberedBluetoothReaderStore(defaults: defaults).reader?.lastExchangeAt, link.lastCompletedAt)
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertEqual(transport.cancels, 1, "The app disconnects after the exchange")

        let behind = library[1]
        let suggestion = await sync.suggestion(for: behind, current: behind.position)
        XCTAssertEqual(suggestion?.source, .reader("X3"), "The reader's further place is offered when the book opens")

        XCTAssertEqual(scheduler.pending.map(\.seconds), [timing.cooldown])
        XCTAssertEqual(scheduler.timers.filter(\.keepAwake).map(\.seconds), [timing.cooldown],
                       "Only re-arming must survive a suspension; timeouts rely on the disconnection")
        scheduler.fire(timing.cooldown)
        XCTAssertEqual(link.phase, .waiting)
        XCTAssertEqual(transport.connects, [peripheral, peripheral], "The pending connection is re-armed")
        XCTAssertTrue(scheduler.pending.isEmpty, "No session timer outlives the session")
    }

    func testAnotherReaderIDDisconnectsWithoutTraffic() throws {
        let link = makeLink()
        link.start()
        XCTAssertNil(try connect(link, status: status(id: "01234567")))
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(transport.cancels, 1)
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertNil(sync.readerExchangeError)
    }

    func testFirmwareWithoutReadingSyncDisconnects() throws {
        let link = makeLink()
        link.start()
        XCTAssertNil(try connect(link, status: status(capabilities: "AP,HTTP,SD,COMMIT1")))
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertEqual(transport.cancels, 1)
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertNil(sync.readerExchangeError)
    }

    func testMalformedStatusDisconnects() {
        let link = makeLink()
        link.start()
        transport.send(.connected(peripheral))
        transport.send(.ready(status: Data([0xFF, 0xFE])))
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertTrue(transport.writes.isEmpty)
    }

    func testChecksumMismatchDiscardsTheList() async throws {
        let link = makeLink()
        link.start()
        let id = try XCTUnwrap(try connect(link))
        sendList(listJSON, id: id, crc: CRC32.checksum(listJSON) ^ 0xFF)
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertEqual(libraryLoads, 0)
        XCTAssertEqual(transport.writes.count, 1, "Nothing is offered")
        XCTAssertNotNil(sync.readerExchangeError)
        let suggestion = await sync.suggestion(for: library[1], current: library[1].position)
        XCTAssertNil(suggestion, "No place from a corrupt list is kept")
    }

    func testRecordsForAnotherRequestAreIgnoredAndMalformedOnesEndTheList() throws {
        let link = makeLink()
        link.start()
        let id = try XCTUnwrap(try connect(link))
        transport.send(.received(Data("END FFFFFFFF 1 00000000".utf8)))
        transport.send(.received(Data("AP \(id) Pocket-1 ABCDEF123456 192.168.4.1 80 0 600".utf8)))
        XCTAssertEqual(link.phase, .listing)
        transport.send(.received(Data("D \(id) x y".utf8)))
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertNotNil(sync.readerExchangeError)
    }

    func testReaderErrorForTheListIsReported() throws {
        let link = makeLink()
        link.start()
        let id = try XCTUnwrap(try connect(link))
        transport.send(.received(Data("ERR \(id) BUSY".utf8)))
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertEqual(sync.readerExchangeError, ReadingSyncBLEError.rejected("BUSY").errorDescription)
    }

    func testTimeoutsBeforeTheExchangeAreQuiet() throws {
        let link = makeLink()
        link.start()
        transport.send(.connected(peripheral))
        scheduler.fire(timing.prepare)
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertEqual(transport.cancels, 1)
        XCTAssertNotNil(link.lastFailure, "Connection diagnostics must explain a timeout even before merge")
        XCTAssertNil(sync.readerExchangeError, "A reader that stops answering before the list is not an error")

        scheduler.fire(timing.cooldown)
        _ = try connect(link)
        scheduler.fire(timing.step)
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertNil(sync.readerExchangeError)
    }

    func testTimeoutWhileOfferingFinishesTheExchangeWithAnError() async throws {
        let link = makeLink()
        link.start()
        let id = try XCTUnwrap(try connect(link))
        sendList(listJSON, id: id)
        await link.mergeTask?.value
        XCTAssertEqual(link.phase, .offering)
        _ = completeOfferWrites(from: transport.writes.count - 1)
        scheduler.fire(timing.step)
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertEqual(sync.readerExchangeError, ReadingSyncBLEError.timedOut.errorDescription)
        XCTAssertNil(sync.lastReaderExchange, "A timed-out offer does not become a successful exchange")
        let suggestion = await sync.suggestion(for: library[1], current: library[1].position)
        XCTAssertNotNil(suggestion, "Places already received are kept")
    }

    func testSessionTimeoutBoundsTheWholeConnection() throws {
        let link = makeLink()
        link.start()
        let id = try XCTUnwrap(try connect(link))
        transport.send(.received(Data("D \(id) 0 {".utf8)))
        scheduler.fire(timing.session)
        XCTAssertEqual(link.phase, .coolingDown)
    }

    func testUnknownDocumentMovesToTheNextOfferAndOtherErrorsStop() async throws {
        library = [book(digest, fraction: 0.8), book(otherDigest, fraction: 0.9)]
        let link = makeLink()
        link.start()
        let id = try XCTUnwrap(try connect(link))
        sendList(listJSON, id: id)
        await link.mergeTask?.value
        let first = transport.writes.count - 1
        let firstID = try requestID(transport.writes[first])
        transport.send(.received(Data("ERR \(firstID) UNKNOWN_DOCUMENT".utf8)))
        XCTAssertEqual(transport.writes.count, first + 1, "The next offer waits for the write in flight")
        transport.send(.wrote(nil))
        let second = transport.writes.count - 1
        XCTAssertTrue(String(data: transport.writes[second], encoding: .utf8)?.hasPrefix("OFFER ") == true)
        let secondID = try requestID(transport.writes[second])
        XCTAssertNotEqual(firstID, secondID)
        _ = completeOfferWrites(from: second)
        transport.send(.received(Data("OK \(secondID)".utf8)))
        XCTAssertEqual(sync.lastReaderExchange?.sent, 1)
        XCTAssertNil(sync.readerExchangeError)

        scheduler.fire(timing.cooldown)
        let again = try XCTUnwrap(try connect(link))
        sendList(listJSON, id: again)
        await link.mergeTask?.value
        let offerID = try requestID(transport.writes.last)
        transport.send(.received(Data("ERR \(offerID) NO_MEMORY".utf8)))
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertEqual(sync.readerExchangeError, ReadingSyncBLEError.rejected("NO_MEMORY").errorDescription)
    }

    func testDisconnectMidExchangeIsReportedOnceTheExchangeBegan() async throws {
        let link = makeLink()
        link.start()
        let id = try XCTUnwrap(try connect(link))
        sendList(listJSON, id: id)
        await link.mergeTask?.value
        transport.send(.disconnected(nil))
        XCTAssertEqual(link.phase, .coolingDown)
        XCTAssertEqual(transport.cancels, 0, "Already disconnected")
        XCTAssertNotNil(sync.readerExchangeError)
    }

    func testStandsDownWhileNearbySyncOwnsBluetooth() throws {
        let link = makeLink()
        link.start()
        _ = try connect(link)
        link.nearbySessionActive = true
        XCTAssertEqual(link.phase, .off)
        XCTAssertEqual(transport.cancels, 1)
        transport.send(.connected(peripheral))
        XCTAssertEqual(link.phase, .off, "A late connection does not start a session")
        link.start()
        XCTAssertEqual(link.phase, .off)
        link.nearbySessionActive = false
        XCTAssertEqual(link.phase, .waiting)
    }

    func testDemoModeNeverConnects() {
        let link = makeLink()
        link.isDemoMode = true
        link.start()
        XCTAssertEqual(link.phase, .off)
        XCTAssertTrue(transport.connects.isEmpty)
        link.isDemoMode = false
        XCTAssertEqual(link.phase, .waiting)
    }

    func testTurningReaderExchangeOffCancelsThePendingConnection() {
        let link = makeLink()
        link.start()
        XCTAssertEqual(link.phase, .waiting)
        sync.readerExchangeEnabled = false
        XCTAssertEqual(link.phase, .off)
        XCTAssertEqual(transport.cancels, 1)
        link.start()
        XCTAssertEqual(link.phase, .off)
        sync.readerExchangeEnabled = true
        XCTAssertEqual(link.phase, .waiting)
    }

    func testBluetoothOffAndUnknownPeripheralLeaveTheLinkOff() {
        transport.isAvailable = false
        let link = makeLink()
        link.start()
        XCTAssertEqual(link.phase, .off)
        XCTAssertEqual(transport.activations, 1)
        transport.isAvailable = true
        transport.send(.availabilityChanged(true))
        XCTAssertEqual(link.phase, .waiting)
        transport.send(.availabilityChanged(false))
        XCTAssertEqual(link.phase, .off)

        transport.known = []
        transport.send(.availabilityChanged(true))
        XCTAssertEqual(link.phase, .off, "The system no longer knows the paired peripheral")
    }

    func testRestoredConnectionStartsASessionAtOnce() {
        transport.connectedOnRequest = true
        let link = makeLink()
        link.start()
        XCTAssertEqual(link.phase, .preparing)
        XCTAssertEqual(transport.prepares, 1)
    }
}
