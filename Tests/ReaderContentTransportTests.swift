import XCTest
@testable import Pocket

@MainActor
final class ReaderContentTransportTests: XCTestCase {
    @MainActor private final class Reader {
        let target: ContentRevision
        var identity = "1234ABCD"
        var capabilities: UInt16 = 3
        var files: [String: Data] = [:]
        var staged: [String] = []
        var active: ContentActiveReceipt?
        var corruptAsset = false
        var loseActivationReply = false
        var activationCalls = 0
        init(_ target: ContentRevision) { self.target = target }

        func transport() -> ReaderContentTransport {
            ReaderContentTransport(target: target, deviceID: "1234ABCD", operations: .init(
                state: { .init(deviceID: self.identity, schema: 1, capabilities: self.capabilities, active: self.active) },
                stage: { data, name, directory in
                    self.staged.append(name)
                    self.files[name] = self.corruptAsset && name != "manifest.pdcm" ? Data() : data
                    XCTAssertEqual(directory, "/pocket-daily/content-staging/" + self.target.revision)
                    return directory + "/" + name
                },
                inspect: {
                    XCTAssertEqual(self.files["manifest.pdcm"], self.target.manifest)
                    return .init(destination: .init(deviceID: self.identity, revision: self.target.revision),
                                 verifiedFiles: self.target.files.filter { self.files[$0.path] == $0.data }.map {
                        .init(path: $0.path, kind: $0.kind, bytes: UInt32($0.data.count), sha256: $0.sha256)
                    })
                },
                activate: {
                    self.activationCalls += 1
                    self.active = .init(revision: self.target.revision, generation: 1)
                    if self.loseActivationReply { throw URLError(.networkConnectionLost) }
                }
            ))
        }
    }

    private func target() throws -> ContentRevision {
        try ContentRevision(cards: [.init(id: "a", title: "A", question: "Text")])
    }

    func testLayoutEditRequiresCapabilityBeforeStagingAndKeepsUnchangedImage() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ContentDraftStore(file: folder.appendingPathComponent("draft.json"))
        let editor = ContentEditorModel(store: store)
        let image = Data("P4\n8 1\n".utf8) + Data([0x81])
        editor.edit(.init(cards: [.init(id: "a", title: "Layout", question: "Text", imagePath: "sun.pbm", layout: .sideBySide)],
                          images: ["sun.pbm": image]))
        try await editor.save()
        let saved = try await store.load()
        XCTAssertEqual(saved?.schema, 2, "Older apps must reject rather than discard layout")
        let reopened = ContentEditorModel(store: store)
        try await reopened.load()
        XCTAssertEqual(reopened.draft, editor.draft)
        let target = try reopened.deploymentSnapshot()
        XCTAssertEqual(target.requiredCapabilities, 7)
        XCTAssertEqual(target.manifest[10], 7)
        let reader = Reader(target)
        let deployment = ContentDeployment(deviceID: reader.identity, transport: reader.transport())
        do { _ = try await deployment.deploy(target); XCTFail("Legacy reader cannot render layout") }
        catch { XCTAssertEqual(error as? ContentDeployment.Failure, .unsupported) }
        XCTAssertTrue(reader.staged.isEmpty)
        XCTAssertEqual(reader.activationCalls, 0)
        reader.capabilities = 7
        reader.files["sun.pbm"] = image // Reader preparation verified the reused image.
        _ = try await deployment.deploy(target)
        XCTAssertEqual(reader.staged, ["manifest.pdcm", "card-00-a.card"])
        XCTAssertEqual(reader.activationCalls, 1)
        XCTAssertEqual(reader.files["card-00-a.card"]?[491], 2)
    }

    func testCoordinatorStagesManifestAndAssetsAndConfirmsLostActivationReply() async throws {
        let target = try target()
        let reader = Reader(target)
        reader.loseActivationReply = true
        let deployment = ContentDeployment(deviceID: "1234ABCD", transport: reader.transport())
        let result = try await deployment.deploy(target)
        XCTAssertEqual(result.revision, target.revision)
        XCTAssertEqual(reader.staged, ["manifest.pdcm", "card-00-a.card"])
        XCTAssertEqual(reader.activationCalls, 1)
        _ = try await deployment.deploy(target)
        XCTAssertEqual(reader.activationCalls, 1)
        XCTAssertEqual(reader.staged.count, 2)
    }

    func testSavedEditorSnapshotAppliesAndRedrawFailureDoesNotResendContent() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ContentDraftStore(file: folder.appendingPathComponent("draft.json"))
        let editor = ContentEditorModel(store: store)
        try await editor.load()
        editor.edit(.init(cards: [.init(id: "a", title: "오늘", question: "읽고 싶은 내용")]))
        try await editor.save()
        let reopened = ContentEditorModel(store: store)
        try await reopened.load()
        XCTAssertEqual(reopened.draft, editor.draft)
        let snapshot = try reopened.deploymentSnapshot()
        let reader = Reader(snapshot)
        reader.loseActivationReply = true
        let journal = ContentActivationJournal(file: folder.appendingPathComponent("intent.json"))
        let deployment = ContentDeployment(deviceID: reader.identity, transport: reader.transport(), journal: journal)

        // Later edits must not alter the captured deployment or saved document.
        reopened.edit(.init(cards: [.init(id: "a", title: "Later", question: "Not applied")]))
        let active = try await deployment.deploy(snapshot)
        XCTAssertEqual(active.revision, snapshot.revision)
        let pending = try await journal.load()
        XCTAssertNil(pending)
        let staged = reader.staged
        var presentationRequests = 0
        var presentationReads = 0
        do {
            try await ContentPresenter.present(deviceID: reader.identity, active: active, using: .init(
                request: {
                    presentationRequests += 1
                    throw URLError(.networkConnectionLost)
                },
                state: {
                    presentationReads += 1
                    return .init(schema: 1, deviceID: reader.identity, revision: active.revision,
                                 generation: active.generation, phase: .failed)
                }, wait: {}))
            XCTFail("Display failed, even though storage activation succeeded")
        } catch { XCTAssertTrue(error is ContentPresenter.Failure) }
        XCTAssertEqual(deployment.phase, .complete(active))
        XCTAssertEqual(presentationRequests, 1)
        XCTAssertEqual(presentationReads, 1)
        XCTAssertEqual(reader.staged, staged)
        XCTAssertEqual(reader.activationCalls, 1)
        XCTAssertEqual(reader.files["card-00-a.card"], snapshot.files.first?.data)
        XCTAssertTrue(reopened.hasUnsavedChanges)
        let saved = try await store.load()
        XCTAssertEqual(saved?.draft, editor.draft)

        // Explicitly applying the same confirmed snapshot needs only a state
        // check; neither a redraw failure nor a lost POST authorizes resending.
        _ = try await deployment.deploy(snapshot)
        XCTAssertEqual(reader.staged, staged)
        XCTAssertEqual(reader.activationCalls, 1)
    }

    func testVerifiedCandidateAssetIsNotUploadedAgain() async throws {
        let target = try target()
        let reader = Reader(target)
        for asset in target.files { reader.files[asset.path] = asset.data }
        _ = try await ContentDeployment(deviceID: "1234ABCD", transport: reader.transport()).deploy(target)
        XCTAssertEqual(reader.staged, ["manifest.pdcm"])
    }

    func testCardEditUploadsOnlyCardWhenPreparationVerifiedReusedImage() async throws {
        let image = try ContentImage(width: 9, height: 2, raster: Data([0xAA, 0x80, 0x55, 0])).encoded()
        let previous = try ContentRevision(cards: [.init(id: "a", title: "Before", question: "Text", imagePath: "sun.pbm")],
                                           images: ["sun.pbm": image])
        let target = try ContentRevision(cards: [.init(id: "a", title: "After", question: "Text", imagePath: "sun.pbm")],
                                         images: ["sun.pbm": image])
        XCTAssertNotEqual(previous.revision, target.revision)
        let reader = Reader(target)
        // Models the receipt after firmware has copied and rehashed the old
        // image into this candidate. Old-revision presence alone is not proof.
        reader.files["sun.pbm"] = image
        _ = try await ContentDeployment(deviceID: "1234ABCD", transport: reader.transport()).deploy(target)
        XCTAssertEqual(reader.staged, ["manifest.pdcm", "card-00-a.card"])
        XCTAssertEqual(reader.activationCalls, 1)
    }

    func testSuccessfulUploadWithoutVerifiedBytesNeverActivates() async throws {
        let target = try target()
        let reader = Reader(target)
        reader.corruptAsset = true
        let deployment = ContentDeployment(deviceID: "1234ABCD", transport: reader.transport())
        do {
            _ = try await deployment.deploy(target)
            XCTFail("A successful transfer response is not a verified asset")
        } catch {
            XCTAssertEqual(deployment.phase, .failed)
            XCTAssertEqual(reader.activationCalls, 0)
            XCTAssertNil(reader.active)
        }
    }

    func testWrongReaderAndUnboundInputCannotWrite() async throws {
        let target = try target()
        let reader = Reader(target)
        let transport = reader.transport()
        reader.identity = "9999FFFF"
        do {
            _ = try await transport.prepare(revision: target.revision, manifest: target.manifest)
            XCTFail("Wrong reader")
        } catch { XCTAssertTrue(reader.staged.isEmpty) }
        reader.identity = "1234ABCD"
        do {
            _ = try await transport.prepare(revision: target.revision, manifest: Data())
            XCTFail("Unbound manifest")
        } catch { XCTAssertTrue(reader.staged.isEmpty) }
        do {
            try await transport.activate(revision: String(repeating: "a", count: 64))
            XCTFail("Unbound activation")
        } catch { XCTAssertEqual(reader.activationCalls, 0) }
    }
}
