import XCTest
@testable import Pocket

@MainActor
final class TransferSeparationTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }
    private func fixture(_ name: String, attempted: Bool = false, publicationPending: Bool? = nil) throws -> PreparedTransfer {
        let id = UUID()
        let item = PreparedTransfer(id: id, filename: name, firmwareVersion: name.hasSuffix(".bin") ? "test" : nil,
                                    readerID: attempted ? "1234ABCD" : nil, remoteStagingID: attempted ? id : nil, publicationPending: publicationPending)
        let folder = TransferPreparation.file(item).deletingLastPathComponent()
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: TransferPreparation.file(item))
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("transfer.json"))
        return item
    }
    private func setup(failControl: Bool = false, identity: String = "1234ABCD",
                       localFiles: PocketModel.LocalFileOperations = .init(),
                       releases: PocketModel.ReleaseOperations = .init()) throws -> (PocketModel, URLSession) {
        TransferControlProtocol.reset(failControl: failControl, identity: identity)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferControlProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session),
                                localFiles: localFiles, releaseSource: releases)
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: TransferControlProtocol.status(identity: "1234ABCD"))
        return (model, session)
    }
    private func wait(_ model: PocketModel) async throws {
        for _ in 0..<300 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isWorking)
    }
    func testUnconfirmedPublicationSurvivesReloadAndCannotBeResent() async throws {
        let item = try fixture("unconfirmed.epub", attempted: true, publicationPending: true)
        let (model, session) = try setup()
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        XCTAssertEqual(model.preparedTransfers.first { $0.id == item.id }?.publicationPending, true)
        model.sendPreparedFiles(kind: .content)
        try await wait(model)
        XCTAssertTrue(TransferControlProtocol.controls.isEmpty, "Must not even prepare another upload")
        XCTAssertTrue(model.message.contains("may have saved"))
        XCTAssertEqual(model.messageTone, .pending)
        XCTAssertNotNil(model.preparedTransfers.first { $0.id == item.id })
    }

    func testContentSendNeverStartsPendingFirmware() async throws {
        let book = try fixture("separation.epub")
        let firmware = try fixture("separation.bin")
        let (model, session) = try setup(failControl: true)
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        model.sendPreparedFiles()
        try await wait(model)
        let request = try XCTUnwrap(TransferControlProtocol.controls.first)
        XCTAssertEqual(request["kind"], "content")
        XCTAssertEqual(request["staging"], "/.pocket-\(book.id.uuidString.lowercased()).part")
        XCTAssertEqual(TransferControlProtocol.controls.count, 1)
        XCTAssertNil(model.preparedTransfers.first { $0.id == firmware.id }?.remoteStagingID)
    }
    func testRejectedNewFirmwareCannotSendAnOlderQueuedImage() async throws {
        let firmware = try fixture("earlier.bin")
        let (model, session) = try setup()
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let downloaded = folder.appendingPathComponent("new.bin")
        try Data("new download fixture".utf8).write(to: downloaded)
        model.stageDownloadedFirmware(downloaded)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(TransferControlProtocol.controls.isEmpty)
        XCTAssertNil(model.preparedTransfers.first { $0.id == firmware.id }?.remoteStagingID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }

    func testFirmwareSendNeverStartsPendingContent() async throws {
        let book = try fixture("separation.epub")
        let firmware = try fixture("separation.bin")
        let (model, session) = try setup(failControl: true)
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        model.sendPreparedFiles(kind: .firmware)
        try await wait(model)
        let request = try XCTUnwrap(TransferControlProtocol.controls.first)
        XCTAssertEqual(request["kind"], "firmware")
        XCTAssertEqual(request["staging"], "/.pocket-\(firmware.id.uuidString.lowercased()).part")
        XCTAssertNil(model.preparedTransfers.first { $0.id == book.id }?.remoteStagingID)
    }
    func testCleanupFailureRetainsCopyAndSuccessfulRetryOnlyRemovesContent() async throws {
        let book = try fixture("cleanup.epub", attempted: true)
        let firmware = try fixture("cleanup.bin", attempted: true)
        let (model, session) = try setup(failControl: true)
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        model.removePreparedFiles()
        try await wait(model)
        XCTAssertTrue(model.preparedTransfers.contains { $0.id == book.id })
        XCTAssertTrue(FileManager.default.fileExists(atPath: TransferPreparation.file(book).path))
        TransferControlProtocol.reset(failControl: false, identity: "1234ABCD")
        model.removePreparedFiles()
        try await wait(model)
        XCTAssertFalse(model.preparedTransfers.contains { $0.id == book.id })
        XCTAssertTrue(model.preparedTransfers.contains { $0.id == firmware.id })
        XCTAssertEqual(TransferControlProtocol.controls.first?["action"], "discard")
        XCTAssertEqual(TransferControlProtocol.controls.first?["staging"], "/.pocket-\(book.id.uuidString.lowercased()).part")
    }
    func testChangedReaderCannotBeCleanedAndExplicitLocalRemovalMakesNoRequest() async throws {
        let book = try fixture("identity.epub", attempted: true)
        let (model, session) = try setup(identity: "9999FFFF")
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        model.removePreparedFiles()
        try await wait(model)
        XCTAssertTrue(model.preparedTransfers.contains { $0.id == book.id })
        XCTAssertTrue(TransferControlProtocol.controls.isEmpty)
        model.removePreparedFiles(localOnly: true)
        try await wait(model)
        XCTAssertFalse(model.preparedTransfers.contains { $0.id == book.id })
        XCTAssertTrue(TransferControlProtocol.controls.isEmpty)
    }
    func testStopWaitsForCancelledRequestThenCleansOnlyItsStaging() async throws {
        let book = try fixture("stop.epub")
        let (model, session) = try setup()
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        TransferControlProtocol.holdPrepare()
        model.sendPreparedFiles()
        for _ in 0..<300 where TransferControlProtocol.controls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.activeTransferKind, .content)
        model.stopAndRemoveTransfer()
        for _ in 0..<300 where model.isWorking || model.preparedTransfers.contains(where: { $0.id == book.id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.preparedTransfers.contains { $0.id == book.id })
        XCTAssertEqual(TransferControlProtocol.controls.compactMap { $0["action"] }, ["prepare", "discard"])
    }
    func testCancelOfficialUpdateDrainsTransferAndDiscardsFirmwareStaging() async throws {
        let item = PreparedTransfer(id: UUID(), filename: "firmware.bin", firmwareVersion: "99.0.0", readerID: nil)
        let folder = TransferPreparation.file(item).deletingLastPathComponent()
        folders.append(folder)
        let downloadFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(downloadFolder)
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        let download = downloadFolder.appendingPathComponent("firmware.bin")
        try Data("fixture".utf8).write(to: download)
        let release = FirmwareRelease(version: "99.0.0", downloadURL: URL(string: "https://example.invalid")!, byteCount: 7)
        let (model, session) = try setup(localFiles: .init(prepare: { _ in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: TransferPreparation.file(item))
            return item
        }), releases: .init(latest: { release }, download: { _, _ in download }))
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        TransferControlProtocol.holdPrepare()
        let task = Task { await model.updateFirmware() }
        for _ in 0..<300 where TransferControlProtocol.controls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.activeTransferKind, .firmware)
        task.cancel()
        await task.value
        try await wait(model)
        XCTAssertEqual(TransferControlProtocol.controls.compactMap { $0["action"] }, ["prepare", "discard"])
        XCTAssertTrue(TransferControlProtocol.controls.allSatisfy { $0["kind"] == "firmware" })
        XCTAssertFalse(model.preparedTransfers.contains { $0.id == item.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadFolder.path))
    }

    func testBackgroundDoesNotStartDeferredCleanup() async throws {
        let book = try fixture("background.epub", attempted: true)
        let (model, session) = try setup()
        defer { session.invalidateAndCancel() }
        model.pauseForBackground()
        model.removePreparedFiles()
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.preparedTransfers.contains { $0.id == book.id })
        XCTAssertTrue(TransferControlProtocol.controls.isEmpty)
    }

    func testOlderQueueStillKnowsItMayHaveStagingAndClassificationDoesNotDependOnVersion() throws {
        let id = UUID()
        let json = Data("{\"id\":\"\(id)\",\"filename\":\"update.BIN\",\"readerID\":\"1234ABCD\"}".utf8)
        let item = try JSONDecoder().decode(PreparedTransfer.self, from: json)
        XCTAssertEqual(item.kind, .firmware)
        XCTAssertEqual(item.stagingID, id)
    }
}

private final class TransferControlProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [[String: String]] = []
    nonisolated(unsafe) private static var held = false
    static func holdPrepare() { lock.withLock { held = true } }
    nonisolated(unsafe) private static var fail = false
    nonisolated(unsafe) private static var identity = "1234ABCD"
    static var controls: [[String: String]] { lock.withLock { recorded } }
    static func reset(failControl: Bool, identity: String) {
        lock.withLock { recorded = []; held = false; fail = failControl; self.identity = identity }
    }
    static func status(identity: String) -> Data {
        Data("{\"version\":\"1.7.0\",\"device\":\"X3\",\"deviceID\":\"\(identity)\",\"ip\":\"192.0.2.1\",\"mode\":\"STA\",\"rssi\":-40,\"freeHeap\":20000,\"uptime\":1,\"transferControl\":1}".utf8)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var sent = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                sent.append(buffer, count: count)
            }
        }
        let control = url.path == "/api/pocket/v1/transfer"
        let (fail, id) = Self.lock.withLock { () -> (Bool, String) in
            if control, let object = try? JSONSerialization.jsonObject(with: sent) as? [String: String] { Self.recorded.append(object) }
            return (Self.fail, Self.identity)
        }
        if control, Self.lock.withLock({ Self.held }),
           (try? JSONSerialization.jsonObject(with: sent) as? [String: String])?["action"] == "prepare" { return }
        let body = url.path == "/api/status" ? Self.status(identity: id) : Data("{\"ok\":true}".utf8)
        guard let response = HTTPURLResponse(url: url, statusCode: control && fail ? 503 : 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
