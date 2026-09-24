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

    func testFrameAnnouncementMatchesFirmwareUInt32AndClientSizeBounds() {
        XCTAssertEqual(LiveStudioEvent.decode(#"{"frame":{"seq":0,"bytes":64}}"#),
                       .frame(seq: 0, bytes: 64))
        XCTAssertEqual(LiveStudioEvent.decode(#"{"frame":{"seq":4294967295,"bytes":131072}}"#),
                       .frame(seq: Int(UInt32.max), bytes: 128 * 1024))
        for seq in ["-1", "4294967296", String(Int.max), "true", "false", "1.5", "null", "\"7\""] {
            XCTAssertNil(LiveStudioEvent.decode("{\"frame\":{\"seq\":\(seq),\"bytes\":53918}}"), seq)
        }
        for bytes in ["-1", "0", "63", "131073", "4294967295", "true", "64.5", "null", "\"64\""] {
            XCTAssertNil(LiveStudioEvent.decode("{\"frame\":{\"seq\":7,\"bytes\":\(bytes)}}"), bytes)
        }
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
        XCTAssertTrue(policy.shouldFetch(seq: 1, at: Date(timeIntervalSince1970: 0.1)))
    }

    func testPendingFrameHasDeadlineWithoutAnotherAnnouncement() {
        var policy = FrameFetchPolicy()
        let start = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(policy.shouldFetch(seq: 1, at: start))
        XCTAssertNil(policy.fetchCompleted())
        XCTAssertFalse(policy.shouldFetch(seq: 2, at: start.addingTimeInterval(0.2)))
        XCTAssertEqual(policy.delayUntilNextFetch(at: start.addingTimeInterval(0.2)), 0.8, accuracy: 0.001)
        XCTAssertEqual(policy.pendingSeq, 2)
        XCTAssertTrue(policy.shouldFetch(seq: 2, at: start.addingTimeInterval(1)))
        XCTAssertNil(policy.pendingSeq)
    }
}
