import XCTest
@testable import Pocket

@MainActor
final class ContentApplyAdmissionTests: XCTestCase {
    func testInitialNetworkFailureRevokesApplyWithoutResendingOrLosingDraft() async throws {
        for code: URLError.Code in [.timedOut, .cannotConnectToHost, .cancelled, .badServerResponse] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let journal = ContentActivationJournal(file: folder.appendingPathComponent("intent.json"))
            var reads = 0
            let model = PocketModel(activationJournal: journal, contentTransportFactory: { revision, identity, _, _ in
                ReaderContentTransport(target: revision, deviceID: identity, operations: .init(
                    state: { reads += 1; throw URLError(code) },
                    stage: { _, _, _ in XCTFail("Initial check must precede uploads"); throw CancellationError() },
                    inspect: { XCTFail("No staging"); throw CancellationError() },
                    activate: { XCTFail("No activation") }))
            })
            defer { model.pauseForBackground() }
            var reader = status()
            reader.contentPresentation = true
            model.readerStatus = reader
            let revision = try target()
            let editingSession = try XCTUnwrap(model.contentEditingSession)
            let applied = await model.applyLiveContent(revision, session: editingSession)
            XCTAssertFalse(applied)
            XCTAssertEqual(reads, 1)
            XCTAssertEqual(model.contentDeployment?.failurePhase, .checking)
            XCTAssertFalse(model.isWorking)
            let pending = try await journal.load()
            XCTAssertNil(pending)
            if code == .timedOut || code == .cannotConnectToHost {
                XCTAssertNil(model.readerStatus)
                XCTAssertNil(model.contentEditingSession)
                XCTAssertTrue(model.message.contains("No content was sent"))
                XCTAssertNil(model.applyContent(revision))
                XCTAssertEqual(reads, 1)
            } else {
                XCTAssertNotNil(model.readerStatus, "Cancellation and response errors do not prove disconnection")
            }
        }
    }

    func testLocalFileWorkOwnsAdmissionAndRetainsCompletedReceiptAfterCancellation() async throws {
        for copy in [false, true] {
            let io = HeldLocalFiles()
            ApplyPresentationURLProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ApplyPresentationURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session),
                                    localFiles: .init(prepare: { _ in try await io.prepare() },
                                                      copy: { _, _ in try await io.copy() }))
            defer { model.pauseForBackground(); Task { await io.fail() } }
            let source = URL(fileURLWithPath: "/not-accessed.epub")
            let root = URL(fileURLWithPath: "/not-accessed-directory")
            if copy { model.copyToSD(source, root: root) } else { model.upload(source) }
            XCTAssertTrue(model.isWorking, "Reserve before the scheduled task starts")
            XCTAssertFalse(model.isTransferring)
            for _ in 0..<100 {
                if await io.calls == 1 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            model.upload(source)
            model.copyToSD(source, root: root)
            await model.verify(host: "must-not-contact.test", port: 80)
            model.findOnLocalNetwork(retryIfMissing: false)
            XCTAssertTrue(ApplyPresentationURLProtocol.paths.isEmpty)
            model.pauseForBackground()
            model.resumeForForeground()
            model.copyToSD(source, root: root)
            XCTAssertTrue(model.isWorking, "Non-cooperative file I/O retains ownership until completion")
            let calls = await io.calls
            XCTAssertEqual(calls, 1)
            let item = PreparedTransfer(id: UUID(), filename: "retained.epub", firmwareVersion: nil)
            await io.succeed(item)
            for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(model.isWorking)
            if copy { XCTAssertTrue(model.message.contains("Copied to SD card")) }
            else { XCTAssertTrue(model.preparedTransfers.contains(item)) }
            model.copyToSD(source, root: root)
            for _ in 0..<100 {
                if await io.calls == 2 { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            XCTAssertTrue(model.isWorking)
            await io.succeed(item)
            for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(model.isWorking)
            let finalCalls = await io.calls
            XCTAssertEqual(finalCalls, 2)
            XCTAssertTrue(ApplyPresentationURLProtocol.paths.isEmpty)
        }
    }

    func testDemoAndBackgroundRejectLocalFileWritesAtModelBoundary() async throws {
        let io = HeldLocalFiles()
        let model = PocketModel(localFiles: .init(prepare: { _ in try await io.prepare() },
                                                  copy: { _, _ in try await io.copy() }))
        defer { model.pauseForBackground(); Task { await io.fail() } }
        let source = URL(fileURLWithPath: "/not-accessed.epub")
        for demo in [true, false] {
            model.isDemoMode = demo
            if !demo { model.pauseForBackground() }
            model.upload(source)
            model.copyToSD(source, root: source)
            XCTAssertFalse(model.canPrepareFiles)
            XCTAssertFalse(model.isWorking)
            for _ in 0..<10 { await Task.yield() }
            let calls = await io.calls
            XCTAssertEqual(calls, 0)
        }
    }

    func testVerificationCannotReplaceTransferWhileCancellationDrains() async throws {
        try await checkTransferDrain(background: false)
        try await checkTransferDrain(background: true)
    }

    private func checkTransferDrain(background: Bool) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ApplyPresentationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ApplyPresentationURLProtocol.reset()
        let revision = try target()
        let active = ContentActiveReceipt(revision: revision.revision, generation: 1)
        let state = ContentDeviceState(deviceID: "1234ABCD", schema: 1, capabilities: 7, active: active)
        var held: CheckedContinuation<ContentDeviceState, Error>?
        var reads = 0
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session),
                                activationJournal: ContentActivationJournal(file: folder.appendingPathComponent("intent.json")),
                                contentTransportFactory: { target, identity, _, _ in
            ReaderContentTransport(target: target, deviceID: identity, operations: .init(
                state: {
                    reads += 1
                    if reads == 1 { return try await withCheckedThrowingContinuation { held = $0 } }
                    return state
                },
                stage: { _, _, _ in XCTFail("Already active; no upload"); throw CancellationError() },
                inspect: { XCTFail("Already active; no preparation"); throw CancellationError() },
                activate: { XCTFail("Already active; no activation") }))
        })
        defer { model.pauseForBackground(); held?.resume(throwing: CancellationError()) }
        model.readerStatus = status()
        model.applyContent(revision)
        for _ in 0..<100 where held == nil { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertNotNil(held)
        let original = model.contentDeployment
        if background {
            model.pauseForBackground()
            model.resumeForForeground()
        } else {
            model.pauseTransfer()
        }
        // A non-cooperative I/O completion still owns the lane until it drains.
        await model.verify(host: "must-not-contact.test", port: 80)
        model.findOnLocalNetwork(retryIfMissing: false)
        XCTAssertTrue(ApplyPresentationURLProtocol.paths.isEmpty)
        XCTAssertTrue(model.isWorking)
        XCTAssertTrue(model.isTransferring)
        model.applyContent(revision)
        XCTAssertTrue(model.contentDeployment === original)
        held?.resume(returning: state)
        held = nil
        for _ in 0..<100 where model.isTransferring { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isTransferring)
        XCTAssertEqual(original?.phase, .cancelled)
        model.applyContent(revision)
        for _ in 0..<100 where model.isTransferring { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(model.contentDeployment?.phase, .complete(active))
        XCTAssertEqual(reads, 2)
        XCTAssertFalse(model.isWorking)
    }

    func testActualApplyLifecycleKeepsSessionAcrossEditsAndFailedUpload() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ContentActivationJournal(file: folder.appendingPathComponent("intent.json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ApplyPresentationURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        ApplyPresentationURLProtocol.reset()
        var active: ContentActiveReceipt?
        var files: [String: Data] = [:]
        var stages: [String] = []
        var activations = 0
        var failUpload = false
        var destinations: [String] = []
        let model = PocketModel(client: CrossPointClient(session: session), activationJournal: journal,
                                contentTransportFactory: { revision, identity, host, port in
            destinations.append("\(identity)@\(host):\(port)")
            return ReaderContentTransport(target: revision, deviceID: identity, operations: .init(
                state: { .init(deviceID: identity, schema: 1, capabilities: 7, active: active) },
                stage: { data, name, directory in
                    if failUpload && name != "manifest.pdcm" { throw URLError(.networkConnectionLost) }
                    stages.append(name)
                    files[name] = data
                    return directory + "/" + name
                },
                inspect: {
                    .init(destination: .init(deviceID: identity, revision: revision.revision),
                          verifiedFiles: revision.files.filter { files[$0.path] == $0.data }.map {
                        .init(path: $0.path, kind: $0.kind, bytes: UInt32($0.data.count), sha256: $0.sha256)
                    })
                },
                activate: {
                    activations += 1
                    active = .init(revision: revision.revision, generation: UInt32(activations))
                }))
        })
        defer { model.pauseForBackground() }
        var readerStatus = status()
        readerStatus.contentPresentation = true
        model.readerStatus = readerStatus
        let image = Data("P4\n8 1\n".utf8) + Data([0x81])
        func revision(_ title: String) throws -> ContentRevision {
            try .init(cards: [.init(id: "a", title: title, question: "Text", imagePath: "sun.pbm")],
                      images: ["sun.pbm": image])
        }
        func finishApply() async throws {
            for _ in 0..<400 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(model.isWorking)
            XCTAssertFalse(model.isTransferring)
            XCTAssertEqual(model.readerStatus, readerStatus, "Apply must not discard the selected session")
        }
        let first = try revision("First")
        let editingSession = try XCTUnwrap(model.contentEditingSession)
        let initialLiveResult = await model.applyLiveContent(first, session: editingSession)
        XCTAssertTrue(initialLiveResult)
        try await finishApply()
        XCTAssertEqual(model.contentDeployment?.phase, .complete(try XCTUnwrap(active)))
        XCTAssertEqual(model.contentRedrawReceipt, active)
        XCTAssertTrue(model.message.contains("completed redraw"))
        XCTAssertEqual(activations, 1)
        let firstStages = stages.count

        // A redraw failure is not an upload failure. Exercise the real model's
        // Apply entry point again, including a stale display receipt and lost
        // POST + GET responses, without replacing the selected session.
        var expectedPaths = ["/api/pocket/v1/content/present"]
        for responses: [ApplyPresentationURLProtocol.Reply] in [
            [.failed], [.wrongGeneration, .wrongGeneration], [.unavailable, .unavailable]
        ] {
            ApplyPresentationURLProtocol.script(responses)
            model.applyContent(first)
            try await finishApply()
            XCTAssertEqual(model.contentDeployment?.phase, .complete(try XCTUnwrap(active)))
            XCTAssertNil(model.contentRedrawReceipt)
            XCTAssertTrue(model.message.contains("Nothing was resent"))
            XCTAssertEqual(stages.count, firstStages)
            XCTAssertEqual(activations, 1)
            expectedPaths.append("/api/pocket/v1/content/present")
            if responses.count == 2 { expectedPaths.append("/api/pocket/v1/content/presentation") }

            model.applyContent(first)
            try await finishApply()
            XCTAssertEqual(model.contentRedrawReceipt, active)
            XCTAssertEqual(stages.count, firstStages, "Redraw retry must not stage even the manifest")
            XCTAssertEqual(activations, 1, "Redraw retry must not create a new activation generation")
            let pendingAfterRedraw = try await journal.load()
            XCTAssertNil(pendingAfterRedraw)
            expectedPaths.append("/api/pocket/v1/content/present")
            XCTAssertEqual(ApplyPresentationURLProtocol.paths, expectedPaths)
        }

        // Losing only the command reply does not require another Apply: the
        // existing read-only fallback can confirm the already completed frame.
        ApplyPresentationURLProtocol.script([.unavailable, .rendered])
        model.applyContent(first)
        try await finishApply()
        XCTAssertEqual(model.contentRedrawReceipt, active)
        XCTAssertEqual(stages.count, firstStages)
        XCTAssertEqual(activations, 1)
        expectedPaths += ["/api/pocket/v1/content/present", "/api/pocket/v1/content/presentation"]
        XCTAssertEqual(ApplyPresentationURLProtocol.paths, expectedPaths)

        let second = try revision("Second")
        failUpload = true
        let failedLiveResult = await model.applyLiveContent(second, session: editingSession)
        XCTAssertFalse(failedLiveResult)
        try await finishApply()
        XCTAssertEqual(model.contentDeployment?.phase, .failed)
        XCTAssertNil(model.contentRedrawReceipt, "Old redraw must not confirm a new draft")
        XCTAssertEqual(active?.revision, first.revision)
        XCTAssertEqual(activations, 1)
        let pendingAfterFailure = try await journal.load()
        XCTAssertNil(pendingAfterFailure)

        failUpload = false
        model.applyContent(second)
        try await finishApply()
        XCTAssertEqual(active?.revision, second.revision)
        XCTAssertEqual(active?.generation, 2)
        XCTAssertEqual(model.contentRedrawReceipt, active)
        XCTAssertEqual(activations, 2)
        XCTAssertEqual(Array(stages.dropFirst(firstStages)), ["manifest.pdcm", "manifest.pdcm", "card-00-a.card"])
        let pendingAfterSuccess = try await journal.load()
        XCTAssertNil(pendingAfterSuccess)
        XCTAssertEqual(Set(destinations).count, 1)
        expectedPaths.append("/api/pocket/v1/content/present")
        XCTAssertEqual(ApplyPresentationURLProtocol.paths, expectedPaths)
        model.pauseForBackground()
        model.resumeForForeground()
        let staleSessionResult = await model.applyLiveContent(first, session: editingSession)
        XCTAssertFalse(staleSessionResult)
        XCTAssertEqual(ApplyPresentationURLProtocol.paths, expectedPaths)
    }

    private func target() throws -> ContentRevision {
        try ContentRevision(cards: [.init(id: "a", title: "A", question: "Text")])
    }

    private func status(id: String? = "1234ABCD", stream: Int? = 82,
                        device: String = "X3") -> CrossPointStatus {
        .init(version: "test", ip: "reader.test", mode: "STA", rssi: -50,
              freeHeap: 20000, uptime: 1, device: device,
              crashReportAvailable: false, crashReportBytes: 0,
              uploadChunkBytes: nil, uploadStreamPort: stream, uploadStreamResume: true,
              diagnosticsAffordable: false, deviceID: id)
    }

    func testDisconnectedAndDemoDoNotStartDeployment() throws {
        let model = PocketModel()
        model.applyContent(try target())
        XCTAssertNil(model.contentDeployment)
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isTransferring)
        model.isDemoMode = true
        model.readerStatus = status()
        model.applyContent(try target())
        XCTAssertNil(model.contentDeployment)
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.message.contains("Demo"))
    }

    func testExistingOperationIsNotOverwritten() throws {
        let model = PocketModel()
        model.readerStatus = status()
        model.isWorking = true
        let original = model.message
        model.applyContent(try target())
        XCTAssertTrue(model.isWorking)
        XCTAssertEqual(model.message, original)
        XCTAssertNil(model.contentDeployment)
    }

    func testUnsupportedAndUnidentifiedReadersNeverStartTransport() throws {
        for reader in [status(id: nil), status(id: "1234abcd"), status(stream: nil),
                       status(stream: 0), status(stream: 65536), status(device: "Unknown")] {
            let model = PocketModel()
            model.readerStatus = reader
            model.applyContent(try target())
            XCTAssertNil(model.contentDeployment)
            XCTAssertFalse(model.isTransferring)
            XCTAssertFalse(model.isWorking)
        }
    }
}

private actor HeldLocalFiles {
    private(set) var calls = 0
    private var preparation: CheckedContinuation<PreparedTransfer, Error>?
    private var copying: CheckedContinuation<SDCopyResult, Error>?
    func prepare() async throws -> PreparedTransfer {
        calls += 1
        return try await withCheckedThrowingContinuation { preparation = $0 }
    }
    func copy() async throws -> SDCopyResult {
        calls += 1
        return try await withCheckedThrowingContinuation { copying = $0 }
    }
    func succeed(_ item: PreparedTransfer) {
        preparation?.resume(returning: item)
        copying?.resume(returning: .init(path: "/retained.epub", firmwareVersion: nil))
        preparation = nil
        copying = nil
    }
    func fail() {
        preparation?.resume(throwing: CancellationError())
        copying?.resume(throwing: CancellationError())
        preparation = nil
        copying = nil
    }
}

private final class ApplyPresentationURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply { case rendered, failed, wrongGeneration, unavailable }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recordedPaths: [String] = []
    nonisolated(unsafe) private static var generations: [String: Int] = [:]
    nonisolated(unsafe) private static var replies: [Reply] = []
    static var paths: [String] { lock.withLock { recordedPaths } }
    static func reset() { lock.withLock { recordedPaths = []; generations = [:]; replies = [] } }
    static func script(_ values: [Reply]) { lock.withLock { replies = values } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.recordedPaths.append(url.path) }
        guard (url.path == "/api/pocket/v1/content/present" && request.httpMethod == "POST")
                || (url.path == "/api/pocket/v1/content/presentation" && request.httpMethod == "GET"),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        let (generation, reply) = Self.lock.withLock {
            let revision = values["revision"] ?? ""
            if Self.generations[revision] == nil { Self.generations[revision] = Self.generations.count + 1 }
            return (Self.generations[revision] ?? 0, Self.replies.isEmpty ? Reply.rendered : Self.replies.removeFirst())
        }
        if reply == .unavailable {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        let body: [String: Any] = ["schema": 1, "deviceID": values["deviceID"] ?? "",
                                  "revision": values["revision"] ?? "",
                                  "generation": reply == .wrongGeneration ? generation + 1 : generation,
                                  "phase": reply == .failed ? "failed" : "rendered"]
        do {
            let data = try JSONSerialization.data(withJSONObject: body)
            guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
