import XCTest
@testable import Pocket

/// Live-studio event decoding (`docs/live-studio-v1.md` in the firmware
/// repository): status and preference pushes only; frames were removed.
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
        XCTAssertEqual(status.liveStudio?.wsPort, 81, "Older readers' pack and frame keys are ignored")
    }

    func testDecodePrefsByeAndIgnoreFrames() {
        XCTAssertNil(LiveStudioEvent.decode(#"{"frame":{"seq":7,"bytes":53918}}"#),
                     "Frame announcements from older readers are not events any more")
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

}
