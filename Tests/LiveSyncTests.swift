import XCTest
@testable import Pocket

/// M2: live-studio event decoding and the frame-fetch coalescing policy
/// (`docs/live-studio-v1.md` in the firmware repository).
final class LiveSyncTests: XCTestCase {
    private func statusJSON() -> String {
        """
        {"version":"1.4.1","ip":"192.168.68.64","mode":"STA","rssi":-44,"freeHeap":13000,
        "uptime":120,"device":"X3","deviceID":"5B09AF70",
        "liveStudio":{"wsPort":81,"mode":"push","frameStream":true,"uiPacks":false,
        "activePack":null,"activePackVersion":null}}
        """
    }

    // MARK: Event decoding

    func testDecodeHello() {
        let event = LiveStudioEvent.decode(
            #"{"hello":{"proto":"live-studio/1","deviceID":"5B09AF70","version":"1.4.1","caps":["status","prefs"]}}"#
        )
        XCTAssertEqual(event, .hello(proto: "live-studio/1", deviceID: "5B09AF70", version: "1.4.1"))
    }

    func testDecodeStatus() {
        let json = """
        {"status":{"version":"1.4.1","ip":"192.168.68.64","mode":"STA","rssi":-44,"freeHeap":13000,"uptime":120,"device":"X3","deviceID":"5B09AF70","liveStudio":{"wsPort":81,"mode":"push","frameStream":true,"uiPacks":false,"activePack":null,"activePackVersion":null}}}
        """
        guard case let .status(status) = LiveStudioEvent.decode(json) ?? .bye else {
            return XCTFail("did not decode status")
        }
        XCTAssertEqual(status.deviceID, "5B09AF70")
        XCTAssertEqual(status.liveStudio?.mode, "push")
        XCTAssertEqual(status.liveStudio?.frameStream, true)
    }

    func testDecodeFramePrefsBye() {
        XCTAssertEqual(LiveStudioEvent.decode(#"{"frame":{"seq":7,"bytes":53918}}"#),
                       .frame(seq: 7, bytes: 53918))
        XCTAssertEqual(LiveStudioEvent.decode(#"{"prefs":{"changed":true}}"#), .prefsChanged)
        XCTAssertEqual(LiveStudioEvent.decode(#"{"bye":{}}"#), .bye)
    }

    func testDecodeRejectsMalformed() {
        XCTAssertNil(LiveStudioEvent.decode(""))
        XCTAssertNil(LiveStudioEvent.decode("not json"))
        XCTAssertNil(LiveStudioEvent.decode(#"{"unknown":1}"#))
        XCTAssertNil(LiveStudioEvent.decode(#"{"frame":{"seq":"x","bytes":1}}"#))
        XCTAssertNil(LiveStudioEvent.decode(#"{"prefs":{"changed":false}}"#))
        // Multi-key objects are not part of the single-key envelope.
        XCTAssertNil(LiveStudioEvent.decode(#"{"hello":{"proto":"live-studio/1"},"bye":{}}"#))
    }

    // MARK: Fetch policy

    func testFetchPolicyCoalescesWhileInFlight() {
        var policy = FrameFetchPolicy()
        XCTAssertTrue(policy.shouldFetch(seq: 1, at: Date(timeIntervalSince1970: 100)))
        // While the first fetch runs, newer frames only mark pending.
        XCTAssertFalse(policy.shouldFetch(seq: 2, at: Date(timeIntervalSince1970: 100.5)))
        XCTAssertFalse(policy.shouldFetch(seq: 3, at: Date(timeIntervalSince1970: 101)))
        // Completing returns the newest pending seq, not the intermediate one.
        XCTAssertEqual(policy.fetchCompleted(), 3)
        // Spacing counts from fetch starts: 101.2 is 1.2 s after 100, so the
        // follow-up may begin; 101.5 is only 0.3 s later and must wait.
        XCTAssertTrue(policy.shouldFetch(seq: 4, at: Date(timeIntervalSince1970: 101.2)))
        XCTAssertNil(policy.fetchCompleted())
        XCTAssertFalse(policy.shouldFetch(seq: 5, at: Date(timeIntervalSince1970: 101.5)))
        XCTAssertEqual(policy.fetchCompleted(), 5)
    }

    func testFetchPolicySpacesFetches() {
        var policy = FrameFetchPolicy()
        XCTAssertTrue(policy.shouldFetch(seq: 1, at: Date(timeIntervalSince1970: 0)))
        XCTAssertNil(policy.fetchCompleted())
        XCTAssertFalse(policy.shouldFetch(seq: 2, at: Date(timeIntervalSince1970: 0.5)))
        XCTAssertEqual(policy.fetchCompleted(), 2)  // pending drains to the caller
        XCTAssertTrue(policy.shouldFetch(seq: 3, at: Date(timeIntervalSince1970: 1.6)))
    }

    func testFetchPolicyReset() {
        var policy = FrameFetchPolicy()
        XCTAssertTrue(policy.shouldFetch(seq: 1, at: Date(timeIntervalSince1970: 0)))
        policy.reset()
        XCTAssertFalse(policy.inFlight)
        XCTAssertNil(policy.fetchCompleted())
    }
}
