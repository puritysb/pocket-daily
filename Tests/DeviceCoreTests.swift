import XCTest
@testable import Pocket

/// M1 core seams: the pure device-state reducer, the sync-mode policy, and
/// the `liveStudio` capability advertisement from `/api/status`
/// (`docs/live-studio-v1.md` in the firmware repository).
final class DeviceCoreTests: XCTestCase {
    private func status(
        device: String = "X3",
        deviceID: String? = "ABCD1234",
        liveStudio: LiveStudioAdvertisement? = nil
    ) -> CrossPointStatus {
        CrossPointStatus(
            version: "1.4.1", ip: "192.168.68.10", mode: "STA", rssi: -55,
            freeHeap: 90_000, uptime: 120, device: device,
            crashReportAvailable: false, crashReportBytes: 0,
            screenPreviewAvailable: false, screenPreviewBytes: 0,
            uploadChunkBytes: nil, uploadStreamPort: 82, uploadStreamResume: true,
            diagnosticsAffordable: true, deviceID: deviceID, sessionEnd: false,
            liveStudio: liveStudio
        )
    }

    // MARK: Reducer

    func testStatusEventConnectsAndStores() {
        let state = DeviceStateReducer.apply(.status(status()), to: DeviceState())
        XCTAssertEqual(state.phase, .connected)
        XCTAssertEqual(state.status?.version, "1.4.1")
    }

    func testFrameEventReplacesLatestAndAdvancesSequence() {
        var state = DeviceStateReducer.apply(
            .frame(seq: 4, capturedAt: Date(timeIntervalSince1970: 100), data: Data([1])),
            to: DeviceState()
        )
        XCTAssertEqual(state.frameSequence, 4)
        XCTAssertEqual(state.latestFrame?.seq, 4)
        state = DeviceStateReducer.apply(
            .frame(seq: 2, capturedAt: Date(timeIntervalSince1970: 200), data: Data([2])),
            to: state
        )
        // A stale reader sequence must not roll the counter back.
        XCTAssertEqual(state.frameSequence, 5)
        XCTAssertEqual(state.latestFrame?.seq, 2)
        XCTAssertEqual(state.latestFrame?.data, Data([2]))
    }

    func testDisconnectClearsDeviceDerivedState() {
        var state = DeviceStateReducer.apply(.status(status()), to: DeviceState())
        state = DeviceStateReducer.apply(
            .frame(seq: 1, capturedAt: Date(), data: Data([9])), to: state
        )
        state = DeviceStateReducer.apply(.preferences(ReaderPreferences()), to: state)
        state = DeviceStateReducer.apply(.transferProgress(0.5), to: state)
        state = DeviceStateReducer.apply(.connection(.disconnected), to: state)
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertNil(state.status)
        XCTAssertNil(state.preferences)
        XCTAssertNil(state.latestFrame)
        XCTAssertNil(state.transferProgress)
        // Preferences survive when a disconnect did not happen.
        var kept = DeviceStateReducer.apply(.preferences(ReaderPreferences()), to: DeviceState())
        kept = DeviceStateReducer.apply(.connection(.connected), to: kept)
        XCTAssertNotNil(kept.preferences)
    }

    func testPackStateChanged() {
        let state = DeviceStateReducer.apply(
            .packStateChanged(activePack: "serenity", version: "1.2"), to: DeviceState()
        )
        XCTAssertEqual(state.activePack, "serenity")
        XCTAssertEqual(state.activePackVersion, "1.2")
        let cleared = DeviceStateReducer.apply(.packStateChanged(activePack: nil, version: nil), to: state)
        XCTAssertNil(cleared.activePack)
        XCTAssertNil(cleared.activePackVersion)
    }

    @MainActor
    func testMirrorAppliesEventsToPublishedState() {
        let mirror = DeviceMirror()
        mirror.apply(.connection(.searching))
        XCTAssertEqual(mirror.state.phase, .searching)
        mirror.apply(.status(status()))
        XCTAssertEqual(mirror.state.phase, .connected)
    }

    // MARK: Sync mode policy

    func testSyncModeOfflineWithoutReaderOrInDemo() {
        XCTAssertEqual(SyncModePolicy.syncMode(status: nil), .offline)
        XCTAssertEqual(SyncModePolicy.syncMode(status: status(), isDemoMode: true), .offline)
    }

    func testSyncModePollForLegacyOrNonPushReaders() {
        XCTAssertEqual(SyncModePolicy.syncMode(status: status(liveStudio: nil)), .poll)
        XCTAssertEqual(
            SyncModePolicy.syncMode(
                status: status(liveStudio: LiveStudioAdvertisement(
                    wsPort: nil, mode: "poll", frameStream: false, uiPacks: false,
                    activePack: nil, activePackVersion: nil
                ))
            ),
            .poll
        )
        XCTAssertEqual(
            SyncModePolicy.syncMode(
                status: status(liveStudio: LiveStudioAdvertisement(
                    wsPort: 0, mode: "push", frameStream: false, uiPacks: false,
                    activePack: nil, activePackVersion: nil
                ))
            ),
            .poll
        )
    }

    func testSyncModePushWhenListenerAdvertised() {
        XCTAssertEqual(
            SyncModePolicy.syncMode(
                status: status(liveStudio: LiveStudioAdvertisement(
                    wsPort: 81, mode: "push", frameStream: false, uiPacks: false,
                    activePack: nil, activePackVersion: nil
                ))
            ),
            .push(wsPort: 81)
        )
    }

    // MARK: Advertisement decoding

    func testLegacyStatusDecodesWithoutLiveStudio() {
        let json = """
        {"version":"1.4.1","ip":"192.168.68.10","mode":"STA","rssi":-55,"freeHeap":90000,
        "uptime":120,"device":"X3","deviceID":"ABCD1234","sessionEnd":false}
        """.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(CrossPointStatus.self, from: json)
        XCTAssertNotNil(decoded)
        XCTAssertNil(decoded?.liveStudio)
        XCTAssertEqual(SyncModePolicy.syncMode(status: decoded), .poll)
    }

    func testLiveStudioAdvertisementDecodes() {
        let json = """
        {"version":"1.4.1","ip":"192.168.68.10","mode":"STA","rssi":-55,"freeHeap":90000,
        "uptime":120,"device":"X3","deviceID":"ABCD1234","sessionEnd":false,
        "liveStudio":{"wsPort":81,"mode":"push","frameStream":false,"uiPacks":false,
        "activePack":null,"activePackVersion":null}}
        """.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode(CrossPointStatus.self, from: json)
        XCTAssertEqual(decoded?.liveStudio?.mode, "push")
        XCTAssertEqual(decoded?.liveStudio?.wsPort, 81)
        XCTAssertEqual(SyncModePolicy.syncMode(status: decoded), .push(wsPort: 81))
    }
}
