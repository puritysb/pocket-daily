import XCTest
@testable import Pocket

@MainActor
final class ContentLiveApplyTests: XCTestCase {
    private func revision(_ title: String) throws -> ContentRevision {
        try ContentRevision(cards: [.init(id: "card", title: title, question: "Text")])
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Live apply did not reach the expected state")
    }

    func testOptInCoalescesEditsAndSkipsConfirmedContent() async throws {
        let live = ContentLiveApply(settle: { try await Task.sleep(for: .milliseconds(5)) })
        defer { live.stop() }
        let first = try revision("First"), latest = try revision("Latest")
        var sent: [String] = []
        live.update(first)
        XCTAssertFalse(live.isEnabled)
        live.start(revision: first) { sent.append($0.revision); return true }
        live.update(latest)
        try await waitUntil { live.message.contains("redraw confirmed") }
        XCTAssertEqual(sent, [latest.revision])
        live.update(latest)
        try await waitUntil { live.message.contains("redraw confirmed") }
        XCTAssertEqual(sent, [latest.revision])
    }

    func testOnlyNewestEditFollowsInFlightApply() async throws {
        let live = ContentLiveApply(settle: { try await Task.sleep(for: .milliseconds(5)) })
        defer { live.stop() }
        var held: CheckedContinuation<Bool, Never>?
        var sent: [String] = []
        let first = try revision("First"), middle = try revision("Middle"), latest = try revision("Latest")
        live.start(revision: first) {
            sent.append($0.revision)
            if sent.count == 1 { return await withCheckedContinuation { held = $0 } }
            return true
        }
        try await waitUntil { held != nil }
        live.update(middle)
        live.update(latest)
        XCTAssertEqual(sent, [first.revision])
        held?.resume(returning: true)
        try await waitUntil { live.message.contains("redraw confirmed") }
        XCTAssertEqual(sent, [first.revision, latest.revision])
    }

    func testInvalidDraftClearsQueuedRevisionAndFailureStopsWithoutRetry() async throws {
        let live = ContentLiveApply(settle: { try await Task.sleep(for: .milliseconds(5)) })
        defer { live.stop() }
        var sent = 0
        let first = try revision("First")
        live.start(revision: first) { _ in sent += 1; return false }
        live.update(nil)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(live.isEnabled)
        live.update(first)
        try await waitUntil { !live.isEnabled }
        live.update(first)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sent, 1)
        XCTAssertTrue(live.message.contains("stopped"))
    }

    func testStopDiscardsQueuedEditsAndIgnoresLateCompletion() async throws {
        let live = ContentLiveApply(settle: { try await Task.sleep(for: .milliseconds(5)) })
        var held: CheckedContinuation<Bool, Never>?
        var sent = 0
        live.start(revision: try revision("First")) { _ in
            sent += 1
            return await withCheckedContinuation { held = $0 }
        }
        try await waitUntil { held != nil }
        live.update(try revision("Next"))
        live.stop()
        held?.resume(returning: true)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(sent, 1)
        XCTAssertFalse(live.isEnabled)
        XCTAssertEqual(live.message, "Live apply is off.")
    }
}
