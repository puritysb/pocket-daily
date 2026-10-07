import XCTest
@testable import Pocket

@MainActor
final class TransferSeparationTests: XCTestCase {
    private var folders: [URL] = []
    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        super.tearDown()
    }
    private func fixture(_ name: String, id: UUID = UUID(), attempted: Bool = false, publicationPending: Bool? = nil) throws -> PreparedTransfer {
        let item = PreparedTransfer(id: id, filename: name, firmwareVersion: name.hasSuffix(".bin") ? "test" : nil,
                                    readerID: attempted ? "1234ABCD" : nil, remoteStagingID: attempted ? id : nil, publicationPending: publicationPending)
        let folder = TransferPreparation.file(item).deletingLastPathComponent()
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: TransferPreparation.file(item))
        try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("transfer.json"))
        return item
    }
    private func setup(failControl: Bool = false, identity: String = "1234ABCD", receipts: Bool = false,
                       heldPublication: String? = nil,
                       localFiles: PocketModel.LocalFileOperations = .init(),
                       releases: PocketModel.ReleaseOperations = .init()) throws -> (PocketModel, URLSession) {
        TransferControlProtocol.reset(failControl: failControl, identity: identity, receipts: receipts, heldPublication: heldPublication)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransferControlProtocol.self]
        let session = URLSession(configuration: configuration)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session),
                                localFiles: localFiles, releaseSource: releases)
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: TransferControlProtocol.status(identity: "1234ABCD", receipts: receipts))
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
    func testOriginalBatchKeepsPauseAndStopScopeAfterFirstConfirmedFileLeavesQueue() async throws {
        let sortedIDs = [UUID(), UUID()].sorted { $0.uuidString < $1.uuidString }
        let first = try fixture("batch-A.epub", id: sortedIDs[0], attempted: true, publicationPending: true)
        let second = try fixture("batch-B.epub", id: sortedIDs[1], attempted: true, publicationPending: true)
        let (model, session) = try setup(receipts: true, heldPublication: "/batch-B.epub")
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        let ids: Set<UUID> = [first.id, second.id]
        model.sendPreparedFiles(ids: ids)
        for _ in 0..<300 where model.preparedTransfers.contains(where: { $0.id == first.id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.preparedTransfers.contains { $0.id == first.id })
        XCTAssertTrue(model.preparedTransfers.contains { $0.id == second.id })
        XCTAssertEqual(Set(model.activePreparedFileBatch.map(\.id)), ids)
        XCTAssertTrue(model.isSendingPreparedFiles(ids: ids))
        XCTAssertFalse(model.isSendingPreparedFiles(ids: [second.id]), "A remaining subset cannot cancel another admitted scope")
        model.stopAndRemovePreparedFiles(ids: ids)
        for _ in 0..<300 where model.isWorking || model.preparedTransfers.contains(where: { $0.id == second.id }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.activePreparedFileBatch.isEmpty)
        XCTAssertFalse(model.preparedTransfers.contains { ids.contains($0.id) })
        XCTAssertEqual(TransferControlProtocol.controls.compactMap { $0["action"] }, ["discard"])
        XCTAssertEqual(TransferControlProtocol.controls.first?["staging"], "/.pocket-\(second.id.uuidString.lowercased()).part")
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

    func testLocalFirmwareBuildUsesTheFirmwareLaneAndKeepsTheChosenFile() async throws {
        let item = PreparedTransfer(id: UUID(), filename: "update.bin", firmwareVersion: "0.1.0-dev-test", readerID: nil)
        let folder = TransferPreparation.file(item).deletingLastPathComponent()
        folders.append(folder)
        let sourceFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(sourceFolder)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("update.bin")
        try Data("fixture".utf8).write(to: source)
        let (model, session) = try setup(localFiles: .init(prepare: { _ in
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: TransferPreparation.file(item))
            return item
        }), releases: .init(latest: { throw FirmwareReleaseError.unavailable }))
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        XCTAssertTrue(model.canSendLocalFirmware)
        TransferControlProtocol.holdPrepare()
        let task = Task { await model.updateFirmware(fromLocalImage: source) }
        for _ in 0..<300 where TransferControlProtocol.controls.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.activeTransferKind, .firmware)
        XCTAssertFalse(model.canSendLocalFirmware, "One image at a time")
        task.cancel()
        await task.value
        try await wait(model)
        XCTAssertEqual(TransferControlProtocol.controls.compactMap { $0["action"] }, ["prepare", "discard"])
        XCTAssertTrue(TransferControlProtocol.controls.allSatisfy { $0["kind"] == "firmware" })
        XCTAssertFalse(model.preparedTransfers.contains { $0.id == item.id })
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertEqual(try Data(contentsOf: source), Data("fixture".utf8), "The chosen build is never moved or removed")
    }

    func testLocalFirmwareInspectionRejectsANonImageAndNeedsAReader() async throws {
        let sourceFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(sourceFolder)
        try FileManager.default.createDirectory(at: sourceFolder, withIntermediateDirectories: true)
        let source = sourceFolder.appendingPathComponent("notes.bin")
        try Data("not a firmware image".utf8).write(to: source)
        let (model, session) = try setup()
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        let rejected = await model.inspectLocalFirmware(source)
        XCTAssertNil(rejected)
        XCTAssertEqual(model.message, FirmwareValidationError.tooSmall.errorDescription)
        XCTAssertEqual(model.messageTone, .failure)
        model.readerStatus = nil
        let offline = await model.inspectLocalFirmware(source)
        XCTAssertNil(offline)
        XCTAssertTrue(model.message.contains("Connect a reader"))
        await model.updateFirmware(fromLocalImage: source)
        XCTAssertTrue(TransferControlProtocol.controls.isEmpty)
        XCTAssertFalse(model.preparedTransfers.contains { $0.kind == .firmware })
    }

    func testLocalFirmwareConfirmationNamesTheImageAndWarnsWhenTheReaderAlreadyRunsIt() {
        let image = PocketModel.LocalFirmwareImage(file: URL(fileURLWithPath: "/tmp/update.bin"),
                                                   version: "0.1.0", byteCount: 6_331_344)
        let newer = image.confirmation(readerVersion: "1.0.0-dev-main-433b3e7d")
        XCTAssertTrue(newer.contains("update.bin reports 0.1.0"))
        XCTAssertTrue(newer.contains("not an official release"))
        XCTAssertTrue(newer.contains("only after you confirm on the reader"))
        XCTAssertFalse(newer.contains("already reports"))
        XCTAssertTrue(image.confirmation(readerVersion: " 0.1.0\n").contains("SD Card Firmware Update"))
        XCTAssertFalse(image.confirmation(readerVersion: nil).contains("already reports"))
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

    func testOfficialImageCanBePreparedOfflineFromReaderWithoutStartingTransfer() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folders.append(folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let downloaded = folder.appendingPathComponent("official.bin")
        try Data("test image".utf8).write(to: downloaded)
        let item = PreparedTransfer(id: UUID(), filename: "official.bin", firmwareVersion: "0.2.0", readerID: nil)
        let release = FirmwareRelease(version: "0.2.0", downloadURL: URL(string: "https://example.invalid/update.bin")!, byteCount: 10)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(),
            localFiles: .init(prepare: { _ in item }),
            releaseSource: .init(latest: { release }, download: { _, _ in downloaded }))
        XCTAssertNil(model.readerStatus)
        await model.prepareOfficialFirmware()
        XCTAssertTrue(model.preparedTransfers.contains { $0.id == item.id })
        XCTAssertNil(model.preparedTransfers.first { $0.id == item.id }?.readerID)
        XCTAssertFalse(model.isTransferring)
        XCTAssertTrue(model.message.contains("Direct connection"))
        XCTAssertEqual(model.readerUpdateState, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloaded.path))
    }

    func testAutomaticSessionEndInstructionsStillRequireReaderConfirmation() {
        let message = PocketModel.stagedFirmwareMessage(version: "0.2.0", endsSession: true)
        XCTAssertTrue(message.contains("confirm installation on the reader"))
        XCTAssertFalse(message.contains("Press Back"))
        XCTAssertTrue(PocketModel.stagedFirmwareMessage(version: "0.2.0").contains("Press Back"))
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
    nonisolated(unsafe) private static var receipts = false
    nonisolated(unsafe) private static var heldPublication: String?
    static var controls: [[String: String]] { lock.withLock { recorded } }
    static func reset(failControl: Bool, identity: String, receipts: Bool = false, heldPublication: String? = nil) {
        lock.withLock { recorded = []; held = false; fail = failControl; self.identity = identity; self.receipts = receipts; self.heldPublication = heldPublication }
    }
    static func status(identity: String, receipts: Bool = false) -> Data {
        Data("{\"version\":\"1.7.0\",\"device\":\"X3\",\"deviceID\":\"\(identity)\",\"ip\":\"192.0.2.1\",\"mode\":\"STA\",\"rssi\":-40,\"freeHeap\":20000,\"uptime\":1,\"transferControl\":1,\"publicationReceipt\":\(receipts ? 1 : 0)}".utf8)
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
        let (fail, id, receipts, heldPublication) = Self.lock.withLock { () -> (Bool, String, Bool, String?) in
            if control, let object = try? JSONSerialization.jsonObject(with: sent) as? [String: String] { Self.recorded.append(object) }
            return (Self.fail, Self.identity, Self.receipts, Self.heldPublication)
        }
        if control, Self.lock.withLock({ Self.held }),
           (try? JSONSerialization.jsonObject(with: sent) as? [String: String])?["action"] == "prepare" { return }
        let body: Data
        if url.path == "/api/status" { body = Self.status(identity: id, receipts: receipts) }
        else if url.path == "/api/pocket/v1/publication",
                let fields = try? JSONSerialization.jsonObject(with: sent) as? [String: Any] {
            if let heldPublication, fields["target"] as? String == heldPublication { return }
            guard let size = fields["size"], let crc = fields["crc32"],
                  let receipt = try? JSONSerialization.data(withJSONObject: ["size": size, "crc32": crc]) else { return }
            body = receipt
        } else { body = Data("{\"ok\":true}".utf8) }
        guard let response = HTTPURLResponse(url: url, statusCode: control && fail ? 503 : 200, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
