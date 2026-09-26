import XCTest

@testable import Pocket

/// Drawing a saved Home or Daily Brief inside Sync
/// (sibling docs/pocket-screen-present-v1.md): receipts bind to one reader,
/// screen and profile generation, and only reads follow a request.
@MainActor
final class ScreenPresentationTests: XCTestCase {
    private func receipt(surface: String = "home", generation: UInt32 = 7, phase: String = "rendered",
                         failure: String = "none", deviceID: String = "5B09AF70") -> ScreenPresentationReceipt {
        let json = #"{"schema":1,"deviceID":"\#(deviceID)","surface":"\#(surface)","generation":\#(generation),"phase":"\#(phase)","failure":"\#(failure)","heap":20000,"block":8000}"#
        return try! JSONDecoder().decode(ScreenPresentationReceipt.self, from: Data(json.utf8))
    }

    func testReceiptMustMatchReaderScreenAndGeneration() throws {
        let data = Data(#"{"schema":1,"deviceID":"5B09AF70","surface":"brief","generation":3,"phase":"queued","failure":"none","heap":0,"block":0}"#.utf8)
        let decoded = try ScreenPresentationReceipt.decode(data, deviceID: "5B09AF70", screen: .brief, generation: 3)
        XCTAssertEqual(decoded.phase, .queued)
        XCTAssertThrowsError(try ScreenPresentationReceipt.decode(data, deviceID: "5B09AF70", screen: .home, generation: 3))
        XCTAssertThrowsError(try ScreenPresentationReceipt.decode(data, deviceID: "5B09AF70", screen: .brief, generation: 4))
        XCTAssertThrowsError(try ScreenPresentationReceipt.decode(data, deviceID: "00000000", screen: .brief, generation: 3))
        XCTAssertThrowsError(try ScreenPresentationReceipt.decode(Data(#"{"schema":2}"#.utf8), deviceID: "5B09AF70",
                                                                  screen: .brief, generation: 3))
        XCTAssertThrowsError(try ScreenPresentationReceipt.decode(Data(count: 600), deviceID: "5B09AF70",
                                                                  screen: .brief, generation: 3))
    }

    func testQueuedFrameIsFollowedWithReadsUntilRendered() async throws {
        var reads = 0
        try await ScreenPresenter.present(deviceID: "5B09AF70", screen: .home, generation: 7, using: .init(
            request: { self.receipt(phase: "queued") },
            state: { reads += 1; return self.receipt(phase: reads < 2 ? "queued" : "rendered") },
            wait: {}))
        XCTAssertEqual(reads, 2)
    }

    /// A lost POST response is resolved by reading; the request is never repeated.
    func testLostRequestIsResolvedByReadingOnly() async throws {
        var requests = 0
        try await ScreenPresenter.present(deviceID: "5B09AF70", screen: .home, generation: 7, using: .init(
            request: { requests += 1; throw URLError(.networkConnectionLost) },
            state: { self.receipt() },
            wait: {}))
        XCTAssertEqual(requests, 1)
    }

    func testFailuresAreReportedWithoutRetrying() async {
        for (failure, expected) in [("memory", ScreenPresenter.Failure.memory),
                                    ("preparation", .preparation), ("display", .failed)] {
            var requests = 0
            do {
                try await ScreenPresenter.present(deviceID: "5B09AF70", screen: .brief, generation: 7, using: .init(
                    request: { requests += 1; return self.receipt(surface: "brief", phase: "failed", failure: failure) },
                    state: { XCTFail("A failed receipt needs no reads"); return self.receipt() },
                    wait: {}))
                XCTFail("\(failure) must throw")
            } catch {
                XCTAssertEqual(error as? ScreenPresenter.Failure, expected)
            }
            XCTAssertEqual(requests, 1)
        }
    }

    func testAReceiptForAnotherScreenIsRejected() async {
        do {
            try await ScreenPresenter.present(deviceID: "5B09AF70", screen: .home, generation: 7, using: .init(
                request: { self.receipt(surface: "brief") }, state: { self.receipt() }, wait: {}))
            XCTFail("A receipt for another screen must not count")
        } catch {
            XCTAssertEqual(error as? ContentDeployment.Failure, .invalidReceipt)
        }
    }

    func testUnconfirmedFrameStopsAtTheBudget() async {
        var clock: TimeInterval = 0
        do {
            try await ScreenPresenter.present(deviceID: "5B09AF70", screen: .home, generation: 7, using: .init(
                request: { self.receipt(phase: "queued") },
                state: { self.receipt(phase: "queued") },
                wait: { clock += 30 },
                now: { clock }))
            XCTFail("An unconfirmed frame must stop")
        } catch {
            XCTAssertEqual(error as? ScreenPresenter.Failure, .unconfirmed)
        }
    }
}
