import CoreBluetooth
import XCTest
@testable import Pocket

final class NearbySyncProtocolTests: XCTestCase {
    func testConnectionHeartbeatRequiresConsecutiveFailures() {
        var heartbeat = ConnectionHeartbeat()
        XCTAssertFalse(heartbeat.recordFailure())
        XCTAssertFalse(heartbeat.recordFailure())
        heartbeat.recordSuccess()
        XCTAssertEqual(heartbeat.consecutiveFailures, 0)
        XCTAssertFalse(heartbeat.recordFailure())
        XCTAssertFalse(heartbeat.recordFailure())
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

    private func temporaryFixture() throws -> (base: URL, sd: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sd = base.appendingPathComponent("SD", isDirectory: true)
        try FileManager.default.createDirectory(at: sd, withIntermediateDirectories: true)
        return (base, sd)
    }
}
