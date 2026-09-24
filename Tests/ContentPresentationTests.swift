import XCTest
@testable import Pocket

@MainActor
final class ContentPresentationTests: XCTestCase {
    private let active = ContentActiveReceipt(revision: String(repeating: "a", count: 64), generation: 7)
    private func receipt(_ phase: ContentPresentationReceipt.Phase, id: String = "1234ABCD", generation: UInt32 = 7) -> ContentPresentationReceipt {
        .init(schema: 1, deviceID: id, revision: active.revision, generation: generation, phase: phase)
    }

    func testQueuesOnceAndReadsUntilRendered() async throws {
        var requests = 0, reads = 0, waits = 0
        try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
            request: { requests += 1; return self.receipt(.queued) },
            state: { reads += 1; return self.receipt(reads == 1 ? .queued : .rendered) },
            wait: { waits += 1 }))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(waits, 2)
    }

    func testLostRequestResponseIsResolvedWithoutRepeatingMutation() async throws {
        var requests = 0, reads = 0
        try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
            request: { requests += 1; throw URLError(.networkConnectionLost) },
            state: { reads += 1; return self.receipt(.rendered) }, wait: {}))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(reads, 1)
    }

    func testFailedWrongReaderAndWrongGenerationCannotBecomeSuccess() async throws {
        for result in [receipt(.failed), receipt(.rendered, id: "9999FFFF"), receipt(.rendered, generation: 8)] {
            var reads = 0
            do {
                try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
                    request: { result }, state: { reads += 1; return result }, wait: {}))
                XCTFail("Invalid display result")
            } catch { XCTAssertEqual(reads, 0) }
        }
    }

    func testFailedRecoveryPreservesOriginalRejectionWithoutRepeatingPost() async throws {
        var requests = 0, reads = 0
        let original = NSError(domain: "ReaderPresentation", code: 503,
                               userInfo: [NSLocalizedDescriptionKey: "Reader memory is too low for content presentation"])
        do {
            try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
                request: { requests += 1; throw original },
                state: { reads += 1; throw URLError(.badServerResponse) }, wait: {}))
            XCTFail("Rejected display request")
        } catch {
            XCTAssertEqual(error as NSError, original)
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(reads, 1)
        }
    }

    func testCancellationInRequestOrRecoveryRemainsCancellation() async throws {
        for cancelRequest in [true, false] {
            var reads = 0
            do {
                try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
                    request: {
                        if cancelRequest { throw CancellationError() }
                        throw URLError(.networkConnectionLost)
                    },
                    state: { reads += 1; throw CancellationError() }, wait: {}))
                XCTFail("Cancelled")
            } catch {
                XCTAssertTrue(error is CancellationError)
                XCTAssertEqual(reads, cancelRequest ? 0 : 1)
            }
        }
    }

    func testPendingPaintHasFiniteReadBudgetAndNeverRepeatsPost() async throws {
        var requests = 0, reads = 0
        do {
            try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
                request: { requests += 1; return self.receipt(.queued) },
                state: { reads += 1; return self.receipt(.queued) }, wait: {}))
            XCTFail("Never rendered")
        } catch {
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(reads, ContentPresenter.maximumStateReads)
        }
    }

    func testCancellationDuringWaitDoesNotPollOrRepeat() async throws {
        var reads = 0
        do {
            try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
                request: { self.receipt(.queued) },
                state: { reads += 1; return self.receipt(.rendered) }, wait: { throw CancellationError() }))
            XCTFail("Cancelled")
        } catch { XCTAssertTrue(error is CancellationError); XCTAssertEqual(reads, 0) }
    }

    func testQueuedPaintSurvivesTemporaryHTTPUnavailabilityWithoutRepeatingPost() async throws {
        var requests = 0, reads = 0
        var time: TimeInterval = 0
        try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
            request: { requests += 1; return self.receipt(.queued) },
            state: {
                reads += 1
                time += 15
                if reads == 1 { throw URLError(.timedOut) }
                if reads == 2 { throw URLError(.networkConnectionLost) }
                return self.receipt(.rendered)
            }, wait: { time += 2 }, now: { time }))
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(reads, 3)
    }

    func testQueuedPaintDeadlineStopsReadsEvenWhenTransportKeepsFailing() async throws {
        var requests = 0, reads = 0
        var time: TimeInterval = 0
        do {
            try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
                request: { requests += 1; return self.receipt(.queued) },
                state: { reads += 1; time += 30; throw URLError(.timedOut) },
                wait: { time += 2 }, now: { time }))
            XCTFail("Unconfirmed paint")
        } catch {
            XCTAssertEqual(error.localizedDescription, ContentPresenter.Failure.unconfirmed.localizedDescription)
        }
        XCTAssertEqual(requests, 1)
        XCTAssertEqual(reads, 3)
    }

    func testDeadlineDuringWaitDoesNotStartAnotherRead() async throws {
        var reads = 0
        var time: TimeInterval = 0
        do {
            try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
                request: { self.receipt(.queued) }, state: { reads += 1; return self.receipt(.rendered) },
                wait: { time = 90 }, now: { time }))
            XCTFail("Budget expired")
        } catch {
            XCTAssertEqual(error.localizedDescription, ContentPresenter.Failure.unconfirmed.localizedDescription)
        }
        XCTAssertEqual(reads, 0)
    }

    func testQueuedPaintDoesNotRetryCancellationOrInvalidReceipt() async throws {
        for failure: Error in [CancellationError(), URLError(.cancelled), ContentDeployment.Failure.invalidReceipt] {
            var reads = 0
            do {
                try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
                    request: { self.receipt(.queued) }, state: { reads += 1; throw failure }, wait: {}))
                XCTFail("Invalid receipt or cancellation")
            } catch { XCTAssertEqual(reads, 1) }
        }
    }

    func testDecoderRejectsMalformedStaleAndOversizedResults() throws {
        let good = "{\"schema\":1,\"deviceID\":\"1234ABCD\",\"revision\":\"\(active.revision)\",\"generation\":7,\"phase\":\"rendered\"}"
        XCTAssertEqual(try ContentPresentationReceipt.decode(Data(good.utf8), deviceID: "1234ABCD", active: active).phase, .rendered)
        for bad in [good.replacingOccurrences(of: "rendered", with: "idle"),
                    good.replacingOccurrences(of: "\"generation\":7", with: "\"generation\":0"),
                    good.replacingOccurrences(of: "1234ABCD", with: "9999FFFF"),
                    good.replacingOccurrences(of: "\"schema\":1", with: "\"schema\":2"),
                    String(repeating: " ", count: 513), "{}"] {
            XCTAssertThrowsError(try ContentPresentationReceipt.decode(Data(bad.utf8), deviceID: "1234ABCD", active: active))
        }
    }

    func testDeferredFailureReceiptIsActionableAndNeverRetriesRequest() async throws {
        for reason in ["memory", "preparation", "display", "future-reason"] {
            let json = "{\"schema\":1,\"deviceID\":\"1234ABCD\",\"revision\":\"\(active.revision)\",\"generation\":7,\"phase\":\"failed\",\"failure\":\"\(reason)\"}"
            let failed = try ContentPresentationReceipt.decode(Data(json.utf8), deviceID: "1234ABCD", active: active)
            XCTAssertEqual(failed.failure, reason)
            var requests = 0, reads = 0
            do {
                try await ContentPresenter.present(deviceID: "1234ABCD", active: active, using: .init(
                    request: { requests += 1; return self.receipt(.queued) },
                    state: { reads += 1; return failed }, wait: {}))
                XCTFail("Deferred rejection")
            } catch {
                let expected: ContentPresenter.Failure = reason == "memory" ? .memory : reason == "preparation" ? .preparation : .failed
                XCTAssertEqual(error.localizedDescription, expected.localizedDescription)
            }
            XCTAssertEqual(requests, 1)
            XCTAssertEqual(reads, 1)
        }
    }
}
