import XCTest
@testable import Pocket

/// "Update reader" downloads only the official latest release, only on
/// request, never in demo mode, and never offers what the reader already runs.
final class FirmwareReleaseTests: XCTestCase {
    private func document(tag: String = "v1.7.0", name: String = "firmware.bin", size: Int = 5_947_312,
                          url: String? = nil, prerelease: Bool = false) -> Data {
        let link = url ?? "https://github.com/puritysb/pocket-daily-firmware/releases/download/\(tag)/\(name)"
        return Data("""
        {"tag_name":"\(tag)","draft":false,"prerelease":\(prerelease),"assets":[
          {"name":"bootloader.bin","size":20000,"browser_download_url":"https://github.com/puritysb/pocket-daily-firmware/releases/download/\(tag)/bootloader.bin"},
          {"name":"\(name)","size":\(size),"browser_download_url":"\(link)"}]}
        """.utf8)
    }

    func testParsesTheOfficialFirmwareAsset() throws {
        let release = try FirmwareReleaseSource.parse(document())
        XCTAssertEqual(release.version, "1.7.0")
        XCTAssertEqual(release.byteCount, 5_947_312)
        XCTAssertEqual(release.downloadURL.absoluteString,
                       "https://github.com/puritysb/pocket-daily-firmware/releases/download/v1.7.0/firmware.bin")
        XCTAssertEqual(try FirmwareReleaseSource.parse(document(tag: "2.0.1")).version, "2.0.1")
    }

    func testRejectsUnsafeOrMalformedReleases() {
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(url: "https://example.com/firmware.bin"))) {
            XCTAssertEqual($0 as? FirmwareReleaseError, .untrustedLocation)
        }
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(
            url: "http://github.com/puritysb/pocket-daily-firmware/releases/download/v1.7.0/firmware.bin")))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(name: "other.bin"))) {
            XCTAssertEqual($0 as? FirmwareReleaseError, .malformed)
        }
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(size: 7_000_000))) {
            XCTAssertEqual($0 as? FirmwareReleaseError, .tooLarge(7_000_000))
        }
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(size: 0)))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(tag: "nightly")))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(prerelease: true)))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(Data("{}".utf8)))
    }

    func testOnlyNewerReleasesAreOffered() {
        XCTAssertTrue(FirmwareReleaseSource.isNewer("1.7.0", than: "1.6.6"))
        XCTAssertTrue(FirmwareReleaseSource.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(FirmwareReleaseSource.isNewer("1.7.0", than: "1.7.0"))
        XCTAssertFalse(FirmwareReleaseSource.isNewer("1.7.0", than: "1.7.0-dev-main-47a363f8-w1"))
        XCTAssertFalse(FirmwareReleaseSource.isNewer("1.6.6", than: "1.7.0"))
        XCTAssertFalse(FirmwareReleaseSource.isNewer("1.7.0", than: "weird"))
    }

    @MainActor func testDemoAndUpToDateReadersDownloadNothing() async throws {
        let calls = Counter()
        let release = FirmwareRelease(version: "1.7.0", downloadURL: URL(string: "https://example.invalid")!,
                                      byteCount: 1)
        let operations = PocketModel.ReleaseOperations(
            latest: { await calls.add("latest"); return release },
            download: { _, _ in await calls.add("download"); throw FirmwareReleaseError.unavailable })
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), releaseSource: operations)

        model.enterDemoMode()
        XCTAssertFalse(model.canUpdateReader)
        let demoResult = await model.downloadLatestFirmware()
        XCTAssertNil(demoResult)
        model.exitDemoMode()

        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.7.0","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        XCTAssertTrue(model.canUpdateReader)
        let upToDate = await model.downloadLatestFirmware()
        XCTAssertNil(upToDate)
        XCTAssertTrue(model.message.contains("up to date"))
        XCTAssertEqual(model.readerUpdateState, .idle)
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["latest"])
    }

    @MainActor func testDownloadFailureIsReportedAndLeavesNothingPending() async throws {
        let release = FirmwareRelease(version: "1.8.0", downloadURL: URL(string: "https://example.invalid")!,
                                      byteCount: 1)
        let operations = PocketModel.ReleaseOperations(
            latest: { release },
            download: { _, _ in throw FirmwareReleaseError.unavailable })
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), releaseSource: operations)
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.7.0","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        let result = await model.downloadLatestFirmware()
        XCTAssertNil(result)
        XCTAssertEqual(model.messageTone, .failure)
        XCTAssertTrue(model.message.contains("Couldn't reach"))
        XCTAssertEqual(model.readerUpdateState, .idle)
    }
}

private actor Counter {
    private(set) var values: [String] = []
    func add(_ value: String) { values.append(value) }
}
