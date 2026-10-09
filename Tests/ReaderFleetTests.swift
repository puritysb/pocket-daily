import XCTest
@testable import Pocket

@MainActor
final class ReaderFleetTests: XCTestCase {
    private var roots: [URL] = []
    private var fleets: [ReaderFleet] = []
    private var sessions: [URLSession] = []

    override func tearDown() {
        MainActor.assumeIsolated {
            for fleet in fleets {
                for reader in fleet.readers {
                    reader.model.pauseForBackground()
                    UserDefaults.standard.removePersistentDomain(forName: "Pocket.reader." + reader.id.uuidString)
                }
            }
            sessions.forEach { $0.invalidateAndCancel() }
            roots.forEach { try? FileManager.default.removeItem(at: $0) }
            fleets.removeAll()
        }
        super.tearDown()
    }

    private func makeFleet() throws -> (ReaderFleet, ReaderRegistryStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        roots.append(root)
        let store = ReaderRegistryStore(file: root.appendingPathComponent("readers.json"))
        try store.save([
            ReaderRegistration(name: "Desk X3", deviceID: "11111111", host: "192.0.2.1"),
            ReaderRegistration(name: "Travel X4", deviceID: "22222222", host: "192.0.2.2")
        ])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FleetURLProtocol.self]
        let session = URLSession(configuration: config)
        sessions.append(session)
        let fleet = ReaderFleet(store: store, root: root, startBluetooth: false) { storage, link in
            PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session),
                        sessionStorage: storage, bluetoothLink: link)
        }
        fleets.append(fleet)
        return (fleet, store)
    }

    private func status(_ id: String?) throws -> CrossPointStatus {
        let identity = id.map { ",\"deviceID\":\"\($0)\"" } ?? ""
        return try JSONDecoder().decode(CrossPointStatus.self, from: Data("{\"device\":\"X3\",\"version\":\"test\",\"ip\":\"192.0.2.1\",\"mode\":\"STA\",\"rssi\":-40,\"freeHeap\":20000,\"uptime\":1\(identity)}".utf8))
    }

    func testTwoConnectionsRemainIndependentWhenSelectingAndDisconnecting() async throws {
        let (fleet, _) = try makeFleet()
        let a = fleet.readers[0], b = fleet.readers[1]
        async let first: Void = a.model.verify(host: "192.0.2.1", port: 80)
        async let second: Void = b.model.verify(host: "192.0.2.2", port: 80)
        _ = await (first, second)
        XCTAssertEqual(a.model.readerStatus?.deviceID, "11111111")
        XCTAssertEqual(b.model.readerStatus?.deviceID, "22222222")
        XCTAssertEqual(fleet.connectedCount, 2)
        fleet.selectedID = b.id
        XCTAssertEqual(a.model.readerStatus?.deviceID, "11111111")
        a.model.endConnection()
        for _ in 0..<100 where a.model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(a.model.readerStatus)
        XCTAssertEqual(b.model.readerStatus?.deviceID, "22222222")
        XCTAssertEqual(fleet.connectedCount, 1)
    }

    func testSlowConnectionToOneReaderDoesNotBlockAnother() async throws {
        let (fleet, _) = try makeFleet()
        let a = fleet.readers[0].model, b = fleet.readers[1].model
        FleetURLProtocol.holdFirstReader = true
        defer { FleetURLProtocol.releaseFirstReader() }
        let first = Task { await a.verify(host: "192.0.2.1", port: 80) }
        for _ in 0..<100 where !FleetURLProtocol.hasPendingReader { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(FleetURLProtocol.hasPendingReader)
        await b.verify(host: "192.0.2.2", port: 80)
        XCTAssertTrue(a.isWorking)
        XCTAssertEqual(b.readerStatus?.deviceID, "22222222")
        FleetURLProtocol.releaseFirstReader()
        await first.value
        XCTAssertEqual(fleet.connectedCount, 2)
    }

    func testWrongMissingAndDuplicateIdentityCannotBeClaimed() throws {
        let (fleet, _) = try makeFleet()
        let a = fleet.readers[0].model
        XCTAssertFalse(a.acceptsReader(try status("22222222"), "192.0.2.2", 80))
        XCTAssertFalse(a.acceptsReader(try status(nil), "192.0.2.1", 80))
        XCTAssertThrowsError(try a.acceptsBluetoothReader("22222222", UUID()))
        let newID = try fleet.add()
        let added = try XCTUnwrap(fleet.readers.first { $0.id == newID })
        XCTAssertFalse(added.model.acceptsReader(try status("11111111"), "192.0.2.9", 80))
        XCTAssertFalse(added.model.acceptsReader(try status(nil), "192.0.2.9", 80))
        XCTAssertTrue(added.model.acceptsReader(try status("33333333"), "192.0.2.9", 80))
        try added.model.registerReader(status("33333333"), "192.0.2.9", 80)
        XCTAssertFalse(added.model.acceptsReader(try status("44444444"), "192.0.2.9", 80))
    }

    func testDirectConnectionCannotDisruptAnotherReader() throws {
        let (fleet, _) = try makeFleet()
        let a = fleet.readers[0].model, b = fleet.readers[1].model
        a.readerStatus = try status("11111111")
        XCTAssertNotNil(b.networkAdmission(true))
        b.beginDirectConnection()
        XCTAssertFalse(b.directConnectionRequested)
        XCTAssertEqual(a.readerStatus?.deviceID, "11111111")
        a.readerStatus = nil
        b.beginDirectConnection()
        XCTAssertTrue(b.directConnectionRequested)
        XCTAssertNotNil(a.networkAdmission(false))
        XCTAssertNotNil(a.networkAdmission(true))
        a.startConnectionSearch()
        XCTAssertFalse(a.isSearchingForReader)
        b.cancelConnectionAttempt()
    }

    func testFilesJobsDraftsAndPairingAreIsolatedAcrossRestart() async throws {
        let (fleet, store) = try makeFleet()
        let a = fleet.readers[0], b = fleet.readers[1]
        let source = roots[0].appendingPathComponent("book.epub")
        try Data("test bytes".utf8).write(to: source)
        let item = try await a.model.sessionStorage.localFiles().prepare(source)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TransferPreparation.file(item, directory: a.model.sessionStorage.transfers).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: TransferPreparation.file(item, directory: b.model.sessionStorage.transfers).path))
        let job = BookTransferJob(id: UUID(), target: .init(readerID: "11111111", displayName: "Desk X3"), origin: .init(),
                                  stage: .needsConnection, items: [.init(bookID: UUID(), title: "A")])
        try await a.model.sessionStorage.jobs.save([job])
        let otherJobs = try await b.model.sessionStorage.jobs.load()
        XCTAssertTrue(otherJobs.isEmpty)
        let editor = ProfileEditorState()
        editor.draft.home.dailyWord.toggle()
        let snapshot = try XCTUnwrap(editor.snapshot)
        try a.model.profileEditStore.save(snapshot)
        XCTAssertNil(try b.model.profileEditStore.loadChecked())
        a.model.bluetoothLink.remember(peripheral: UUID(), readerID: "11111111", model: "X3", supportsReadingSync: true)
        XCTAssertNil(b.model.bluetoothLink.rememberedReader)
        try fleet.rename(a, to: "Reading Room")
        let restored = ReaderFleet(store: store, root: roots[0], startBluetooth: false)
        fleets.append(restored)
        XCTAssertEqual(restored.readers[0].registration.name, "Reading Room")
        XCTAssertEqual(restored.readers[0].model.bluetoothLink.rememberedReader?.readerID, "11111111")
        XCTAssertNil(restored.readers[1].model.bluetoothLink.rememberedReader)
        XCTAssertEqual(try restored.readers[0].model.profileEditStore.loadChecked(), snapshot)
        XCTAssertEqual(restored.readers[0].model.preparedTransfers.map(\.id), [item.id])
    }

    func testBusyRemovalAndCorruptRegistryPreserveData() throws {
        let (fleet, store) = try makeFleet()
        let a = fleet.readers[0]
        a.model.readerStatus = try status("11111111")
        XCTAssertThrowsError(try fleet.remove(a))
        XCTAssertEqual(try store.load()?.count, 2)
        let corrupt = Data("not a registry".utf8)
        try corrupt.write(to: store.file)
        let restored = ReaderFleet(store: store, root: roots[0], startBluetooth: false)
        fleets.append(restored)
        XCTAssertNotNil(restored.error)
        XCTAssertThrowsError(try restored.add())
        XCTAssertEqual(try Data(contentsOf: store.file), corrupt)
        XCTAssertFalse(try XCTUnwrap(restored.readers.first).model.acceptsReader(try status("11111111"), "192.0.2.1", 80))
    }

    func testRemovingIdleReaderPreservesCopiesAndOtherRegistration() async throws {
        let (fleet, store) = try makeFleet()
        let a = fleet.readers[0], b = fleet.readers[1]
        let source = roots[0].appendingPathComponent("kept.epub")
        try Data("kept bytes".utf8).write(to: source)
        let item = try await a.model.sessionStorage.localFiles().prepare(source)
        a.model.bluetoothLink.remember(peripheral: UUID(), readerID: "11111111", model: "X3")
        b.model.bluetoothLink.remember(peripheral: UUID(), readerID: "22222222", model: "X4")
        try fleet.remove(a)
        XCTAssertEqual(try store.load()?.map(\.id), [b.id])
        XCTAssertEqual(fleet.selectedID, b.id)
        XCTAssertNil(a.model.bluetoothLink.rememberedReader)
        XCTAssertEqual(b.model.bluetoothLink.rememberedReader?.readerID, "22222222")
        let restored = ReaderFleet(store: store, root: roots[0], startBluetooth: false)
        fleets.append(restored)
        XCTAssertEqual(restored.readers.first?.model.hardware, .x4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: TransferPreparation.file(item, directory: a.model.sessionStorage.transfers).path))
    }

    func testRegistryRejectsDuplicateIdentitiesAndUnknownSchema() throws {
        let (_, store) = try makeFleet()
        let duplicate = ReaderRegistration(name: "Duplicate", deviceID: "11111111")
        try store.save([duplicate, duplicate])
        XCTAssertThrowsError(try store.load())
        let data = try JSONEncoder().encode(ReaderRegistryStore.Archive(schema: 2, readers: [duplicate]))
        try data.write(to: store.file)
        XCTAssertThrowsError(try store.load())
    }
}

private final class FleetURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var held: FleetURLProtocol?
    private static var holding = false
    static var holdFirstReader: Bool {
        get { lock.withLock { holding } }
        set { lock.withLock { holding = newValue } }
    }
    static var hasPendingReader: Bool { lock.withLock { held != nil } }
    static func releaseFirstReader() {
        let pending = lock.withLock { let pending = held; held = nil; holding = false; return pending }
        pending?.respond()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.host == "192.0.2.1", request.url?.path == "/api/status", Self.holdFirstReader {
            Self.lock.withLock { Self.held = self }
            return
        }
        respond()
    }
    private func respond() {
        guard let url = request.url else { return }
        if url.path == "/api/status" {
            let id = url.host == "192.0.2.1" ? "11111111" : "22222222"
            let data = Data("{\"device\":\"X3\",\"version\":\"test\",\"deviceID\":\"\(id)\",\"ip\":\"\(url.host ?? "")\",\"mode\":\"STA\",\"rssi\":-40,\"freeHeap\":20000,\"uptime\":1}".utf8)
            if let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"]) {
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            }
        } else { client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)) }
    }
    override func stopLoading() { Self.lock.withLock { if Self.held === self { Self.held = nil } } }
}
