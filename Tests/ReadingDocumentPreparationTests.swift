import XCTest
@testable import Pocket

@MainActor
final class ReadingDocumentPreparationTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testEPUBIsPreparedOfflineAndSurvivesExportRemovalAndModelReload() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await ReadingDocumentPreparation.create(title: "읽을 글", text: "첫 문단\n\n둘째 문단", format: .epub, directory: root)
        let expected = try Data(contentsOf: url)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO())
        try await model.prepareGeneratedReadingFile(url)
        let item = try XCTUnwrap(model.preparedTransfers.first { $0.filename == url.lastPathComponent })
        defer { try? FileManager.default.removeItem(at: TransferPreparation.file(item).deletingLastPathComponent()) }
        XCTAssertNil(model.readerStatus)
        XCTAssertFalse(model.isWorking)
        try await ReadingDocumentPreparation.removeExport(at: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: TransferPreparation.file(item)), expected)
        let reloaded = PocketModel(discoveryIO: EmptyReaderDiscoveryIO())
        XCTAssertTrue(reloaded.preparedTransfers.contains(item))
        XCTAssertNil(item.firmwareVersion)
    }

    func testPlainTextOptionKeepsExistingContent() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await ReadingDocumentPreparation.create(title: "Notes", text: "\nOne\nTwo\n", format: .text, directory: root)
        XCTAssertEqual(url.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Notes\n\nOne\nTwo\n")
        try await ReadingDocumentPreparation.removeExport(at: url)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testBlankTitleIsUsableButEmptyContentFailsWithoutFiles() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await ReadingDocumentPreparation.create(title: "", text: "Words", format: .epub, directory: root)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Reading-"))
        try await ReadingDocumentPreparation.removeExport(at: url)
        do {
            _ = try await ReadingDocumentPreparation.create(title: "Title", text: " \n", format: .epub, directory: root)
            XCTFail("Expected empty input rejection")
        } catch { XCTAssertEqual(error as? EPUBExportError, .emptyContent) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testQueueFailureIsReportedAndSourceRemainsAvailableForRetry() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await ReadingDocumentPreparation.create(title: "Retry", text: "Keep this", format: .epub, directory: root)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), localFiles: .init(prepare: { _ in
            throw CocoaError(.fileWriteOutOfSpace)
        }))
        let before = model.preparedTransfers
        do {
            try await model.prepareGeneratedReadingFile(url)
            XCTFail("Must not report failed copy as prepared")
        } catch {
            XCTAssertTrue(error is PocketModel.ReadingPreparationFailure)
        }
        XCTAssertEqual(model.preparedTransfers, before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(model.messageTone, .failure)
    }

    func testDemoAndBackgroundRejectPreparation() async throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await ReadingDocumentPreparation.create(title: "Local", text: "Content", format: .epub, directory: root)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), localFiles: .init(prepare: { _ in
            XCTFail("Unavailable model must not touch local files")
            throw CocoaError(.fileReadUnknown)
        }))
        model.enterDemoMode()
        do { try await model.prepareGeneratedReadingFile(url); XCTFail("Demo must reject") }
        catch { XCTAssertTrue(error is PocketModel.ReadingPreparationFailure) }
        model.exitDemoMode()
        model.pauseForBackground()
        do { try await model.prepareGeneratedReadingFile(url); XCTFail("Background must reject") }
        catch { XCTAssertTrue(error is PocketModel.ReadingPreparationFailure) }
    }
}
