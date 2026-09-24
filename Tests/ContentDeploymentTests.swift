import XCTest
@testable import Pocket

@MainActor
final class ContentDeploymentTests: XCTestCase {
    private enum Fault: Error { case disconnected }
    private final class Transport: ContentDeploymentTransport {
        var states: [Result<ContentDeviceState, Error>] = []
        var events: [String] = []
        var verifiedFiles: [ContentManifest.File] = []
        var preparationID = "reader"
        var uploadError: Error?
        var activationError: Error?
        var onActivate: (() async throws -> Void)?
        var suspendRead: CheckedContinuation<Void, Never>?
        var onRead: (() -> Void)?

        func readState() async throws -> ContentDeviceState {
            events.append("state")
            if let onRead {
                await withCheckedContinuation { continuation in
                    suspendRead = continuation
                    onRead()
                }
            }
            guard !states.isEmpty else { throw Fault.disconnected }
            return try states.removeFirst().get()
        }
        func prepare(revision: String, manifest: Data) async throws -> ContentPreparation {
            events.append("prepare")
            XCTAssertEqual(ContentManifest.revision(of: manifest), revision)
            return .init(destination: .init(deviceID: preparationID, revision: revision), verifiedFiles: verifiedFiles)
        }
        func upload(_ asset: ContentRevision.Asset, revision: String) async throws -> ContentDestination {
            events.append("upload:" + asset.path)
            if let uploadError { throw uploadError }
            return .init(deviceID: preparationID, revision: revision)
        }
        func activate(revision: String) async throws {
            events.append("activate")
            try await onActivate?()
            if let activationError { throw activationError }
        }
    }

    private func revision() throws -> ContentRevision {
        try ContentRevision(cards: [.init(id: "a", title: "A", question: "Text")])
    }

    func testIntentIsDurableBeforeActivationAndBlocksAnotherDeployment() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let journal = ContentActivationJournal(file: folder.appendingPathComponent("intent.json"))
        let target = try revision()
        let transport = Transport()
        transport.preparationID = "1234ABCD"
        transport.states = [.success(state(id: "1234ABCD")), .failure(Fault.disconnected)]
        transport.onActivate = {
            let stored = try await journal.load()
            XCTAssertEqual(stored?.revision, target.revision)
            XCTAssertEqual(stored?.deviceID, "1234ABCD")
        }
        let first = ContentDeployment(deviceID: "1234ABCD", transport: transport, journal: journal)
        do { _ = try await first.deploy(target); XCTFail("Confirmation was lost") } catch { }
        XCTAssertEqual(first.phase, .needsConfirmation)
        let before = transport.events
        let second = ContentDeployment(deviceID: "1234ABCD", transport: transport, journal: journal)
        do { _ = try await second.deploy(target); XCTFail("Unresolved intent") } catch { }
        XCTAssertEqual(transport.events, before)
        let saved = try await journal.load()
        XCTAssertNotNil(saved)
    }

    func testJournalWriteFailurePreventsActivation() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let journal = ContentActivationJournal(file: file.appendingPathComponent("intent.json"))
        let transport = Transport()
        transport.preparationID = "1234ABCD"
        transport.states = [.success(state(id: "1234ABCD"))]
        let deployment = ContentDeployment(deviceID: "1234ABCD", transport: transport, journal: journal)
        do { _ = try await deployment.deploy(revision()); XCTFail("Journal is unavailable") } catch { }
        XCTAssertFalse(transport.events.contains("activate"))
    }

    func testRepeatedApplyPreservesPendingOutcomeAndCanStillConfirmOriginalRevision() async throws {
        for persisted in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let journal = persisted ? ContentActivationJournal(file: folder.appendingPathComponent("intent.json")) : nil
            let target = try revision()
            let replacement = try ContentRevision(cards: [.init(id: "a", title: "Later edit", question: "Text")])
            let transport = Transport()
            transport.preparationID = "1234ABCD"
            transport.states = [.success(state(id: "1234ABCD")), .failure(Fault.disconnected)]
            let deployment = ContentDeployment(deviceID: "1234ABCD", transport: transport, journal: journal)
            do { _ = try await deployment.deploy(target); XCTFail("Confirmation was lost") } catch { }
            XCTAssertEqual(deployment.phase, .needsConfirmation)
            let before = transport.events
            let intent = try await journal?.load()

            for retry in [target, replacement] {
                do {
                    _ = try await deployment.deploy(retry)
                    XCTFail("Unresolved activation must prevent another deployment")
                } catch {
                    XCTAssertEqual(error as? ContentActivationJournal.Failure, .unresolved)
                }
                XCTAssertEqual(deployment.phase, .needsConfirmation)
                XCTAssertEqual(transport.events, before, "No read, upload or activation on repeated Apply")
                let stored = try await journal?.load()
                XCTAssertEqual(stored, intent)
            }

            transport.states = [.success(state(target, id: "1234ABCD"))]
            let confirmed = try await deployment.confirmPendingActivation()
            XCTAssertEqual(confirmed.revision, target.revision, "Confirm original snapshot, not later edits")
            XCTAssertEqual(deployment.phase, .complete(confirmed))
            XCTAssertEqual(transport.events, before + ["state"])
            let remaining = try await journal?.load()
            XCTAssertNil(remaining)
        }
    }
    private func state(_ revision: ContentRevision? = nil, id: String = "reader", capabilities: UInt16 = 3) -> ContentDeviceState {
        .init(deviceID: id, schema: 1, capabilities: capabilities,
              active: revision.map { .init(revision: $0.revision, generation: 2) })
    }

    func testUploadsAndConfirmsInsteadOfTrustingActivationReply() async throws {
        let target = try revision()
        let transport = Transport()
        transport.states = [.success(state()), .success(state(target))]
        let deployment = ContentDeployment(deviceID: "reader", transport: transport)
        let receipt = try await deployment.deploy(target)
        XCTAssertEqual(receipt.revision, target.revision)
        XCTAssertEqual(deployment.phase, .complete(receipt))
        XCTAssertEqual(transport.events, ["state", "prepare", "upload:card-00-a.card", "activate", "state"])
    }

    func testAlreadyActiveDoesNotPrepareUploadOrActivate() async throws {
        let target = try revision()
        let transport = Transport()
        transport.states = [.success(state(target))]
        _ = try await ContentDeployment(deviceID: "reader", transport: transport).deploy(target)
        XCTAssertEqual(transport.events, ["state"])
    }

    func testSkipsOnlyExactVerifiedCandidateFiles() async throws {
        let target = try revision()
        let asset = try XCTUnwrap(target.files.first)
        for exact in [true, false] {
            let transport = Transport()
            transport.states = [.success(state()), .success(state(target))]
            transport.verifiedFiles = [.init(path: asset.path, kind: asset.kind,
                                             bytes: UInt32(asset.data.count),
                                             sha256: exact ? asset.sha256 : Data(repeating: 0, count: 32))]
            _ = try await ContentDeployment(deviceID: "reader", transport: transport).deploy(target)
            XCTAssertEqual(transport.events.contains("upload:" + asset.path), !exact)
        }
    }

    func testLostActivationResponseResolvesWithoutRepeatingCommand() async throws {
        let target = try revision()
        let transport = Transport()
        transport.activationError = Fault.disconnected
        transport.states = [.success(state()), .success(state(target))]
        _ = try await ContentDeployment(deviceID: "reader", transport: transport).deploy(target)
        XCTAssertEqual(transport.events.filter { $0 == "activate" }.count, 1)
        XCTAssertEqual(transport.events.filter { $0 == "state" }.count, 2)
    }

    func testDelayedConfirmationReadsOnlyAndRejectsStaleOrWrongReader() async throws {
        let target = try revision()
        let previous = try ContentRevision(cards: [])
        let transport = Transport()
        transport.states = [.success(state(previous)), .failure(Fault.disconnected)]
        let deployment = ContentDeployment(deviceID: "reader", transport: transport)
        do { _ = try await deployment.deploy(target); XCTFail("Lost confirmation") } catch { }
        let writes = transport.events
        for response in [state(target, id: "wrong"), state(target), state(previous)] {
            do {
                _ = try await deployment.confirmPendingActivation { response }
                XCTFail("Wrong identity, stale generation or wrong revision")
            } catch { XCTAssertEqual(deployment.phase, .needsConfirmation) }
            XCTAssertEqual(transport.events, writes)
        }
        let expected = ContentActiveReceipt(revision: target.revision, generation: 3)
        let receipt = try await deployment.confirmPendingActivation {
            .init(deviceID: "reader", schema: 1, capabilities: 3, active: expected)
        }
        XCTAssertEqual(receipt, expected)
        XCTAssertEqual(deployment.phase, .complete(expected))
        XCTAssertEqual(transport.events, writes)
        do {
            _ = try await deployment.confirmPendingActivation()
            XCTFail("Confirmation is already resolved")
        } catch { XCTAssertEqual(error as? ContentDeployment.Failure, .notConfirmed) }
        XCTAssertEqual(transport.events, writes)
    }

    func testCancelledConfirmationPreservesPendingOutcomeAndCanRetryRead() async throws {
        let target = try revision()
        let transport = Transport()
        transport.states = [.success(state()), .failure(Fault.disconnected)]
        let deployment = ContentDeployment(deviceID: "reader", transport: transport)
        do { _ = try await deployment.deploy(target); XCTFail("Lost confirmation") } catch { }
        do {
            _ = try await deployment.confirmPendingActivation { throw CancellationError() }
            XCTFail("Cancelled read")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(deployment.phase, .needsConfirmation)
        transport.states = [.success(state(target))]
        let before = transport.events
        _ = try await deployment.confirmPendingActivation()
        XCTAssertEqual(transport.events, before + ["state"])
        XCTAssertEqual(transport.events.filter { $0 == "activate" }.count, 1)
    }

    func testOldOrUnreadableStateAfterActivationRemainsUnconfirmed() async throws {
        for unavailable in [false, true] {
            let transport = Transport()
            transport.states = [.success(state()), unavailable ? .failure(Fault.disconnected) : .success(state())]
            let deployment = ContentDeployment(deviceID: "reader", transport: transport)
            do {
                _ = try await deployment.deploy(revision())
                XCTFail("Must not infer success from activation response")
            } catch {
                XCTAssertEqual(deployment.phase, .needsConfirmation)
                XCTAssertEqual(transport.events.filter { $0 == "activate" }.count, 1)
            }
        }
    }

    func testWrongReaderOrUnsupportedCapabilityFailsBeforeMutation() async throws {
        for initial in [state(id: "other"), state(capabilities: 0)] {
            let transport = Transport()
            transport.states = [.success(initial)]
            let deployment = ContentDeployment(deviceID: "reader", transport: transport)
            do {
                _ = try await deployment.deploy(revision())
                XCTFail("Must reject incompatible destination")
            } catch {
                XCTAssertEqual(deployment.phase, .failed)
                XCTAssertEqual(transport.events, ["state"])
            }
        }
    }

    func testPreparationIdentityAndDuplicateInventoryAreRejected() async throws {
        let target = try revision()
        let asset = try XCTUnwrap(target.files.first)
        let file = ContentManifest.File(path: asset.path, kind: asset.kind,
                                        bytes: UInt32(asset.data.count), sha256: asset.sha256)
        for wrongIdentity in [true, false] {
            let transport = Transport()
            transport.states = [.success(state())]
            transport.preparationID = wrongIdentity ? "other" : "reader"
            transport.verifiedFiles = wrongIdentity ? [] : [file, file]
            let deployment = ContentDeployment(deviceID: "reader", transport: transport)
            do {
                _ = try await deployment.deploy(target)
                XCTFail("Must reject invalid preparation")
            } catch {
                XCTAssertEqual(transport.events, ["state", "prepare"])
                XCTAssertEqual(deployment.phase, .failed)
            }
        }
    }

    func testConfirmationRejectsChangedReaderAndNonAdvancingGeneration() async throws {
        let target = try revision()
        let previous = try ContentRevision(cards: [])
        for changedReader in [true, false] {
            let transport = Transport()
            transport.states = [.success(state(previous)),
                                .success(state(target, id: changedReader ? "other" : "reader"))]
            let deployment = ContentDeployment(deviceID: "reader", transport: transport)
            do {
                _ = try await deployment.deploy(target)
                XCTFail("Must not accept another reader or stale generation")
            } catch {
                XCTAssertEqual(deployment.phase, .needsConfirmation)
                XCTAssertEqual(error as? ContentDeployment.Failure,
                               changedReader ? .identityMismatch : .invalidReceipt)
            }
        }
    }

    func testCancellationBeforeAndDuringActivationHaveDifferentOutcomes() async throws {
        for duringActivation in [false, true] {
            let transport = Transport()
            transport.states = [.success(state())]
            if duringActivation { transport.activationError = CancellationError() }
            else { transport.uploadError = CancellationError() }
            let deployment = ContentDeployment(deviceID: "reader", transport: transport)
            do {
                _ = try await deployment.deploy(revision())
                XCTFail("Expected cancellation")
            } catch is CancellationError {
                XCTAssertEqual(deployment.phase, duringActivation ? .needsConfirmation : .cancelled)
                XCTAssertEqual(transport.events.contains("activate"), duringActivation)
            }
        }
    }

    func testConcurrentDeploymentIsRejectedWithoutChangingInFlightPhase() async throws {
        let target = try revision()
        let transport = Transport()
        transport.states = [.success(state(target))]
        let entered = expectation(description: "read suspended")
        transport.onRead = { entered.fulfill() }
        let deployment = ContentDeployment(deviceID: "reader", transport: transport)
        let first = Task { try await deployment.deploy(target) }
        await fulfillment(of: [entered], timeout: 2)
        do {
            _ = try await deployment.deploy(target)
            XCTFail("Expected busy")
        } catch {
            XCTAssertEqual(error as? ContentDeployment.Failure, .busy)
            XCTAssertEqual(deployment.phase, .checking)
        }
        transport.suspendRead?.resume()
        _ = try await first.value
        XCTAssertEqual(transport.events, ["state"])
    }
}
