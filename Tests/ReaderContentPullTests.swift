import CryptoKit
import XCTest
@testable import Pocket

/// Loading the reader's cards back (sibling docs/content-read-v1.md): strict
/// decoders for what the app writes, and end-to-end verification of a read.
final class ReaderContentPullTests: XCTestCase {
    private let image = Data("P4\n8 1\n".utf8) + Data([0x81])

    private func sampleDraft() -> ContentDraft {
        ContentDraft(cards: [
            ContentCard(id: "morning-1", title: "오늘", question: "한 줄 읽기\nRead one line.",
                        context: "가볍게 시작하세요.", imagePath: "sun.pbm", layout: .sideBySide),
            ContentCard(id: "b", title: "Second", question: "Text"),
        ], images: ["sun.pbm": image])
    }

    /// The published revision as a reader stores it: manifest plus files.
    private func published(_ draft: ContentDraft) throws -> (revision: String, files: [String: Data]) {
        let revision = try draft.revision()
        var files = ["manifest.pdcm": revision.manifest]
        for asset in revision.files { files[asset.path] = asset.data }
        return (revision.revision, files)
    }

    /// A reader that answers like `GET /api/pocket/v1/content/file`.
    private func reader(_ files: [String: Data], chunk: Int = 4096) -> (String, Int) async throws -> Data {
        { name, offset in
            guard let data = files[name] else { throw URLError(.fileDoesNotExist) }
            guard offset < data.count else { throw URLError(.badServerResponse) }
            return data.subdata(in: offset..<min(data.count, offset + chunk))
        }
    }

    func testManifestDecodesOnlyCanonicalBytes() throws {
        let golden = Data(hex: "5044434d01001000010001007c00000001000000050000002cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824612e636172640000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000059feb63f")
        let decoded = try ContentManifest.decode(golden)
        XCTAssertEqual(decoded.files.map(\.path), ["a.card"])
        XCTAssertEqual(decoded.files.first?.bytes, 5)
        XCTAssertEqual(decoded.requiredCapabilities, 1)

        let manifest = try sampleDraft().revision().manifest
        let roundTrip = try ContentManifest.decode(manifest)
        XCTAssertEqual(roundTrip.requiredCapabilities, 7)
        XCTAssertEqual(try ContentManifest.encode(roundTrip.files, cardLayout: true), manifest)

        var flipped = manifest
        flipped[30] ^= 1
        XCTAssertThrowsError(try ContentManifest.decode(flipped), "CRC")
        XCTAssertThrowsError(try ContentManifest.decode(manifest.dropLast()), "truncated")
        var layoutless = manifest
        layoutless[10] = 3
        XCTAssertThrowsError(try ContentManifest.decode(layoutless), "capability bits must match")
        XCTAssertThrowsError(try ContentManifest.decode(Data("PDCM".utf8)))
    }

    func testCardDecodesTheFirmwareGoldenAndRejectsNonCanonicalBytes() throws {
        let golden = ContentCard(id: "morning-1", title: "오늘", question: "한 줄 읽기\nRead one line.",
                                 context: "가볍게 시작하세요.", imagePath: "sun.pbm")
        let bytes = try golden.encoded()
        XCTAssertEqual(ContentManifest.revision(of: bytes), "dc6d7e86f5ac0a6114fc6f49ea62572874a355e0a250e01b663508a805d6e1dc")
        XCTAssertEqual(try ContentCard.decode(bytes), golden)
        for layout in ContentCard.Layout.allCases {
            var card = golden
            card.layout = layout
            XCTAssertEqual(try ContentCard.decode(try card.encoded()), card)
        }
        var badCRC = bytes
        badCRC[511] ^= 1
        XCTAssertThrowsError(try ContentCard.decode(badCRC))
        var padding = bytes
        padding[60] = 0x41 // after the title's NUL: non-zero padding
        XCTAssertThrowsError(try ContentCard.decode(padding))
        XCTAssertThrowsError(try ContentCard.decode(bytes.prefix(511)))
    }

    func testReaderCardsComeBackExactlyAcrossChunks() async throws {
        let draft = sampleDraft()
        let (revision, files) = try published(draft)
        for chunk in [7, 100, 4096] {
            let pulled = try await ReaderContentPull.draft(revision: revision, read: reader(files, chunk: chunk))
            XCTAssertEqual(pulled, draft, "chunk \(chunk)")
            // Sending the pulled draft reproduces the reader's revision.
            XCTAssertEqual(try pulled.revision().revision, revision)
        }
        let empty = try published(ContentDraft())
        let pulledEmpty = try await ReaderContentPull.draft(revision: empty.revision, read: reader(empty.files))
        XCTAssertEqual(pulledEmpty, ContentDraft())
    }

    func testAnyMismatchFailsWithoutADraft() async throws {
        let (revision, files) = try published(sampleDraft())
        let cardName = try XCTUnwrap(files.keys.first { $0.hasSuffix(".card") })

        var altered = files
        altered[cardName]![100] ^= 1
        await assertFailure(.integrity(cardName), revision: revision, files: altered)

        await assertFailure(.integrity("manifest.pdcm"), revision: String(repeating: "0", count: 64), files: files)

        var missing = files
        missing["sun.pbm"] = nil
        do {
            _ = try await ReaderContentPull.draft(revision: revision, read: reader(missing))
            XCTFail("A missing file must fail")
        } catch {}

        // A reader that returns more than the file holds is rejected, not truncated.
        let greedy: (String, Int) async throws -> Data = { name, offset in
            let data = files[name]!
            return data.subdata(in: offset..<data.count) + Data([0])
        }
        do {
            _ = try await ReaderContentPull.draft(revision: revision, read: greedy)
            XCTFail("An over-long read must fail")
        } catch let failure as ReaderContentPull.Failure {
            XCTAssertEqual(failure, .integrity("manifest.pdcm"))
        }
        let stalled: (String, Int) async throws -> Data = { _, _ in Data() }
        do {
            _ = try await ReaderContentPull.draft(revision: revision, read: stalled)
            XCTFail("An empty read must fail")
        } catch let failure as ReaderContentPull.Failure {
            XCTAssertEqual(failure, .integrity("manifest.pdcm"))
        }
    }

    @MainActor func testPulledCardsOpenTheSameReviewAsAnImport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let editor = ContentEditorModel(store: ContentDraftStore(file: directory.appendingPathComponent("cards.json")))
        XCTAssertThrowsError(try editor.prepareImport(sampleDraft(), sourceName: "Cards on X3"), "not loaded yet")
        try await editor.load()
        try editor.prepareImport(sampleDraft(), sourceName: "Cards on X3")
        let proposal = try XCTUnwrap(editor.pendingImport)
        XCTAssertEqual(proposal.sourceName, "Cards on X3")
        XCTAssertEqual(proposal.before, ContentDraft())
        XCTAssertEqual(editor.draft, ContentDraft(), "Nothing changes before Replace")
        try editor.confirmImport(id: proposal.id)
        XCTAssertEqual(editor.draft, sampleDraft())

        let demo = ContentEditorModel(store: ContentDraftStore(file: directory.appendingPathComponent("demo.json")),
                                      isDemo: true)
        XCTAssertThrowsError(try demo.prepareImport(sampleDraft(), sourceName: "Cards on X3"))
    }

    /// The model reads state, then chunked files, in the reader lane and hands
    /// back the verified draft; only readers advertising contentRead offer it.
    @MainActor func testModelLoadsTheActiveCardsOverHTTP() async throws {
        let draft = sampleDraft()
        let (revision, files) = try published(draft)
        ContentReadURLProtocol.serve(revision: revision, files: files)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ContentReadURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        var status = CrossPointStatus(version: "test", ip: "reader.test", mode: "STA", rssi: -50, freeHeap: 20000,
                                      uptime: 1, device: "X3", crashReportAvailable: false, crashReportBytes: 0,
                                      screenPreviewAvailable: false, screenPreviewBytes: 0, uploadChunkBytes: nil,
                                      uploadStreamPort: 82, uploadStreamResume: true, diagnosticsAffordable: false,
                                      deviceID: "1234ABCD", contentPresentation: true)
        model.readerStatus = status
        XCTAssertFalse(model.canLoadReaderCards, "Older firmware does not offer loading")
        status.contentRead = 1
        model.readerStatus = status
        XCTAssertTrue(model.canLoadReaderCards)

        let result: Result<ContentDraft?, Error> = await withCheckedContinuation { continuation in
            XCTAssertTrue(model.loadReaderCards { continuation.resume(returning: $0) })
        }
        XCTAssertEqual(try result.get(), draft)
        let paths = ContentReadURLProtocol.requested
        XCTAssertEqual(paths.first, "/api/pocket/v1/content/state")
        XCTAssertTrue(paths.dropFirst().allSatisfy { $0 == "/api/pocket/v1/content/file" })
        XCTAssertFalse(ContentReadURLProtocol.methods.contains { $0 != "GET" }, "Loading never writes")

        ContentReadURLProtocol.serve(revision: nil, files: [:])
        // The lane releases just after delivery.
        for _ in 0..<200 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        let empty: Result<ContentDraft?, Error> = await withCheckedContinuation { continuation in
            XCTAssertTrue(model.loadReaderCards { continuation.resume(returning: $0) })
        }
        XCTAssertNil(try empty.get(), "No active revision means no app cards")
    }

    private func assertFailure(_ expected: ReaderContentPull.Failure, revision: String, files: [String: Data],
                               file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await ReaderContentPull.draft(revision: revision, read: reader(files))
            XCTFail("Expected \(expected)", file: file, line: line)
        } catch let failure as ReaderContentPull.Failure {
            XCTAssertEqual(failure, expected, file: file, line: line)
        } catch {
            XCTFail("Unexpected \(error)", file: file, line: line)
        }
    }
}

/// Serves content/state and content/file like the reader.
private final class ContentReadURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var revision: String?
    nonisolated(unsafe) private static var files: [String: Data] = [:]
    nonisolated(unsafe) private static var paths: [String] = []
    nonisolated(unsafe) private static var verbs: [String] = []
    static var requested: [String] { lock.withLock { paths } }
    static var methods: [String] { lock.withLock { verbs } }
    static func serve(revision: String?, files: [String: Data]) {
        lock.withLock { self.revision = revision; self.files = files; paths = []; verbs = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return }
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        let (revision, files) = Self.lock.withLock {
            Self.paths.append(url.path)
            Self.verbs.append(request.httpMethod ?? "GET")
            return (Self.revision, Self.files)
        }
        var status = 200
        var body = Data()
        switch url.path {
        case "/api/pocket/v1/content/state":
            let active = revision.map { #"{"revision":"\#($0)","generation":1}"# } ?? "null"
            body = Data(#"{"schema":1,"deviceID":"\#(values["deviceID"] ?? "")","capabilities":7,"active":\#(active)}"#.utf8)
        case "/api/pocket/v1/content/file":
            if values["revision"] == revision, let data = files[values["name"] ?? ""],
               let offset = Int(values["offset"] ?? ""), offset < data.count {
                body = data.subdata(in: offset..<min(data.count, offset + 4096))
            } else { status = 404 }
        default: status = 404
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }
}
