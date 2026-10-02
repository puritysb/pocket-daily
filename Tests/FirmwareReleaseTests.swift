import XCTest
@testable import Pocket

/// "Update reader" downloads only the official latest release, only on
/// request, never in demo mode, and never offers what the reader already runs.
final class FirmwareReleaseTests: XCTestCase {
    func testProductStatusCarriesAnIndependentBaseline() throws {
        let status = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.0.0-beta.1","firmwareLineage":1,"crossPointBase":"1.6.5","device":"X3","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        XCTAssertEqual(status.firmwareLineage, 1)
        XCTAssertEqual(status.crossPointBase, "1.6.5")
    }

    private func document(tag: String = "pocket-v1.0.0", name: String = "firmware.bin", size: Int = 5_947_312,
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
        XCTAssertEqual(release.version, "1.0.0")
        XCTAssertEqual(release.byteCount, 5_947_312)
        XCTAssertEqual(release.downloadURL.absoluteString,
                       "https://github.com/puritysb/pocket-daily-firmware/releases/download/pocket-v1.0.0/firmware.bin")
        XCTAssertEqual(try FirmwareReleaseSource.parse(document(tag: "pocket-v2.0.1")).version, "2.0.1")
    }

    func testReleasePublicationDateIsOptionalAndNotAnInstallDate() throws {
        let json = String(decoding: document(), as: UTF8.self)
        let dated = json.replacingOccurrences(of: "\"draft\":false", with: "\"published_at\":\"2026-09-26T08:00:00Z\",\"draft\":false")
        XCTAssertEqual(try FirmwareReleaseSource.parse(Data(dated.utf8)).publishedAt,
                       ISO8601DateFormatter().date(from: "2026-09-26T08:00:00Z"))
        XCTAssertNil(try FirmwareReleaseSource.parse(document()).publishedAt)
        XCTAssertNil(try FirmwareReleaseSource.parse(Data(dated.replacingOccurrences(of: "2026-09-26T08:00:00Z", with: "invalid").utf8)).publishedAt)
    }

    @MainActor func testLaunchChecksOnceWithoutAReaderAndNeverDownloads() async {
        let calls = Counter()
        let release = FirmwareRelease(version: "1.8.0", downloadURL: URL(string: "https://example.invalid")!, byteCount: 1)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), releaseSource: .init(
            latest: { await calls.add("latest"); return release },
            download: { _, _ in await calls.add("download"); throw FirmwareReleaseError.unavailable }))
        await model.checkFirmwareAtLaunch()
        await model.checkFirmwareAtLaunch()
        XCTAssertEqual(model.latestFirmwareRelease, release)
        XCTAssertFalse(model.firmwareUpdateAvailable)
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["latest"])
        model.readerStatus = try? JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.7.0","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        XCTAssertTrue(model.firmwareUpdateAvailable)
    }

    @MainActor func testDemoSkipsLaunchCheckAndFailureNeedsExplicitRetry() async {
        let calls = Counter()
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), releaseSource: .init(
            latest: { await calls.add("latest"); throw FirmwareReleaseError.unavailable }))
        model.enterDemoMode()
        await model.checkFirmwareAtLaunch()
        var recorded = await calls.values
        XCTAssertEqual(recorded, [])
        model.exitDemoMode()
        await model.checkFirmwareAtLaunch()
        await model.checkFirmwareAtLaunch()
        XCTAssertNotNil(model.firmwareCheckError)
        await model.checkFirmwareRelease()
        recorded = await calls.values
        XCTAssertEqual(recorded, ["latest", "latest"])
        XCTAssertFalse(model.isCheckingFirmware)
        XCTAssertNil(model.latestFirmwareRelease)
    }

    @MainActor func testUpdateCheckCanBeCancelledAndRetried() async throws {
        let calls = Counter()
        let release = try FirmwareReleaseSource.parse(document())
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), releaseSource: .init(latest: {
            await calls.add("latest")
            if await calls.values.count == 1 { try await Task.sleep(for: .seconds(30)) }
            return release
        }))
        let checking = Task { await model.checkFirmwareRelease() }
        for _ in 0..<100 where !model.isCheckingFirmware { try await Task.sleep(for: .milliseconds(5)) }
        model.cancelFirmwareCheck()
        await checking.value
        XCTAssertFalse(model.isCheckingFirmware)
        XCTAssertNil(model.latestFirmwareRelease)
        XCTAssertEqual(model.firmwareCheckError, "Update check cancelled. Try again when ready.")
        await model.checkFirmwareRelease()
        XCTAssertEqual(model.latestFirmwareRelease, release)
        XCTAssertNil(model.firmwareCheckError)
    }

    func testRejectsUnsafeOrMalformedReleases() {
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(url: "https://example.com/firmware.bin"))) {
            XCTAssertEqual($0 as? FirmwareReleaseError, .untrustedLocation)
        }
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(
            url: "https://github.com/puritysb/pocket-daily-firmware/releases/download/v1.6.6/firmware.bin"))) {
            XCTAssertEqual($0 as? FirmwareReleaseError, .untrustedLocation)
        }
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(
            url: "http://github.com/puritysb/pocket-daily-firmware/releases/download/pocket-v1.0.0/firmware.bin")))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(name: "other.bin"))) {
            XCTAssertEqual($0 as? FirmwareReleaseError, .malformed)
        }
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(size: 7_000_000))) {
            XCTAssertEqual($0 as? FirmwareReleaseError, .tooLarge(7_000_000))
        }
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(size: 0)))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(tag: "nightly")))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(tag: "v1.6.6")))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(tag: "v1.7.0-beta.4", prerelease: true),
                                                              allowingPrerelease: true))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(prerelease: true)))
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(Data("{}".utf8)))
    }

    func testOnlyNewerReleasesAreOffered() {
        XCTAssertTrue(FirmwareReleaseSource.isNewer("1.0.0", than: "1.6.6"))
        XCTAssertTrue(FirmwareReleaseSource.isNewer("1.0.0", than: "1.7.0-beta.4"))
        XCTAssertTrue(FirmwareReleaseSource.isNewer("1.0.0", than: "1.7.0-dev-main-abcd"))
        XCTAssertTrue(FirmwareReleaseSource.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(FirmwareReleaseSource.isNewer("1.0.0", than: "1.0.0"))
        XCTAssertFalse(FirmwareReleaseSource.isNewer("1.0.0", than: "1.6.6", lineage: 1))
        XCTAssertFalse(FirmwareReleaseSource.isNewer("1.0.0", than: "1.7.0", lineage: 1))
        XCTAssertFalse(FirmwareReleaseSource.isNewer("1.0.0", than: "1.0.1"))
        XCTAssertFalse(FirmwareReleaseSource.isNewer("1.0.0", than: "weird"))
    }

    private func list(_ entries: [(tag: String, prerelease: Bool, draft: Bool)]) -> Data {
        let items = entries.map { entry in
            """
            {"tag_name":"\(entry.tag)","draft":\(entry.draft),"prerelease":\(entry.prerelease),"assets":[
              {"name":"firmware.bin","size":5999200,
               "browser_download_url":"https://github.com/puritysb/pocket-daily-firmware/releases/download/\(entry.tag)/firmware.bin"}]}
            """
        }
        return Data("[\(items.joined(separator: ","))]".utf8)
    }

    func testStableChannelRefusesPrereleasesButBetaAcceptsThem() throws {
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(tag: "pocket-v0.2.0-beta.1", prerelease: true)))
        let beta = try FirmwareReleaseSource.parse(document(tag: "pocket-v0.2.0-beta.1", prerelease: true),
                                                   allowingPrerelease: true)
        XCTAssertEqual(beta.version, "0.2.0-beta.1")
        XCTAssertTrue(beta.isPrerelease)
    }

    /// Below 1.0 is the beta series, published as normal releases so GitHub's
    /// latest endpoint (the reader's own updater) returns them.
    func testZeroSeriesIsANormalReleaseLabelledBeta() throws {
        let release = try FirmwareReleaseSource.parse(document(tag: "pocket-v0.1.0"))
        XCTAssertEqual(release.version, "0.1.0")
        XCTAssertFalse(release.isPrerelease)
        XCTAssertTrue(release.isBeta)
        XCTAssertFalse(try FirmwareReleaseSource.parse(document(tag: "pocket-v1.0.0")).isBeta)
        XCTAssertThrowsError(try FirmwareReleaseSource.parse(document(tag: "pocket-v1.0.0-beta.1", prerelease: true),
                                                             allowingPrerelease: true),
                             "Pre-reset 1.0.0 betas are retired")
    }

    /// The version reset: readers on lineage-1 1.0.0 betas and dev builds take 0.x
    /// once; from lineage 2 on versions compare normally.
    func testReadersFromBeforeTheResetAreOfferedZeroSeries() {
        for running in ["1.0.0-beta.1", "1.0.0-dev-feat-reader-file-download-f6e3f243-w3ec1f022"] {
            XCTAssertTrue(FirmwareReleaseSource.shouldOffer("0.1.0", to: running, channel: .stable, lineage: 1), running)
            XCTAssertTrue(FirmwareReleaseSource.shouldOffer("0.1.0", to: running, channel: .beta, lineage: 1), running)
        }
        XCTAssertTrue(FirmwareReleaseSource.shouldOffer("0.1.1", to: "0.1.0", channel: .stable, lineage: 2))
        XCTAssertFalse(FirmwareReleaseSource.shouldOffer("0.1.0", to: "0.1.0", channel: .stable, lineage: 2))
        XCTAssertFalse(FirmwareReleaseSource.shouldOffer("0.9.0", to: "1.0.0", channel: .stable, lineage: 2))
        XCTAssertFalse(FirmwareReleaseSource.shouldOffer("0.9.0", to: "1.0.0-dev-main-abcd", channel: .beta, lineage: 2),
                       "A dev build toward the real 1.0.0 is not migrated back")
        XCTAssertFalse(FirmwareReleaseSource.shouldOffer("0.1.0", to: "1.0.0", channel: .stable, lineage: 1),
                       "Only pre-reset betas and dev builds migrate")
    }

    /// The beta channel takes the newest published release, skipping drafts
    /// and entries without an official image.
    func testBetaChannelPicksTheNewestUsableRelease() throws {
        let newest = try FirmwareReleaseSource.parseNewest(list([
            (tag: "pocket-v0.2.0-beta.2", prerelease: true, draft: true),
            (tag: "nightly", prerelease: true, draft: false),
            (tag: "pocket-v0.2.0-beta.1", prerelease: true, draft: false),
            (tag: "pocket-v0.1.0", prerelease: false, draft: false),
            (tag: "v1.6.6", prerelease: false, draft: false),
        ]))
        XCTAssertEqual(newest.version, "0.2.0-beta.1")
        XCTAssertTrue(newest.isPrerelease)
        let afterRetired = try FirmwareReleaseSource.parseNewest(list([
            (tag: "pocket-v1.0.0-beta.1", prerelease: true, draft: false),
            (tag: "pocket-v0.1.0", prerelease: false, draft: false),
        ]))
        XCTAssertEqual(afterRetired.version, "0.1.0", "A retired pre-reset beta is skipped")
        XCTAssertThrowsError(try FirmwareReleaseSource.parseNewest(list([(tag: "v1.6.6", prerelease: false, draft: false)])))
        XCTAssertThrowsError(try FirmwareReleaseSource.parseNewest(list([(tag: "nightly", prerelease: true, draft: false)])))
        XCTAssertThrowsError(try FirmwareReleaseSource.parseNewest(Data("[]".utf8)))
        XCTAssertThrowsError(try FirmwareReleaseSource.parseNewest(document()))
    }

    func testBetaChannelOffersNewProductBuildsAndMigratesHistoricalReaders() {
        let dev = "0.2.0-dev-main-3de13206-wafd75b32"
        XCTAssertTrue(FirmwareReleaseSource.shouldOffer("0.2.0-beta.1", to: dev, channel: .beta, lineage: 2))
        XCTAssertTrue(FirmwareReleaseSource.shouldOffer("0.2.0", to: "0.2.0-beta.1", channel: .beta, lineage: 2))
        XCTAssertTrue(FirmwareReleaseSource.shouldOffer("0.2.1-beta.1", to: "0.2.0", channel: .beta, lineage: 2))
        XCTAssertTrue(FirmwareReleaseSource.shouldOffer("0.1.0", to: "1.6.6", channel: .beta))
        XCTAssertTrue(FirmwareReleaseSource.shouldOffer("0.1.0", to: "1.7.0-beta.4", channel: .beta))
        XCTAssertFalse(FirmwareReleaseSource.shouldOffer("0.2.0-beta.1", to: "0.2.0-beta.1", channel: .beta, lineage: 2))
        XCTAssertFalse(FirmwareReleaseSource.shouldOffer("0.1.0", to: "1.7.0", channel: .beta, lineage: 1))
        XCTAssertFalse(FirmwareReleaseSource.shouldOffer("0.2.0-beta.1", to: "weird", channel: .beta))
        XCTAssertFalse(FirmwareReleaseSource.shouldOffer("0.2.0-beta.1", to: dev, channel: .stable, lineage: 2))
        XCTAssertTrue(FirmwareReleaseSource.shouldOffer("0.1.0", to: "1.6.6", channel: .stable))
    }

    @MainActor func testBetaReleaseIsDownloadedForADevelopmentReader() async throws {
        let release = FirmwareRelease(version: "0.2.0-beta.1", downloadURL: URL(string: "https://example.invalid")!,
                                      byteCount: 1, isPrerelease: true)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("beta-firmware.bin")
        let operations = PocketModel.ReleaseOperations(latest: { release }, download: { _, _ in file }, channel: .beta)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), releaseSource: operations)
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.7.0-dev-main-3de13206-wafd75b32","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        let result = await model.downloadLatestFirmware()
        XCTAssertEqual(result?.version, "0.2.0-beta.1")
        XCTAssertEqual(result?.file, file)

        let stable = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(),
                                 releaseSource: .init(latest: { release }, download: { _, _ in file }, channel: .stable))
        stable.readerStatus = model.readerStatus
        let refused = await stable.downloadLatestFirmware()
        XCTAssertNil(refused)
    }

    @MainActor func testDemoAndUpToDateReadersDownloadNothing() async throws {
        let calls = Counter()
        let release = FirmwareRelease(version: "1.0.0", downloadURL: URL(string: "https://example.invalid")!,
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
            #"{"version":"1.0.0","firmwareLineage":1,"device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        XCTAssertTrue(model.canUpdateReader)
        let upToDate = await model.downloadLatestFirmware()
        XCTAssertNil(upToDate)
        XCTAssertTrue(model.message.contains("up to date"))
        XCTAssertEqual(model.readerUpdateState, .idle)
        let recorded = await calls.values
        XCTAssertEqual(recorded, ["latest"])
    }

    @MainActor func testCancellingFirmwareDownloadLeavesNoQueueOrReaderTransfer() async throws {
        let release = FirmwareRelease(version: "1.8.0", downloadURL: URL(string: "https://example.invalid")!, byteCount: 1)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), releaseSource: .init(
            latest: { release }, download: { _, _ in
                try await Task.sleep(for: .seconds(20))
                throw FirmwareReleaseError.unavailable
            }))
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.7.0","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        let before = model.preparedTransfers
        let task = Task { await model.downloadLatestFirmware() }
        for _ in 0..<100 where model.readerUpdateState != .downloading("1.8.0") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.readerUpdateState, .downloading("1.8.0"))
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(model.readerUpdateState, .idle)
        XCTAssertEqual(model.preparedTransfers, before)
        XCTAssertFalse(model.isTransferring)
        XCTAssertEqual(model.messageTone, .pending)
    }

    @MainActor func testCancelDuringPreparationCannotSendAndRemovesPreparedCopy() async throws {
        let downloadFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: downloadFolder, withIntermediateDirectories: true)
        let download = downloadFolder.appendingPathComponent("firmware.bin")
        try Data("fixture".utf8).write(to: download)
        let item = PreparedTransfer(id: UUID(), filename: "firmware.bin", firmwareVersion: "1.8.0", readerID: nil)
        let preparedFolder = TransferPreparation.file(item).deletingLastPathComponent()
        defer {
            try? FileManager.default.removeItem(at: downloadFolder)
            try? FileManager.default.removeItem(at: preparedFolder)
        }
        let release = FirmwareRelease(version: "1.8.0", downloadURL: URL(string: "https://example.invalid")!, byteCount: 7)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), localFiles: .init(prepare: { _ in
            try await Task.sleep(for: .milliseconds(100))
            try FileManager.default.createDirectory(at: preparedFolder, withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: TransferPreparation.file(item))
            return item
        }), releaseSource: .init(latest: { release }, download: { _, _ in download }))
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.7.0","device":"X3","deviceID":"5B09AF70","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
        let task = Task { await model.updateFirmware() }
        for _ in 0..<100 where !model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.isWorking)
        task.cancel()
        await task.value
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.preparedTransfers.contains { $0.id == item.id })
        XCTAssertFalse(model.isTransferring)
        XCTAssertFalse(FileManager.default.fileExists(atPath: preparedFolder.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadFolder.path))
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
