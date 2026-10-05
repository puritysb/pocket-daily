import XCTest
@testable import Pocket

/// M1 core seams: the pure device-state reducer, the sync-mode policy, and
/// the `liveStudio` capability advertisement from `/api/status`
/// (`docs/live-studio-v1.md` in the firmware repository).
final class DeviceCoreTests: XCTestCase {
    func testConnectionWorkerCancellationReachesDetachedOperation() async throws {
        let started = expectation(description: "worker started")
        let cancelled = expectation(description: "worker received cancellation")
        let finished = expectation(description: "request finished")
        let request = Task {
            defer { finished.fulfill() }
            do {
                try await ConnectionWorker.run {
                    try await withTaskCancellationHandler {
                        started.fulfill()
                        try await Task.sleep(for: .seconds(10))
                    } onCancel: {
                        cancelled.fulfill()
                    }
                }
                XCTFail("Cancelled connection reported success")
            } catch is CancellationError { }
            catch { XCTFail("Unexpected error: \(error)") }
        }
        defer { request.cancel() }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        await fulfillment(of: [cancelled, finished], timeout: 2)
        await request.value
    }

    private actor WorkerGate {
        private var opened = false
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async {
            if opened { return }
            await withCheckedContinuation { waiter = $0 }
        }
        func open() {
            opened = true
            waiter?.resume()
            waiter = nil
        }
    }

    func testConnectionWorkerRejectsLateSuccessAndPrecancelledRequests() async throws {
        let success = try await ConnectionWorker.run { 42 }
        XCTAssertEqual(success, 42)
        let gate = WorkerGate()
        let started = expectation(description: "noninterruptible work started")
        let request = Task {
            try await ConnectionWorker.run {
                started.fulfill()
                await gate.wait() // Models a system call that ignores cancellation.
                return 42
            }
        }
        await fulfillment(of: [started], timeout: 2)
        request.cancel()
        await gate.open()
        do { _ = try await request.value; XCTFail("Late success accepted") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }

        let beforeStart = WorkerGate()
        let cancelledRequest = Task {
            await beforeStart.wait()
            try await ConnectionWorker.run { XCTFail("Cancelled operation started") }
        }
        cancelledRequest.cancel()
        await beforeStart.open()
        do { try await cancelledRequest.value; XCTFail("Precancelled request accepted") }
        catch is CancellationError { }
        catch { XCTFail("Unexpected error: \(error)") }
    }

    private func status(
        device: String = "X3",
        deviceID: String? = "ABCD1234",
        freeHeap: Int = 90_000,
        liveStudio: LiveStudioAdvertisement? = nil
    ) -> CrossPointStatus {
        CrossPointStatus(
            version: "1.4.1", ip: "192.168.68.10", mode: "STA", rssi: -55,
            freeHeap: freeHeap, uptime: 120, device: device,
            crashReportAvailable: false, crashReportBytes: 0,
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

    func testNewLegacySessionClearsSnapshotEvenWithoutDistinctIdentity() {
        var state = DeviceStateReducer.apply(.status(status(deviceID: nil)), to: DeviceState())
        state = DeviceStateReducer.apply(.preferences(ReaderPreferences()), to: state)
        state = DeviceStateReducer.apply(.transferProgress(0.5), to: state)
        state = DeviceStateReducer.apply(.sessionStarted(status(deviceID: nil)), to: state)
        XCTAssertEqual(state.phase, .connected)
        XCTAssertNil(state.preferences)
        XCTAssertNil(state.transferProgress)
    }

    func testDisconnectClearsDeviceDerivedState() {
        var state = DeviceStateReducer.apply(.status(status()), to: DeviceState())
        state = DeviceStateReducer.apply(.preferences(ReaderPreferences()), to: state)
        state = DeviceStateReducer.apply(.transferProgress(0.5), to: state)
        state = DeviceStateReducer.apply(.connection(.disconnected), to: state)
        XCTAssertEqual(state.phase, .disconnected)
        XCTAssertNil(state.status)
        XCTAssertNil(state.preferences)
        XCTAssertNil(state.transferProgress)
        // Preferences survive when a disconnect did not happen.
        var kept = DeviceStateReducer.apply(.preferences(ReaderPreferences()), to: DeviceState())
        kept = DeviceStateReducer.apply(.connection(.connected), to: kept)
        XCTAssertNotNil(kept.preferences)
    }

    func testChangedIdentityClearsPreviousReaderDerivedState() {
        var state = DeviceStateReducer.apply(.status(status()), to: DeviceState())
        state = DeviceStateReducer.apply(.preferences(ReaderPreferences()), to: state)
        state = DeviceStateReducer.apply(.transferProgress(0.5), to: state)
        for replacement in [status(deviceID: "DIFFERENT"), status(deviceID: nil), status(device: "X4")] {
            let next = DeviceStateReducer.apply(.status(replacement), to: state)
            XCTAssertEqual(next.status, replacement)
            XCTAssertEqual(next.phase, .connected)
            XCTAssertNil(next.preferences)
            XCTAssertNil(next.transferProgress)
        }
        // The same reader refreshing its status keeps what was loaded for it.
        let refreshed = DeviceStateReducer.apply(.status(status()), to: state)
        XCTAssertNotNil(refreshed.preferences)
    }

    func testNonconnectedPhasesClearStatus() {
        let state = DeviceStateReducer.apply(.status(status()), to: DeviceState())
        for phase in [DeviceConnectionPhase.idle, .searching, .waitingForReader, .disconnected] {
            let next = DeviceStateReducer.apply(.connection(phase), to: state)
            XCTAssertEqual(next.phase, phase)
            XCTAssertNil(next.status)
        }
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
                status: status(liveStudio: LiveStudioAdvertisement(wsPort: nil, mode: "poll"))
            ),
            .poll
        )
        XCTAssertEqual(
            SyncModePolicy.syncMode(
                status: status(liveStudio: LiveStudioAdvertisement(wsPort: 0, mode: "push"))
            ),
            .poll
        )
    }

    func testSyncModePushWhenListenerAdvertised() {
        XCTAssertEqual(
            SyncModePolicy.syncMode(
                status: status(liveStudio: LiveStudioAdvertisement(wsPort: 81, mode: "push"))
            ),
            .push(wsPort: 81)
        )
    }

    func testAdvertisedListenerDoesNotOverrideCurrentMemoryAdmission() {
        let live = LiveStudioAdvertisement(wsPort: 81, mode: "push")
        for heap in [0, 10_624, 12_056, SyncModePolicy.minimumPushFreeHeap - 1] {
            let reader = status(freeHeap: heap, liveStudio: live)
            XCTAssertEqual(SyncModePolicy.syncMode(status: reader), .poll)
        }
        let reader = status(freeHeap: SyncModePolicy.minimumPushFreeHeap, liveStudio: live)
        XCTAssertEqual(SyncModePolicy.syncMode(status: reader), .push(wsPort: 81))
    }

    // MARK: Advertisement decoding

    func testDedicatedSyncAdvertisementKeepsBothBearersPollOnly() throws {
        for mode in ["STA", "AP"] {
            for hardware in ["X3", "X4"] {
                let json = """
                {"version":"test","ip":"192.0.2.1","mode":"\(mode)",
                 "device":"\(hardware)","rssi":-50,"freeHeap":90000,"uptime":1,
                 "deviceID":"1234ABCD","contentPresentation":true,
                 "diagnosticsAffordable":false,"screenPreviewAvailable":false,
                 "crashReportAvailable":false,"uploadStreamPort":82,
                 "uploadStreamResume":true,"uploadStreamWindow":4096,
                 "liveStudio":{"mode":"poll","frameStream":false,"uiPacks":true}}
                """
                let decoded = try JSONDecoder().decode(CrossPointStatus.self, from: Data(json.utf8))
                XCTAssertEqual(SyncModePolicy.syncMode(status: decoded), .poll)
                XCTAssertFalse(ReaderDiagnosticsPolicy.canFetchDiagnostics(
                    freeHeap: decoded.freeHeap, readerSaysAffordable: decoded.diagnosticsAffordable))
                XCTAssertEqual(decoded.contentPresentation, true)
                XCTAssertEqual(decoded.uploadStreamPort, 82)
                XCTAssertEqual(decoded.uploadStreamWindow, 4096)
                XCTAssertEqual(decoded.liveStudio?.mode, "poll", "Older readers' pack keys are ignored")
            }
        }
    }

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

extension DeviceCoreTests {
    @MainActor func testWorkLaneKeepsReplacementOwnedUntilItsTaskFinishes() throws {
        var lane = ReaderWorkLane()
        let quiet = try XCTUnwrap(lane.reserve(.quietReading))
        let task = Task<Void, Never> { }
        lane.attach(task, owner: quiet.owner)
        let transfer = try XCTUnwrap(lane.reserve(.transfer))
        XCTAssertTrue(task.isCancelled)
        XCTAssertNotNil(transfer.predecessor)
        XCTAssertNil(lane.reserve(.settings))
        lane.finish(quiet.owner)
        XCTAssertEqual(lane.owner, transfer.owner)
        XCTAssertTrue(lane.isActive)
        lane.finish(transfer.owner)
        XCTAssertFalse(lane.isActive)
        XCTAssertNotNil(lane.reserve(.settings))
    }
}
