import XCTest
@testable import Pocket

final class ContentSendStatusTests: XCTestCase {
    private let active = ContentActiveReceipt(revision: String(repeating: "a", count: 64), generation: 5)

    private func inputs(_ change: (inout ContentSendStatus.Inputs) -> Void = { _ in }) -> ContentSendStatus.Inputs {
        var value = ContentSendStatus.Inputs(isDemo: false, connected: true, canPresent: true, validation: nil,
                                             cardCount: 1, draftRevision: active.revision, phase: nil,
                                             redrawConfirmed: nil, busy: false)
        change(&value)
        return value
    }

    func testDemoNeverSendsEvenWithAValidDraft() {
        let status = ContentSendStatus.evaluate(inputs { $0.isDemo = true })
        XCTAssertEqual(status, .demo)
        XCTAssertFalse(ContentSendStatus.canSend(status, busy: false, autoSend: false))
    }

    func testConnectionAndCapabilityGateSending() {
        XCTAssertEqual(ContentSendStatus.evaluate(inputs { $0.connected = false }), .disconnected)
        XCTAssertEqual(ContentSendStatus.evaluate(inputs { $0.canPresent = false }), .unsupported)
        XCTAssertFalse(ContentSendStatus.canSend(.disconnected, busy: false, autoSend: false))
        XCTAssertFalse(ContentSendStatus.canSend(.unsupported, busy: false, autoSend: false))
    }

    func testEmptyDraftDoesNotSilentlyClearTheReader() {
        let status = ContentSendStatus.evaluate(inputs { $0.cardCount = 0; $0.validation = "Check title" })
        XCTAssertEqual(status, .empty)
        XCTAssertFalse(ContentSendStatus.canSend(status, busy: false, autoSend: false))
    }

    func testInvalidDraftExplainsWhy() {
        let status = ContentSendStatus.evaluate(inputs { $0.validation = "Check title"; $0.draftRevision = nil })
        XCTAssertEqual(status, .invalid("Check title"))
        XCTAssertEqual(status.label, "Check title")
        XCTAssertFalse(ContentSendStatus.canSend(status, busy: false, autoSend: false))
    }

    func testShownOnlyAfterRedrawReceiptForTheExactCanvasRevision() {
        let stored = ContentSendStatus.evaluate(inputs { $0.phase = .complete(active) })
        XCTAssertEqual(stored, .storedNotShown)
        XCTAssertTrue(ContentSendStatus.canSend(stored, busy: false, autoSend: false))

        let shown = ContentSendStatus.evaluate(inputs { $0.phase = .complete(active); $0.redrawConfirmed = active })
        XCTAssertEqual(shown, .shown)
        XCTAssertFalse(ContentSendStatus.canSend(shown, busy: false, autoSend: false), "Resending identical cards only refreshes e-ink")

        let edited = ContentSendStatus.evaluate(inputs {
            $0.phase = .complete(active); $0.redrawConfirmed = active; $0.draftRevision = String(repeating: "b", count: 64)
        })
        XCTAssertEqual(edited, .changed)
        XCTAssertTrue(ContentSendStatus.canSend(edited, busy: false, autoSend: false))
    }

    func testInFlightPhasesReportProgressAndBlockSend() {
        let cases: [(ContentDeployment.Phase, String)] = [
            (.checking, "Checking the reader"), (.preparing, "Preparing cards"),
            (.uploading(path: "x", index: 1, total: 2), "Sending file 1 of 2"),
            (.activating, "Activating on the reader"), (.confirming, "Waiting for the reader to show it"),
        ]
        for (phase, step) in cases {
            let status = ContentSendStatus.evaluate(inputs { $0.phase = phase; $0.connected = false })
            XCTAssertEqual(status, .sending(step), "Progress must survive a transient status gap")
            XCTAssertFalse(ContentSendStatus.canSend(status, busy: false, autoSend: false))
        }
    }

    func testUnknownOutcomeRequiresACheckBeforeAnotherSend() {
        for phase in [ContentDeployment.Phase.needsConfirmation, .archived] {
            let status = ContentSendStatus.evaluate(inputs { $0.phase = phase })
            XCTAssertEqual(status, .needsCheck)
            XCTAssertFalse(ContentSendStatus.canSend(status, busy: false, autoSend: false))
        }
    }

    func testFailureAllowsAnExplicitRetryButNotWhileBusyOrAutoSending() {
        let failed = ContentSendStatus.evaluate(inputs { $0.phase = .failed })
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(ContentSendStatus.canSend(failed, busy: false, autoSend: false))
        XCTAssertFalse(ContentSendStatus.canSend(failed, busy: true, autoSend: false))
        XCTAssertFalse(ContentSendStatus.canSend(.ready, busy: false, autoSend: true))
        XCTAssertEqual(ContentSendStatus.evaluate(inputs { $0.phase = .cancelled }), .failed)
    }

    func testReadyBeforeAnySendInThisSession() {
        XCTAssertEqual(ContentSendStatus.evaluate(inputs()), .ready)
        XCTAssertEqual(ContentSendStatus.evaluate(inputs { $0.phase = .idle }), .ready)
    }
}
