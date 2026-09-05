import CoreBluetooth
import CryptoKit
import Network
import XCTest
@testable import Pocket

final class NearbySyncProtocolTests: XCTestCase {
    func testConnectionHeartbeatRequiresConsecutiveFailures() {
        var heartbeat = ConnectionHeartbeat()
        XCTAssertFalse(heartbeat.recordFailure())
        XCTAssertFalse(heartbeat.recordFailure())
        heartbeat.recordSuccess()
        XCTAssertEqual(heartbeat.consecutiveFailures, 0)
        for _ in 0 ..< (ConnectionHeartbeat.failureLimit - 1) { XCTAssertFalse(heartbeat.recordFailure()) }
        XCTAssertTrue(heartbeat.recordFailure())
    }

    func testPocketAdvertisementFallbackAcceptsServiceOrNameOnly() {
        XCTAssertTrue(NearbySyncController.isPocketAdvertisement(
            name: nil,
            serviceUUIDs: [NearbySyncProtocol.service]
        ))
        XCTAssertTrue(NearbySyncController.isPocketAdvertisement(
            name: "Pocket-AF70",
            serviceUUIDs: []
        ))
        XCTAssertFalse(NearbySyncController.isPocketAdvertisement(
            name: "Nearby Headphones",
            serviceUUIDs: []
        ))
    }

    func testCRC32MatchesWireFormat() {
        var crc = CRC32()
        crc.update(Data("123456789".utf8))
        XCTAssertEqual(crc.finalized, 0xCBF4_3926)
    }

    func testStatusAdvertisesPersistentUploadStream() throws {
        let data = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":16000,"uptime":4,"device":"X3","uploadStreamPort":82}"#.utf8)
        let status = try JSONDecoder().decode(CrossPointStatus.self, from: data)
        XCTAssertEqual(status.uploadStreamPort, 82)
        XCTAssertNil(status.uploadChunkBytes)
    }

    func testStatusAdvertisesExactScreenPreview() throws {
        let data = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":16000,"uptime":4,"device":"X3","screenPreviewAvailable":true,"screenPreviewBytes":52342}"#.utf8)
        let status = try JSONDecoder().decode(CrossPointStatus.self, from: data)
        XCTAssertEqual(status.screenPreviewAvailable, true)
        XCTAssertEqual(status.screenPreviewBytes, 52_342)
    }

    func testScreenPreviewReassemblesBoundedChunks() async throws {
        var expected = Data([0x42, 0x4D])
        expected.append(Data((0 ..< 4_094).map { UInt8(truncatingIfNeeded: $0) }))
        ScreenPreviewURLProtocol.payload = expected
        ScreenPreviewURLProtocol.requestedOffsets = []
        defer {
            ScreenPreviewURLProtocol.payload = Data()
            ScreenPreviewURLProtocol.requestedOffsets = []
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScreenPreviewURLProtocol.self]
        let client = CrossPointClient(session: URLSession(configuration: configuration))

        let received = try await client.screenPreview(host: "reader.test", port: 80, expectedBytes: expected.count)
        XCTAssertEqual(received, expected)
        XCTAssertEqual(ScreenPreviewURLProtocol.requestedOffsets, [0, 1_024, 2_048, 3_072])
    }

    func testSubnetDiscoveryCoversSlash22AndStartsWithNeighbors() {
        let candidates = LocalReaderDiscovery.ipv4Candidates(
            address: 0xC0A8_443C, // 192.168.68.60
            netmask: 0xFFFF_FC00,
            limit: 2_048
        )
        XCTAssertEqual(candidates.prefix(2), ["192.168.68.59", "192.168.68.61"])
        XCTAssertTrue(candidates.contains("192.168.71.254"))
        XCTAssertFalse(candidates.contains("192.168.68.60"))
    }

    func testSubnetDiscoveryInterleavesOverlappingInterfaces() {
        let merged = LocalReaderDiscovery.interleaveCandidates([
            ["192.168.68.99", "192.168.68.101", "192.168.68.98"],
            ["192.168.68.59", "192.168.68.61", "192.168.68.58"],
            ["192.168.68.99", "192.168.68.102"],
        ])

        XCTAssertEqual(merged.prefix(6), [
            "192.168.68.99",
            "192.168.68.59",
            "192.168.68.101",
            "192.168.68.61",
            "192.168.68.102",
            "192.168.68.98",
        ])
        XCTAssertEqual(merged.filter { $0 == "192.168.68.99" }.count, 1)
    }

    func testParsesRequiredStatusAndIgnoresUnknownFields() throws {
        let status = try PocketDeviceStatus(
            record: "V=1;MODEL=X3;ID=89ABCDEF;FW=1.4.1;CAP=AP,HTTP,SD,COMMIT1;FUTURE=ignored"
        )
        XCTAssertEqual(status.protocolVersion, 1)
        XCTAssertEqual(status.model, "X3")
        XCTAssertEqual(status.deviceID, "89ABCDEF")
        XCTAssertEqual(status.capabilities, ["AP", "HTTP", "SD", "COMMIT1"])
    }

    func testRejectsDuplicateStatusFields() {
        XCTAssertThrowsError(try PocketDeviceStatus(record: "V=1;V=2;MODEL=X3;ID=A;CAP=AP"))
    }

    func testMapsBothSupportedHardwareModels() throws {
        XCTAssertEqual(PocketHardware(deviceName: "X3"), .x3)
        XCTAssertEqual(PocketHardware(deviceName: "Xteink X4"), .x4)
        XCTAssertNil(PocketHardware(deviceName: "X5"))

        let status = try PocketDeviceStatus(record: "V=1;MODEL=X4;ID=12345678;FW=2.0;CAP=AP,HTTP,SD,COMMIT1")
        XCTAssertEqual(PocketHardware(deviceName: status.model), .x4)
    }

    func testPublicHardwareNamesDescribeCompatibilityWithoutManufacturerBranding() {
        for hardware in PocketHardware.allCases {
            XCTAssertEqual(hardware.displayName, "\(hardware.rawValue)-compatible reader")
            XCTAssertFalse(hardware.displayName.localizedCaseInsensitiveContains("Xteink"))
            XCTAssertTrue(hardware.profileName.hasSuffix(" PROFILE"))
        }
    }

    @MainActor
    func testDemoModeIsExplicitAndLeavesNoConnectedReader() {
        let model = PocketModel()
        model.preferredHardware = .x4

        model.enterDemoMode()
        XCTAssertTrue(model.isDemoMode)
        XCTAssertEqual(model.hardware, .x4)
        XCTAssertEqual(model.readerStatus?.mode, "DEMO")
        XCTAssertNotNil(model.preferences)
        XCTAssertTrue(model.message.contains("disabled"))

        model.exitDemoMode()
        XCTAssertFalse(model.isDemoMode)
        XCTAssertNil(model.readerStatus)
        XCTAssertNil(model.preferences)
    }

    func testParsesHotspotLease() throws {
        let lease = try HotspotLease(record: "AP 12ABCDEF Pocket-89AB A1B2C3D4E5F6 192.168.4.1 80 81 300")
        XCTAssertEqual(lease.requestID, "12ABCDEF")
        XCTAssertEqual(lease.ssid, "Pocket-89AB")
        XCTAssertEqual(lease.passphrase, "A1B2C3D4E5F6")
        XCTAssertEqual(lease.webSocketPort, 81)
        XCTAssertEqual(lease.leaseSeconds, 300)
    }

    func testClassifiesPersistedHeapCrash() {
        let report = """
        CrossPoint version: 1.4.1-test

        Reset reason: panic

        Panic reason: abort() was called on core 0

        Last logs:
        [120] NEARBY started
        [130] HEAP pair: free=6004 largest=2420

        Stack memory:
        0x12345678: 0x00000000
        """
        let diagnostic = CrashDiagnostic(report: report)
        XCTAssertEqual(diagnostic.version, "1.4.1-test")
        XCTAssertEqual(diagnostic.resetReason, "panic")
        XCTAssertTrue(diagnostic.reason.contains("abort"))
        XCTAssertEqual(diagnostic.lastEvent, "[130] HEAP pair: free=6004 largest=2420")
        XCTAssertTrue(diagnostic.analysis.contains("memory pressure"))
    }

    func testClassifiesResetWithoutPanicMessage() {
        let report = """
        CrossPoint version: 1.4.1-test

        Reset reason: task watchdog

        Panic reason:

        Runtime breadcrumb: nearby:connected-awaiting-auth

        Last logs:
        [130] NEARBY ready heap=21000 largest=12000

        Stack memory:
        """
        let diagnostic = CrashDiagnostic(report: report)
        XCTAssertEqual(diagnostic.resetReason, "task watchdog")
        XCTAssertEqual(diagnostic.reason, "No panic message was captured.")
        XCTAssertEqual(diagnostic.breadcrumb, "nearby:connected-awaiting-auth")
        XCTAssertTrue(diagnostic.analysis.contains("watchdog"))
    }

    func testCrashArchiveDeduplicatesByContentHash() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let directory = fixture.base.appendingPathComponent("crash-reports", isDirectory: true)
        let report = "CrossPoint version: test\nReset reason: task watchdog\n"

        let first = try CrashReportArchive.store(report: report, device: "X3", directory: directory)
        let second = try CrashReportArchive.store(report: report, device: "X3", directory: directory)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), report)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testCopiesLearningPackToSDLayoutWithoutOverwriting() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("jp-n3-ko.pdl")
        try Data("learning-pack".utf8).write(to: source)

        let relative = try PocketModel.copyToSDOffMain(source: source, root: fixture.sd)
        XCTAssertEqual(relative, "/pocket-daily/learning/jp-n3-ko.pdl")
        XCTAssertEqual(
            try Data(contentsOf: fixture.sd.appendingPathComponent("pocket-daily/learning/jp-n3-ko.pdl")),
            Data("learning-pack".utf8)
        )
        XCTAssertThrowsError(try PocketModel.copyToSDOffMain(source: source, root: fixture.sd))
    }

    func testValidatesAndRoutesFontPackage() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("PocketSansWorld_12.cpfont")
        try Data([0x43, 0x50, 0x46, 0x4F, 0x4E, 0x54, 0x00, 0x00, 0x01]).write(to: source)

        let relative = try PocketModel.copyToSDOffMain(source: source, root: fixture.sd)
        XCTAssertEqual(relative, "/.fonts/PocketSansWorld/PocketSansWorld_12.cpfont")
    }

    func testValidatesCompatibleFirmwareImage() throws {
        let image = makeFirmwareImage()
        let metadata = try FirmwareImageValidator.validate(image)

        XCTAssertEqual(metadata.byteCount, image.count)
        XCTAssertEqual(metadata.version, "1.4.1-test")
    }

    func testRejectsFirmwareForAnotherChip() {
        var image = makeFirmwareImage()
        image[12] = 0

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .unsupportedChip)
        }
    }

    func testRejectsCorruptedFirmwareChecksum() {
        var image = makeFirmwareImage()
        let digestOffset = image.count - 32
        image[digestOffset - 1] ^= 0x01

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .checksumMismatch)
        }
    }

    func testRejectsCorruptedFirmwareDigest() {
        var image = makeFirmwareImage()
        image[image.count - 1] ^= 0x01

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .digestMismatch)
        }
    }

    func testRejectsUnidentifiedESP32Firmware() {
        let image = makeFirmwareImage(identity: "Unrelated application")

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .incompatibleProduct)
        }
    }

    func testValidatesCompatibleFirmwareWithoutAppendedDigest() throws {
        let image = makeFirmwareImage(hashAppended: false)
        XCTAssertEqual(try FirmwareImageValidator.validate(image).version, "1.4.1-test")
    }

    func testRejectsTruncatedFirmwareSegments() {
        var image = makeFirmwareImage()
        image.removeLast()

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .malformedSegments)
        }
    }

    func testSDCopyPublishesValidatedFirmware() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("update.bin")
        try makeFirmwareImage().write(to: source)

        XCTAssertEqual(try PocketModel.copyToSDOffMain(source: source, root: fixture.sd), "/update.bin")
        XCTAssertEqual(
            try Data(contentsOf: fixture.sd.appendingPathComponent("update.bin")),
            try Data(contentsOf: source)
        )
    }

    func testSDCopyRejectsInvalidFirmwareBeforePublication() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("update.bin")
        try Data(repeating: 0, count: FirmwareImageValidator.minimumSize).write(to: source)

        XCTAssertThrowsError(try PocketModel.copyToSDOffMain(source: source, root: fixture.sd))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sd.appendingPathComponent("update.bin").path))
    }

    private func temporaryFixture() throws -> (base: URL, sd: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sd = base.appendingPathComponent("SD", isDirectory: true)
        try FileManager.default.createDirectory(at: sd, withIntermediateDirectories: true)
        return (base, sd)
    }

    private func makeFirmwareImage(
        identity: String = "CrossPoint version: 1.4.1-test\0PocketNearbySync\0",
        hashAppended: Bool = true
    ) -> Data {
        var header = Data(repeating: 0, count: 24)
        header[0] = 0xE9
        header[1] = 1
        header[12] = 5
        header[23] = hashAppended ? 1 : 0

        var segment = Data(repeating: 0xA5, count: 64 * 1_024)
        writeUInt32(0xABCD_5432, to: &segment, at: 0)
        segment.replaceSubrange(128 ..< 128 + identity.utf8.count, with: identity.utf8)

        var segmentHeader = Data(repeating: 0, count: 8)
        writeUInt32(UInt32(segment.count), to: &segmentHeader, at: 4)

        var image = header
        image.append(segmentHeader)
        image.append(segment)

        let checksum = segment.reduce(UInt8(0xEF), ^)
        let paddedEnd = (image.count + 16) & ~15
        image.append(Data(repeating: 0, count: paddedEnd - image.count - 1))
        image.append(checksum)
        if hashAppended {
            image.append(contentsOf: SHA256.hash(data: image))
        }
        return image
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

private final class ScreenPreviewURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var payload = Data()
    nonisolated(unsafe) static var requestedOffsets: [Int] = []

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)
        let offset = components?.queryItems?.first(where: { $0.name == "offset" })?.value.flatMap(Int.init) ?? -1
        Self.requestedOffsets.append(offset)
        guard offset >= 0, offset < Self.payload.count else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        let end = min(offset + 1_024, Self.payload.count)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/octet-stream"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload.subdata(in: offset ..< end))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Resumable upload stream

/// A loopback stand-in for the reader's port-82 listener. It records the
/// request header, answers it with a scripted line, and answers again once the
/// scripted amount of payload has arrived.
private final class FakeUploadReader: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.upload.reader")
    private var connection: NWConnection?
    private var buffer = Data()
    private var headerHandled = false
    private var payloadHandled = false
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private(set) var header = ""
    private let expectedPayload: Int
    private let onHeader: @Sendable (String) -> Data?
    private let onPayload: @Sendable (Data) -> Data?

    init(
        expectedPayload: Int,
        onHeader: @escaping @Sendable (String) -> Data?,
        onPayload: @escaping @Sendable (Data) -> Data?
    ) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.expectedPayload = expectedPayload
        self.onHeader = onHeader
        self.onPayload = onPayload
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let continuation = self.readyContinuation else { return }
                switch state {
                case .ready:
                    self.readyContinuation = nil
                    continuation.resume(returning: self.listener.port?.rawValue ?? 0)
                case let .failed(error):
                    self.readyContinuation = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connection = connection
                connection.start(queue: self.queue)
                self.receive(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        connection?.cancel()
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.process(connection)
            }
            if error == nil, !isComplete { self.receive(connection) }
        }
    }

    private func process(_ connection: NWConnection) {
        if !headerHandled, let terminator = buffer.range(of: Data("\n\n".utf8)) {
            headerHandled = true
            header = String(decoding: buffer[buffer.startIndex ..< terminator.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex ..< terminator.upperBound)
            if let reply = onHeader(header) {
                connection.send(content: reply, completion: .contentProcessed { _ in })
            }
        }
        if headerHandled, !payloadHandled, buffer.count >= expectedPayload {
            payloadHandled = true
            if let reply = onPayload(buffer) {
                connection.send(content: reply, completion: .contentProcessed { _ in })
            }
        }
    }
}

extension NearbySyncProtocolTests {
    private func makePayloadFile(bytes: Int) throws -> (URL, Data) {
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0 ..< bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-stream-\(UUID().uuidString).bin")
        try payload.write(to: url)
        return (url, payload)
    }

    func testStatusAdvertisesResumableUploadStream() throws {
        let data = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":16000,"uptime":4,"device":"X3","uploadStreamPort":82,"uploadStreamResume":true}"#.utf8)
        let status = try JSONDecoder().decode(CrossPointStatus.self, from: data)
        XCTAssertEqual(status.uploadStreamResume, true)

        let legacy = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":16000,"uptime":4,"device":"X3","uploadStreamPort":82}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CrossPointStatus.self, from: legacy).uploadStreamResume)
    }

    func testDiagnosticsSkippedOnLowHeapReader() throws {
        XCTAssertFalse(ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: 6_996, readerSaysAffordable: nil))
        XCTAssertTrue(ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: 16_312, readerSaysAffordable: nil))
        // A reader that measures itself wins over the app-side heuristic.
        XCTAssertTrue(ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: 6_996, readerSaysAffordable: true))
        XCTAssertFalse(ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: 32_000, readerSaysAffordable: false))

        let data = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":6996,"uptime":4,"device":"X3","diagnosticsAffordable":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CrossPointStatus.self, from: data).diagnosticsAffordable, false)
    }

    func testFirmwareInstallCheckComparesStagedWithRunning() {
        let staged = "1.4.1-dev-main-551001f5-wacf0cb93"
        XCTAssertEqual(
            FirmwareInstallCheck.evaluate(readerVersion: staged, staged: staged),
            .installed(staged)
        )
        XCTAssertEqual(
            FirmwareInstallCheck.evaluate(readerVersion: "1.4.1-dev-main-551001f5-w6799521f", staged: staged),
            .stillPending(running: "1.4.1-dev-main-551001f5-w6799521f", staged: staged)
        )
        XCTAssertEqual(FirmwareInstallCheck.evaluate(readerVersion: staged, staged: nil), .nothingStaged)
        XCTAssertEqual(FirmwareInstallCheck.evaluate(readerVersion: staged, staged: ""), .nothingStaged)
        // Whitespace from either side must not defeat the comparison.
        XCTAssertEqual(FirmwareInstallCheck.evaluate(readerVersion: staged + "\n", staged: " " + staged), .installed(staged))
    }

    func testStreamHeaderAddsResumeOnlyWhenRequested() {
        let fresh = String(decoding: PocketStreamUploader.header(path: "/.pocket-a.part", size: 12, resume: false), as: UTF8.self)
        XCTAssertEqual(fresh, "POCKET-PUT/1\nPath: /.pocket-a.part\nSize: 12\n\n")
        let resumed = String(decoding: PocketStreamUploader.header(path: "/.pocket-a.part", size: 12, resume: true), as: UTF8.self)
        XCTAssertEqual(resumed, "POCKET-PUT/1\nPath: /.pocket-a.part\nSize: 12\nResume: 1\n\n")
    }

    func testStreamReplyParsing() {
        XCTAssertEqual(PocketStreamUploader.Reply.parse("OK 2621440 CBF43926\n"), .ok(size: 2_621_440, crc32: 0xCBF4_3926))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("RESUME 65536"), .resume(offset: 65_536))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("ERROR SD write failed"), .error("SD write failed"))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("OK 12"), .invalid("OK 12"))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("RESUME x"), .invalid("RESUME x"))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("READY"), .invalid("READY"))
    }

    func testRetryPolicyRetriesTransportFailuresOnly() {
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.disconnected, attempt: 1))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.stalled, attempt: 2))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(URLError(.networkConnectionLost), attempt: 1))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(NWError.posix(.ECONNRESET), attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.readerRejected("SD write failed"), attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.verificationFailed, attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.timedOut, attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(CancellationError(), attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.disconnected, attempt: 3))
        XCTAssertEqual(UploadRetryPolicy.delay(afterAttempt: 1), .seconds(1))
        XCTAssertEqual(UploadRetryPolicy.delay(afterAttempt: 9), .seconds(3))
    }

    func testStreamUploaderResumesFromReaderPrefix() async throws {
        let (url, payload) = try makePayloadFile(bytes: 100_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let prefix = 40_000
        var whole = CRC32()
        whole.update(payload)
        let expectedCRC = whole.finalized

        let reader = try FakeUploadReader(
            expectedPayload: payload.count - prefix,
            onHeader: { _ in Data("RESUME \(prefix)\n".utf8) },
            onPayload: { received in
                received == payload[prefix...] ? Data("OK \(payload.count) \(String(format: "%08X", expectedCRC))\n".utf8)
                                               : Data("ERROR payload mismatch\n".utf8)
            }
        )
        let port = try await reader.start()
        defer { reader.stop() }

        let firstProgress = LockedBox<Int64?>(nil)
        let uploader = try PocketStreamUploader(
            fileURL: url, host: "127.0.0.1", port: Int(port), remotePath: "/.pocket-test.part",
            total: Int64(payload.count), resume: true
        ) { sent, _ in firstProgress.setIfNil(sent) }
        let crc = try await uploader.upload()

        XCTAssertEqual(crc, expectedCRC)
        XCTAssertEqual(firstProgress.value, Int64(prefix))
        XCTAssertTrue(reader.header.hasSuffix("Resume: 1"), reader.header)
    }

    func testStreamUploaderSurfacesEarlyReaderError() async throws {
        let (url, payload) = try makePayloadFile(bytes: 200_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try FakeUploadReader(
            expectedPayload: .max,
            onHeader: { _ in Data("ERROR SD write failed\n".utf8) },
            onPayload: { _ in nil }
        )
        let port = try await reader.start()
        defer { reader.stop() }

        let uploader = try PocketStreamUploader(
            fileURL: url, host: "127.0.0.1", port: Int(port), remotePath: "/.pocket-test.part",
            total: Int64(payload.count)
        ) { _, _ in }
        do {
            _ = try await uploader.upload()
            XCTFail("the reader's rejection must abort the transfer")
        } catch let error as PocketStreamUploader.StreamError {
            XCTAssertEqual(error, .readerRejected("SD write failed"))
            XCTAssertFalse(UploadRetryPolicy.shouldRetry(error, attempt: 1))
        }
        XCTAssertFalse(reader.header.contains("Resume"))
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func setIfNil<Wrapped>(_ newValue: Wrapped) where Value == Wrapped? {
        lock.withLock { if stored == nil { stored = newValue } }
    }
}
