import CoreBluetooth
import CryptoKit
import Network
#if os(iOS)
import NetworkExtension
#endif
import XCTest
@testable import Pocket

final class NearbySyncProtocolTests: XCTestCase {
    func testStaleBondExplainsHowToRecover() {
        let removed = CBError(.peerRemovedPairingInformation)
        XCTAssertEqual(NearbySyncController.failureMessage(for: removed), NearbySyncController.staleBondMessage)
        XCTAssertTrue(NearbySyncController.staleBondMessage.contains("Forget This Device"))
        XCTAssertTrue(NearbySyncController.staleBondMessage.contains("Direct connection"))

        let other = CBError(.connectionTimeout)
        XCTAssertEqual(NearbySyncController.failureMessage(for: other), other.localizedDescription)
    }

    @MainActor
    func testFailedBLEDiscoveryReleasesPendingDirectRequestWithoutWiFiChanges() {
        let io = HeldAssociationIO()
        let model = PocketModel(associationIO: io)
        model.beginDirectConnection()
        XCTAssertTrue(model.hasDirectSession)
        model.expectDirectReader("1234ABCD")
        model.directDiscoveryFailed("Pairing timed out")
        XCTAssertFalse(model.hasDirectSession)
        XCTAssertFalse(model.directConnectionRequested)
        XCTAssertEqual(model.message, "Pairing timed out")
        XCTAssertEqual(io.joinCount, 0)
        XCTAssertTrue(io.leftSSIDs.isEmpty)
        // An old BLE failure cannot replace the current UI after revocation.
        model.post("LAN ready")
        model.directDiscoveryFailed("late failure")
        XCTAssertEqual(model.message, "LAN ready")
        model.beginDirectConnection()
        XCTAssertTrue(model.directConnectionRequested, "A new explicit attempt must be admitted")
        model.pauseForBackground()
    }

    @MainActor
    func testRepeatedSynchronousBluetoothFailureDoesNotLeavePendingSession() {
        let io = HeldAssociationIO()
        let model = PocketModel(associationIO: io)
        for state in [NearbySyncController.State.bluetoothUnavailable,
                      .failed(NearbySyncController.unauthorizedMessage)] {
            for _ in 0..<2 {
                model.beginDirectConnection()
                XCTAssertTrue(model.hasDirectSession)
                if let message = state.failureMessage { model.directDiscoveryFailed(message) }
                XCTAssertFalse(model.hasDirectSession)
            }
        }
        XCTAssertNil(NearbySyncController.State.switchingToHotspot.failureMessage)
        XCTAssertNil(NearbySyncController.State.scanning.failureMessage)
        XCTAssertEqual(io.joinCount, 0)
        XCTAssertTrue(io.leftSSIDs.isEmpty)
    }

    @MainActor
    func testLateBLEFailureDoesNotRevokeHandedOffLease() async throws {
        let io = HeldAssociationIO()
        let model = PocketModel(associationIO: io)
        defer { model.pauseForBackground(); io.failAll() }
        let lease = try HotspotLease(record: "AP 12ABCDEF Pocket-Test A1B2C3D4E5F6 192.0.2.1 80 0 300")
        model.beginDirectConnection()
        model.useNearbyLease(lease)
        for _ in 0..<100 where io.joinCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        model.post("Handoff in progress")
        model.directDiscoveryFailed("late BLE disconnect")
        XCTAssertTrue(model.hasDirectSession)
        XCTAssertEqual(model.message, "Handoff in progress")
        XCTAssertEqual(io.joinCount, 1)
        io.failAll()
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        model.post("Manual fallback retained")
        model.directDiscoveryFailed("late failure after join")
        XCTAssertTrue(model.hasDirectSession)
        XCTAssertTrue(model.manualHotspotFallback)
        XCTAssertEqual(model.message, "Manual fallback retained")
    }

    @MainActor
    func testManualLeaseVerificationCancelsWithBackgroundOrCaller() async throws {
        for background in [true, false] {
            HeldReaderURLProtocol.reset()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [HeldReaderURLProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let io = HeldAssociationIO()
            let model = PocketModel(client: CrossPointClient(session: session), associationIO: io)
            defer { model.pauseForBackground(); io.failAll() }
            let lease = try HotspotLease(record: "AP 12ABCDEF Pocket-Test A1B2C3D4E5F6 192.0.2.1 80 81 300")
            model.beginDirectConnection()
            let pending = Task { await model.verifyNearbyLease(lease) }
            defer { pending.cancel() }
            let request = try await heldRequest(0)
            XCTAssertTrue(model.isWorking)
            if background { model.pauseForBackground() }
            else { pending.cancel() }
            model.post("cancelled manual verification")
            await pending.value
            for _ in 0..<100 where !request.wasStopped { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(request.wasStopped)
            XCTAssertFalse(model.isWorking)
            XCTAssertNil(model.readerStatus)
            XCTAssertEqual(model.message, "cancelled manual verification")
            XCTAssertEqual(io.joinCount, 0, "Verification must not associate Wi-Fi")
            XCTAssertEqual(HeldReaderURLProtocol.requests.count, 1)
        }
    }

    @MainActor
    func testReplacingManualVerificationKeepsNewJoinOwnership() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let io = HeldAssociationIO()
        let model = PocketModel(client: CrossPointClient(session: session), associationIO: io)
        defer { model.pauseForBackground(); io.failAll() }
        let lease = try HotspotLease(record: "AP 12ABCDEF Pocket-Test A1B2C3D4E5F6 192.0.2.1 80 81 300")
        model.beginDirectConnection()
        let pending = Task { await model.verifyNearbyLease(lease) }
        defer { pending.cancel() }
        let request = try await heldRequest(0)
        model.useNearbyLease(lease)
        for _ in 0..<100 where io.joinCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await pending.value
        for _ in 0..<100 where !request.wasStopped { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(request.wasStopped)
        XCTAssertEqual(io.joinCount, 1)
        XCTAssertTrue(model.isWorking)
        XCTAssertNil(model.readerStatus)
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 1)
    }

    @MainActor
    func testReplacementJoinWaitsForOldAssociationAndCleanup() async throws {
        for replacementSSID in ["Pocket-Test", "Pocket-Other"] {
            let io = HeldAssociationIO()
            io.holdLeave = true
            let model = PocketModel(associationIO: io)
            defer { model.pauseForBackground(); io.failAll() }
            let first = try HotspotLease(record: "AP 12ABCDEF Pocket-Test A1B2C3D4E5F6 192.0.2.1 80 81 300")
            let replacement = try HotspotLease(record: "AP 12ABCDEF \(replacementSSID) A1B2C3D4E5F6 192.0.2.1 80 81 300")
            model.beginDirectConnection()
            model.useNearbyLease(first)
            for _ in 0..<100 where io.joinCount < 1 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(io.joinCount, 1)
            model.useNearbyLease(replacement)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(io.joinCount, 1, "A replacement must wait for non-cooperative OS I/O")
            io.succeed(0)
            for _ in 0..<100 where io.leftSSIDs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(io.joinCount, 1, "OS cleanup must finish before the replacement joins")
            io.releaseLeave()
            for _ in 0..<100 where io.joinCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertEqual(io.joinCount, 2)
            XCTAssertTrue(model.isWorking, "Old completion released the new join's busy state")
            XCTAssertEqual(io.leftSSIDs, [first.ssid], "Cleanup completes before even a same-SSID replacement")
            XCTAssertNil(model.readerStatus)
            io.failAll() // Do not proceed to HTTP verification or any actual network.
            for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertFalse(model.isWorking)
            XCTAssertTrue(model.manualHotspotFallback)
        }
    }

    @MainActor
    func testQueuedConnectionReplacementsRunOnlyLatestAfterJoinDrains() async throws {
        let io = HeldAssociationIO()
        let model = PocketModel(associationIO: io)
        defer { model.pauseForBackground(); io.failAll() }
        let first = try HotspotLease(record: "AP 12ABCDEF Pocket-First A1B2C3D4E5F6 192.0.2.1 80 81 300")
        let middle = try HotspotLease(record: "AP 12ABCDEF Pocket-Middle A1B2C3D4E5F6 192.0.2.2 80 81 300")
        let latest = try HotspotLease(record: "AP 12ABCDEF Pocket-Latest A1B2C3D4E5F6 192.0.2.3 80 81 300")
        model.beginDirectConnection()
        model.useNearbyLease(first)
        for _ in 0..<100 where io.joinCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(io.joinCount, 1)
        model.useNearbyLease(middle)
        model.useNearbyLease(latest)
        XCTAssertTrue(model.isWorking)
        XCTAssertFalse(model.canPrepareFiles)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(io.joinCount, 1)
        io.succeed(0)
        for _ in 0..<100 where io.joinCount < 2 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(io.joinedSSIDs, [first.ssid, latest.ssid])
        XCTAssertEqual(io.leftSSIDs, [first.ssid])
        XCTAssertTrue(model.isWorking)
        model.pauseForBackground()
        io.failAll()
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.readerStatus)
    }

    @MainActor
    func testBackgroundDrainsJoinOwnershipAndCleansLateAssociation() async throws {
        let io = HeldAssociationIO()
        let model = PocketModel(associationIO: io)
        defer { model.pauseForBackground(); io.failAll() }
        let lease = try HotspotLease(record: "AP 12ABCDEF Pocket-Test A1B2C3D4E5F6 192.0.2.1 80 81 300")
        model.beginDirectConnection()
        model.useNearbyLease(lease)
        for _ in 0..<100 where io.joinCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(io.joinCount, 1)
        model.pauseForBackground()
        XCTAssertTrue(model.isWorking)
        model.useNearbyLease(lease) // A queued BLE lease must not join in the background.
        XCTAssertTrue(model.isWorking)
        model.resumeForForeground() // Foreground alone does not acquire a new association.
        model.post("paused join")
        io.succeed(0)
        for _ in 0..<100 where io.leftSSIDs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(io.leftSSIDs, [lease.ssid])
        XCTAssertEqual(model.message, "paused join")
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.readerStatus)
        model.resumeForForeground()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(io.joinCount, 1, "Foreground must not rejoin automatically")
    }

    @MainActor
    func testAcceptingReaderClearsOldViewDataBeforePreferencesArrive() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        model.preferences = ReaderPreferences(fontSize: 3)
        model.preferencesDirty = true
        model.mirror.apply(.preferences(ReaderPreferences(fontSize: 3)))
        let connecting = Task { await model.verify(host: "reader.local", port: 80) }
        defer { connecting.cancel() }
        let status = try await heldRequest(0)
        status.succeed(Data(#"{"version":"new","device":"X3","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":12000,"uptime":1}"#.utf8))
        let prefs = try await heldRequest(1)
        XCTAssertEqual(model.readerStatus?.version, "new")
        XCTAssertNil(model.preferences)
        XCTAssertFalse(model.preferencesDirty)
        XCTAssertNil(model.mirror.state.preferences)
        XCTAssertTrue(model.isWorking)
        prefs.succeed(Data(#"{"startupApp":1,"pocketDailySleepCover":1,"sleepTimeoutMinutes":10,"fontSize":2}"#.utf8))
        await connecting.value
        XCTAssertEqual(model.preferences?.fontSize, 2)
        XCTAssertEqual(model.mirror.state.preferences?.fontSize, 2)
        XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testForegroundRestartsOneHeartbeatForExistingLANReader() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        let statusData = Data(#"{"version":"1.6.6","device":"X3","deviceID":"test-reader","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":12000,"uptime":1}"#.utf8)
        let connecting = Task { await model.verify(host: "reader.local", port: 80) }
        defer { connecting.cancel() }
        let status = try await heldRequest(0)
        status.succeed(statusData)
        let prefs = try await heldRequest(1)
        prefs.succeed(Data(#"{"startupApp":1,"pocketDailySleepCover":1,"sleepTimeoutMinutes":10,"fontSize":1}"#.utf8))
        await connecting.value
        model.pauseForBackground()
        model.resumeForForeground()
        model.resumeForForeground() // Duplicate scene notifications are inert.
        let heartbeat = try await heldRequest(2, attempts: 1800)
        XCTAssertEqual(heartbeat.request.url?.host, "reader.local")
        XCTAssertEqual(heartbeat.request.url?.path, "/api/status")
        XCTAssertEqual(heartbeat.request.httpMethod, "GET")
        heartbeat.succeed(statusData)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 3)
        XCTAssertEqual(model.readerStatus?.deviceID, "test-reader")
        XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testReaderLeavingToInstallStagedFirmwareIsNoticedWithinSeconds() async throws {
        let stagedKey = "Pocket.stagedFirmwareVersion.install-reader"
        UserDefaults.standard.set("9.9.9", forKey: stagedKey)
        defer { UserDefaults.standard.removeObject(forKey: stagedKey) }
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        let statusData = Data(#"{"version":"1.6.6","device":"X3","deviceID":"install-reader","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":12000,"uptime":1}"#.utf8)
        let connecting = Task { await model.verify(host: "reader.local", port: 80) }
        defer { connecting.cancel() }
        try await heldRequest(0).succeed(statusData)
        try await heldRequest(1).succeed(Data(#"{"startupApp":1,"pocketDailySleepCover":1,"sleepTimeoutMinutes":10,"fontSize":1}"#.utf8))
        await connecting.value
        XCTAssertEqual(model.firmwareAwaitingInstallation, "9.9.9")
        XCTAssertNil(model.firmwareLeftForInstallation)

        // Two missed polls three seconds apart end the session, not five at fifteen.
        try await heldRequest(2, attempts: 600).respond(status: 503)
        XCTAssertNotNil(model.readerStatus, "One miss can be a weak link")
        try await heldRequest(3, attempts: 600).respond(status: 503)
        for _ in 0..<100 where model.readerStatus != nil { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertNil(model.readerStatus)
        XCTAssertEqual(model.message, PocketModel.installingFirmwareMessage(version: "9.9.9"))
        XCTAssertEqual(model.messageTone, .onReader)
        XCTAssertEqual(model.firmwareLeftForInstallation, "9.9.9")
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 4)
    }

    @MainActor
    func testForegroundWithoutPriorSessionDoesNotDiscoverOrConnect() async throws {
        let io = ControlledDiscoveryIO()
        let model = PocketModel(discoveryIO: io)
        model.resumeForForeground()
        model.pauseForBackground()
        model.resumeForForeground()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(io.bonjourCalls, 0)
        XCTAssertEqual(io.statusCalls, 0)
        XCTAssertNil(model.readerStatus)
        XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testReplacingVerificationCancelsOldRequestWithoutReleasingNewOwner() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        let old = Task { await model.verify(host: "old.local", port: 80) }
        defer { old.cancel() }
        let oldRequest = try await heldRequest(0)
        let current = Task { await model.verify(host: "new.local", port: 80) }
        defer { current.cancel() }
        let currentRequest = try await heldRequest(1)
        await old.value
        XCTAssertTrue(oldRequest.wasStopped)
        XCTAssertTrue(model.isWorking)
        XCTAssertNil(model.readerStatus)
        XCTAssertEqual(currentRequest.request.url?.host, "new.local")
        currentRequest.succeed(Data(#"{"version":"new","device":"X3","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":12000,"uptime":1}"#.utf8))
        let prefs = try await heldRequest(2)
        prefs.succeed(Data(#"{"startupApp":1,"pocketDailySleepCover":1,"sleepTimeoutMinutes":10,"fontSize":1}"#.utf8))
        await current.value
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.readerStatus?.version, "new")
    }

    @MainActor
    func testBackgroundCancelsVerificationWithoutLateAcceptance() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        let pending = Task { await model.verify(host: "reader.local", port: 80) }
        defer { pending.cancel() }
        let request = try await heldRequest(0)
        model.pauseForBackground()
        let message = model.message
        await pending.value
        // URLSession can resume its cancelled async task before delivering
        // URLProtocol.stopLoading on the protocol queue. Observe that callback
        // separately, with a bounded deadline; cancellation must still reach I/O.
        for _ in 0..<100 where !request.wasStopped {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(request.wasStopped)
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.readerStatus)
        XCTAssertEqual(model.message, message)
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 1)
    }

    func testHTTPRequestsSerializePerHostAndCancelQueuedRequest() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CrossPointClient(session: session)
        let first = Task { try await client.save(preferences: ReaderPreferences(), host: "reader.local", port: 80) }
        defer { first.cancel() }
        let request = try await heldRequest(0)
        let cancelled = Task { try await client.endDirectSession(host: "reader.local", port: 80) }
        defer { cancelled.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 1)
        cancelled.cancel()
        do { try await cancelled.value; XCTFail("Queued cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError) }
        let next = Task { try await client.save(preferences: ReaderPreferences(), host: "reader.local", port: 80) }
        defer { next.cancel() }
        request.succeed()
        try await first.value
        let nextRequest = try await heldRequest(1)
        XCTAssertEqual(nextRequest.olderActiveRequests, 0)
        XCTAssertEqual(nextRequest.request.url?.path, "/api/pocket/v1/preferences")
        nextRequest.succeed()
        try await next.value
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 2, "Cancelled request must never reach transport")
    }

    func testHTTPRequestsToDifferentHostsRemainConcurrent() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CrossPointClient(session: session)
        let first = Task { try await client.save(preferences: ReaderPreferences(), host: "first.local", port: 80) }
        defer { first.cancel() }
        let firstRequest = try await heldRequest(0)
        let second = Task { try await client.save(preferences: ReaderPreferences(), host: "second.local", port: 80) }
        defer { second.cancel() }
        let secondRequest = try await heldRequest(1)
        XCTAssertEqual(secondRequest.olderActiveRequests, 1)
        firstRequest.succeed()
        secondRequest.succeed()
        try await first.value
        try await second.value
    }

    func testActiveHTTPCancellationReleasesNextRequest() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = CrossPointClient(session: session)
        let first = Task { try await client.save(preferences: ReaderPreferences(), host: "reader.local", port: 80) }
        defer { first.cancel() }
        let firstRequest = try await heldRequest(0)
        let next = Task { try await client.endDirectSession(host: "reader.local", port: 80) }
        defer { next.cancel() }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 1)
        first.cancel()
        do { try await first.value; XCTFail("Active cancellation must throw") }
        catch { XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled) }
        let nextRequest = try await heldRequest(1)
        XCTAssertTrue(firstRequest.wasStopped)
        XCTAssertEqual(nextRequest.olderActiveRequests, 0)
        nextRequest.succeed()
        try await next.value
    }

    @MainActor
    func testSettingsDrainsInFlightHeartbeatBeforeWrite() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        let connecting = Task { await model.verify(host: "127.0.0.1", port: 80) }
        defer { connecting.cancel() }
        let status = try await heldRequest(0)
        status.succeed(Data(#"{"version":"1.6.6","device":"X3","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":12000,"uptime":1}"#.utf8))
        let prefs = try await heldRequest(1)
        prefs.succeed(Data(#"{"startupApp":1,"pocketDailySleepCover":1,"sleepTimeoutMinutes":10,"fontSize":1}"#.utf8))
        await connecting.value
        XCTAssertNotNil(model.preferences)
        // Exercise the shipping 15-second heartbeat, not a substitute scheduler.
        let heartbeat = try await heldRequest(2, attempts: 1800)
        XCTAssertEqual(heartbeat.request.url?.path, "/api/status")
        model.savePreferences()
        let write = try await heldRequest(3)
        XCTAssertTrue(heartbeat.wasStopped)
        XCTAssertEqual(write.olderActiveRequests, 0, "Write must start only after background I/O is drained")
        XCTAssertEqual(write.request.httpMethod, "POST")
        write.succeed()
        for _ in 0..<100 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.messageTone, .success)
    }

    @MainActor
    func testContentApplyCompletesAlreadyActiveRevisionWithoutUploading() async throws {
        try await checkAlreadyActiveContent(presentationPhase: nil)
    }

    @MainActor
    func testContentApplyConfirmsRedrawWithoutEndingSessionOrUploading() async throws {
        try await checkAlreadyActiveContent(presentationPhase: "rendered")
    }

    @MainActor
    func testContentRedrawFailurePreservesActivationWithoutResending() async throws {
        try await checkAlreadyActiveContent(presentationPhase: "failed")
    }

    @MainActor
    private func checkAlreadyActiveContent(presentationPhase: String?) async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        let connecting = Task { await model.verify(host: "127.0.0.1", port: 80) }
        defer { connecting.cancel() }
        let status = try await heldRequest(0)
        status.succeed(try JSONSerialization.data(withJSONObject: [
            "version": "1.6.6", "device": "X3", "deviceID": "1234ABCD", "uploadStreamPort": 82,
            "ip": "127.0.0.1", "mode": "STA", "rssi": -60, "freeHeap": 12000, "uptime": 1,
            "contentPresentation": presentationPhase != nil
        ]))
        let prefs = try await heldRequest(1)
        prefs.succeed(Data(#"{"startupApp":1,"pocketDailySleepCover":1,"sleepTimeoutMinutes":10,"fontSize":1}"#.utf8))
        // A presentation-capable reader's resolved preview inputs are read in the
        // same sequential connection lane, never overlapping another request.
        var next = 2
        if presentationPhase != nil {
            let display = try await heldRequest(next)
            next += 1
            XCTAssertEqual(display.request.httpMethod, "GET")
            XCTAssertEqual(display.request.url?.path, "/api/pocket/v1/display")
            XCTAssertEqual(display.olderActiveRequests, 0)
            if presentationPhase == "rendered" {
                display.succeed(Data(#"{"schema":1,"deviceID":"1234ABCD","theme":"lyra","orientation":0,"font":{"family":"PocketSansWorld","pointSize":12},"contentPage":{"sidePadding":20,"topPadding":5,"spacing":16,"title":"Pocket","empty":"Empty","labels":["Back","","Prev","Next"]}}"#.utf8))
            } else {
                display.respond(status: 404)  // older firmware: labelled reference preview
            }
            // The active card revision is read once so Home & Sleep knows
            // whether My cards need sending.
            let cards = try await heldRequest(next)
            next += 1
            XCTAssertEqual(cards.request.url?.path, "/api/pocket/v1/content/state")
            XCTAssertEqual(cards.olderActiveRequests, 0)
            cards.succeed(Data(#"{"schema":1,"deviceID":"1234ABCD","capabilities":7,"active":null}"#.utf8))
        }
        await connecting.value
        if presentationPhase != nil { XCTAssertEqual(model.loadedContentRevision, "") }
        XCTAssertEqual(model.readerDisplay?.theme, presentationPhase == "rendered" ? "lyra" : nil)

        let target = try ContentRevision(cards: [.init(id: "a", title: "A", question: "Text")])
        model.applyContent(target)
        XCTAssertTrue(model.isWorking)
        XCTAssertTrue(model.isTransferring)
        let state = try await heldRequest(next)
        XCTAssertEqual(state.request.url?.path, "/api/pocket/v1/content/state")
        XCTAssertEqual(state.olderActiveRequests, 0)
        state.succeed(try JSONSerialization.data(withJSONObject: [
            "schema": 1, "deviceID": "1234ABCD", "capabilities": 3,
            "active": ["revision": target.revision, "generation": 1]
        ]))
        if let presentationPhase {
            let present = try await heldRequest(next + 1)
            XCTAssertEqual(present.request.httpMethod, "POST")
            XCTAssertEqual(present.request.url?.path, "/api/pocket/v1/content/present")
            XCTAssertEqual(present.olderActiveRequests, 0)
            XCTAssertTrue(model.isWorking)
            present.succeed(try JSONSerialization.data(withJSONObject: [
                "schema": 1, "deviceID": "1234ABCD", "revision": target.revision,
                "generation": 1, "phase": "queued"
            ]))
            // Production presentation polling is deliberately paced at 2s.
            let paintState = try await heldRequest(next + 2, attempts: 350)
            XCTAssertEqual(paintState.request.httpMethod, "GET")
            XCTAssertEqual(paintState.request.url?.path, "/api/pocket/v1/content/presentation")
            XCTAssertEqual(paintState.olderActiveRequests, 0)
            XCTAssertTrue(model.isWorking)
            paintState.succeed(try JSONSerialization.data(withJSONObject: [
                "schema": 1, "deviceID": "1234ABCD", "revision": target.revision,
                "generation": 1, "phase": presentationPhase
            ]))
        }
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isTransferring)
        XCTAssertEqual(model.contentDeployment?.phase, .complete(.init(revision: target.revision, generation: 1)))
        XCTAssertEqual(model.messageTone, presentationPhase == "failed" ? .pending : .success)
        if presentationPhase == "failed" {
            XCTAssertTrue(model.message.contains("Nothing was resent"))
        } else if presentationPhase == "rendered" {
            XCTAssertTrue(model.message.contains("completed redraw"))
        } else {
            XCTAssertTrue(model.message.contains("screen display is not yet confirmed"))
        }
        XCTAssertNotNil(model.readerStatus)
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, presentationPhase == nil ? 3 : 7,
                       "No staging, upload, reactivation or session termination is permitted")
    }

    private func heldRequest(_ index: Int, attempts: Int = 100) async throws -> HeldReaderURLProtocol {
        for _ in 0..<attempts where HeldReaderURLProtocol.requests.count <= index {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(HeldReaderURLProtocol.requests.dropFirst(index).first)
    }

    @MainActor
    func testInFlightSettingsCancellationCannotReleaseNewOperation() async throws {
        try await checkInFlightOperationCancellation()
    }

    @MainActor
    private func checkInFlightOperationCancellation() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.6.6","device":"X3","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":12000,"uptime":1}"#.utf8))
        model.preferences = ReaderPreferences()
        model.preferencesDirty = true
        model.savePreferences()
        for _ in 0..<100 where HeldReaderURLProtocol.requests.count < 1 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let old = try XCTUnwrap(HeldReaderURLProtocol.requests.first)
        XCTAssertEqual(old.request.httpMethod, "POST")
        XCTAssertTrue(model.isWorking)
        let previousMessage = model.message

        // No response has been delivered. Backgrounding cancels the actual
        // URLSession request, but cannot admit a new write while it drains.
        model.pauseForBackground()
        model.savePreferences()
        for _ in 0..<100 where model.isWorking || !old.wasStopped {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(old.wasStopped, "Background cancellation must reach URLSession")
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 1, "No background write is allowed")
        XCTAssertTrue(model.preferencesDirty)
        XCTAssertEqual(model.message, previousMessage, "Old cancellation must not publish an error")
        model.resumeForForeground()
        model.savePreferences()
        for _ in 0..<100 where HeldReaderURLProtocol.requests.count < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 2)
        XCTAssertTrue(model.isWorking, "The new foreground operation owns its own lifetime")
        XCTAssertTrue(model.preferencesDirty)
        XCTAssertEqual(model.message, previousMessage, "Old cancellation must not publish an error")
        let current = try XCTUnwrap(HeldReaderURLProtocol.requests.last)
        XCTAssertFalse(current === old)
        XCTAssertEqual(current.request.httpMethod, "POST")
        current.succeed()
        for _ in 0..<100 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.preferencesDirty)
        XCTAssertEqual(model.messageTone, .success)
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 2)
    }

    @MainActor
    func testSettingsReserveOwnershipBeforeTaskStarts() async throws {
        RecoveryURLProtocol.configure([.success(Data())])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.6.6","device":"X3","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":12000,"uptime":1}"#.utf8))
        model.preferences = ReaderPreferences()
        model.preferencesDirty = true
        model.savePreferences()
        XCTAssertTrue(model.isWorking)
        model.savePreferences()
        // An edit made during the save must remain unsaved after its completion.
        model.setFontSize(2)
        for _ in 0..<100 where model.isWorking {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 1)
        XCTAssertTrue(model.preferencesDirty)
        XCTAssertEqual(model.messageTone, .success)
        model.pauseForBackground()
    }

    @MainActor
    func testBackgroundCancelsReservedSettingsBeforeNetworkStarts() async throws {
        RecoveryURLProtocol.configure([])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(client: CrossPointClient(session: session))
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.6.6","device":"X3","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":12000,"uptime":1}"#.utf8))
        model.preferences = ReaderPreferences()
        model.savePreferences()
        model.pauseForBackground()
        XCTAssertTrue(model.isWorking, "Cancelled work retains ownership until its task drains")
        XCTAssertFalse(model.isTransferring, "Settings must not expose the file-transfer controls")
        model.resumeForForeground()
        model.savePreferences() // Cannot reserve a replacement before the old task drains.
        for _ in 0..<100 where model.isWorking { await Task.yield() }
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 0)
        XCTAssertFalse(model.isWorking)
        model.pauseForBackground()
    }

    @MainActor
    func testSettingsOwnSessionWithoutTransferControls() async throws {
        do {
            HeldReaderURLProtocol.reset()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [HeldReaderURLProtocol.self]
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            let io = ControlledDiscoveryIO()
            let model = PocketModel(discoveryIO: io, client: CrossPointClient(session: session))
            defer { model.pauseForBackground() }
            let status = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
                #"{"version":"test","device":"X3","ip":"reader.test","mode":"STA","rssi":-60,"freeHeap":12000,"uptime":1}"#.utf8))
            model.readerStatus = status
            model.preferences = ReaderPreferences()
            model.savePreferences()
            let request = try await heldRequest(0)
            XCTAssertTrue(model.isWorking)
            XCTAssertFalse(model.isTransferring)
            model.pauseTransfer() // The file-transfer action does not cancel settings.
            var verificationReturned = false
            let verification = Task {
                await model.verify(host: "must-not-contact.test", port: 80)
                verificationReturned = true
            }
            defer { verification.cancel() }
            for _ in 0..<100 where !verificationReturned { await Task.yield() }
            XCTAssertTrue(verificationReturned, "Connection replacement must be refused before HTTP")
            model.findOnLocalNetwork(retryIfMissing: false)
            model.savePreferences()
            XCTAssertEqual(io.bonjourCalls, 0)
            XCTAssertEqual(io.statusCalls, 0)
            XCTAssertEqual(HeldReaderURLProtocol.requests.count, 1)
            XCTAssertFalse(request.wasStopped)
            XCTAssertEqual(model.readerStatus, status)
            model.pauseForBackground()
            for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(request.wasStopped)
            XCTAssertFalse(model.isWorking)
            XCTAssertFalse(model.isTransferring)
        }
    }

    @MainActor
    func testEmptyDiscoveryFinishesWithoutNetworkAndRetriesOnce() async throws {
        let io = ControlledDiscoveryIO()
        let model = PocketModel(discoveryIO: io)
        model.findOnLocalNetwork()
        for _ in 0..<150 where !model.message.hasPrefix("No Pocket reader was visible") {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(io.bonjourCalls, 2)
        XCTAssertEqual(io.statusCalls, 0)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.messageTone, .failure)
        XCTAssertTrue(model.message.contains("Join a Network"))
        XCTAssertTrue(model.message.contains("Same Wi-Fi"))
        XCTAssertTrue(model.message.contains("Direct connection"))
    }

    @MainActor
    func testDiscoveryOwnsRetryDelayAndBackgroundCancelsSecondPass() async throws {
        let io = ControlledDiscoveryIO()
        let model = PocketModel(discoveryIO: io)
        defer { model.pauseForBackground() }
        model.findOnLocalNetwork()
        for _ in 0..<100 where !model.message.hasPrefix("Reader not ready yet") {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.message.hasPrefix("Reader not ready yet"))
        XCTAssertEqual(io.bonjourCalls, 1)
        XCTAssertTrue(model.isWorking, "The retry delay is part of the active search")
        model.startConnectionSearch() // Duplicate action must not replace the pending search.
        XCTAssertEqual(io.bonjourCalls, 1)
        model.pauseForBackground()
        model.post("paused retry")
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(io.bonjourCalls, 1)
        XCTAssertEqual(io.statusCalls, 0)
        XCTAssertEqual(model.message, "paused retry")
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.readerStatus)
    }

    @MainActor
    func testDuplicateDiscoveryCannotReplaceActiveAttempt() async throws {
        let io = ControlledDiscoveryIO(delay: .milliseconds(200))
        let model = PocketModel(discoveryIO: io)
        model.findOnLocalNetwork(retryIfMissing: false)
        try await Task.sleep(for: .milliseconds(20))
        model.findOnLocalNetwork(retryIfMissing: false)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.isWorking, "Duplicate discovery must not release active work")
        XCTAssertEqual(io.bonjourCalls, 1)
        XCTAssertFalse(model.message.hasPrefix("No Pocket reader was visible"))
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.message.hasPrefix("No Pocket reader was visible"))
    }

    @MainActor
    func testDiscoveryReservesAdmissionAndDrainsNonCooperativeBonjour() async throws {
        let io = ControlledDiscoveryIO()
        io.holdBonjour = true
        io.endpoint = ("late-discovery.test", 80)
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(discoveryIO: io, client: CrossPointClient(session: session))
        defer { model.pauseForBackground(); io.releaseBonjour() }
        model.findOnLocalNetwork(retryIfMissing: false)
        XCTAssertTrue(model.isWorking, "Reserve before any scheduled discovery work starts")
        XCTAssertFalse(model.isTransferring)
        XCTAssertFalse(model.canPrepareFiles)
        model.enterDemoMode()
        XCTAssertFalse(model.isDemoMode)
        for _ in 0..<100 where io.bonjourCalls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(io.bonjourCalls, 1)
        model.pauseForBackground()
        model.resumeForForeground()
        model.post("waiting for old discovery")
        model.findOnLocalNetwork(retryIfMissing: false)
        await model.verify(host: "must-not-contact.test", port: 80)
        model.endConnection()
        XCTAssertTrue(model.isWorking, "Cancellation must not release a provider that has not returned")
        XCTAssertEqual(io.bonjourCalls, 1)
        XCTAssertTrue(HeldReaderURLProtocol.requests.isEmpty)
        io.releaseBonjour()
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isWorking)
        XCTAssertNil(model.readerStatus)
        XCTAssertEqual(model.message, "waiting for old discovery")
        XCTAssertEqual(io.statusCalls, 0, "A late Bonjour endpoint must not start another probe after cancellation")
        io.endpoint = nil
        model.findOnLocalNetwork(retryIfMissing: false)
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(io.bonjourCalls, 2)
        XCTAssertFalse(model.isWorking)
        XCTAssertTrue(model.message.hasPrefix("No Pocket reader was visible"))
        XCTAssertTrue(HeldReaderURLProtocol.requests.isEmpty)
    }

    @MainActor
    func testUserCancellationDrainsDiscoveryAndRejectsLateEndpoint() async throws {
        let io = ControlledDiscoveryIO()
        io.holdBonjour = true
        io.endpoint = ("late-reader.test", 80)
        let model = PocketModel(discoveryIO: io)
        defer { model.pauseForBackground(); io.releaseBonjour() }
        model.findOnLocalNetwork()
        for _ in 0..<100 where io.bonjourCalls == 0 { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.canCancelConnection)
        model.cancelConnectionAttempt()
        XCTAssertTrue(model.isWorking)
        XCTAssertTrue(model.isCancellingConnection)
        XCTAssertFalse(model.canCancelConnection)
        model.startConnectionSearch()
        model.beginDirectConnection()
        XCTAssertEqual(io.bonjourCalls, 1)
        XCTAssertFalse(model.directConnectionRequested)
        io.releaseBonjour()
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.isCancellingConnection)
        XCTAssertNil(model.readerStatus)
        XCTAssertEqual(io.statusCalls, 0)
        XCTAssertTrue(model.message.hasPrefix("Connection cancelled"))
        io.endpoint = nil
        model.findOnLocalNetwork(retryIfMissing: false)
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(io.bonjourCalls, 2)
        XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testUserCancellationDrainsLateWiFiJoinAndCleanupBeforeRetry() async throws {
        let io = HeldAssociationIO()
        io.holdLeave = true
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), associationIO: io)
        defer { io.failAll(); model.pauseForBackground() }
        let lease = try HotspotLease(record: "AP 12ABCDEF Pocket-Test A1B2C3D4E5F6 192.0.2.1 80 0 300")
        model.beginDirectConnection()
        model.useNearbyLease(lease)
        for _ in 0..<100 where io.joinCount == 0 { try await Task.sleep(for: .milliseconds(5)) }
        model.cancelConnectionAttempt()
        XCTAssertTrue(model.isCancellingConnection)
        XCTAssertTrue(model.isWorking)
        model.useNearbyLease(lease)
        XCTAssertEqual(io.joinCount, 1)
        io.succeed(0)
        for _ in 0..<100 where io.leftSSIDs.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(model.isWorking, "Keep admission until OS cleanup returns")
        model.beginDirectConnection()
        XCTAssertFalse(model.directConnectionRequested)
        io.releaseLeave()
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isWorking)
        XCTAssertFalse(model.hasDirectSession)
        XCTAssertNil(model.readerStatus)
        XCTAssertEqual(io.leftSSIDs, [lease.ssid])
        XCTAssertTrue(model.message.hasPrefix("Connection cancelled"))
        model.beginDirectConnection()
        XCTAssertTrue(model.directConnectionRequested)
        model.cancelConnectionAttempt()
    }

    @MainActor
    func testUserCancellationRevokesPendingBluetoothHandoff() async throws {
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO())
        model.beginDirectConnection()
        XCTAssertTrue(model.canCancelConnection)
        model.cancelConnectionAttempt()
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.hasDirectSession)
        XCTAssertFalse(model.canCancelConnection)
        model.directDiscoveryFailed("late BLE failure")
        XCTAssertTrue(model.message.hasPrefix("Connection cancelled"))
        model.beginDirectConnection()
        XCTAssertTrue(model.directConnectionRequested)
        model.cancelConnectionAttempt()
    }

    @MainActor
    func testBackgroundCancelsDiscoveryWithoutLateMessage() async throws {
        let io = ControlledDiscoveryIO(delay: .milliseconds(200))
        let model = PocketModel(discoveryIO: io)
        model.findOnLocalNetwork(retryIfMissing: false)
        try await Task.sleep(for: .milliseconds(20))
        model.pauseForBackground()
        model.post("background marker")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(model.message, "background marker")
        XCTAssertEqual(io.statusCalls, 0)
    }

    @MainActor
    func testLateBonjourStatusCannotReconnectAfterBackground() async throws {
        let io = ControlledDiscoveryIO()
        io.endpoint = ("192.0.2.1", 80)
        io.statusDelay = .milliseconds(200)
        io.response = try JSONDecoder().decode(CrossPointStatus.self, from: Data("""
        {"version":"test","ip":"192.0.2.1","mode":"STA","rssi":-40,
         "freeHeap":20000,"uptime":100,"device":"X3","deviceID":"test-reader"}
        """.utf8))
        let model = PocketModel(discoveryIO: io)
        model.findOnLocalNetwork(retryIfMissing: false)
        for _ in 0..<50 where io.statusCalls == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(io.statusCalls, 1)
        model.pauseForBackground()
        model.post("background marker")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.readerStatus)
        XCTAssertEqual(model.message, "background marker")
        XCTAssertFalse(model.isWorking)
    }

    @MainActor
    func testDirectSessionCanPrepareAgainAfterRemovingQueue() async throws {
        let model = PocketModel()
        guard model.preparedTransfers.isEmpty else {
            throw XCTSkip("Preserve existing prepared files in the test host")
        }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("queue-regression-\(UUID().uuidString).epub")
        try Data("local test content".utf8).write(to: source)
        defer {
            try? FileManager.default.removeItem(at: source)
            model.removePreparedFiles()
        }
        model.beginDirectConnection() // Model state only; no Bluetooth or Wi-Fi calls.
        for _ in 0..<2 {
            XCTAssertTrue(model.canPrepareFiles)
            model.upload(source)
            let deadline = ContinuousClock.now + .seconds(5)
            while model.isWorking, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertFalse(model.isWorking)
            XCTAssertEqual(model.preparedTransfers.count, 1)
            let item = try XCTUnwrap(model.preparedTransfers.first)
            XCTAssertTrue(FileManager.default.fileExists(atPath: TransferPreparation.file(item).path))
            model.removePreparedFiles()
            while model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(model.preparedTransfers.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: TransferPreparation.file(item).path))
            XCTAssertTrue(model.hasDirectSession)
            XCTAssertTrue(model.canPrepareFiles)
        }
    }

    func testPreparedFileSurvivesSourceRemovalAndHasDurableMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("book.epub")
        let payload = Data("offline content".utf8)
        try payload.write(to: source)
        let preparedRoot = root.appendingPathComponent("prepared")
        let item = try TransferPreparation.prepare(source, directory: preparedRoot)
        try FileManager.default.removeItem(at: source)
        let folder = preparedRoot.appendingPathComponent(item.id.uuidString)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("book.epub")), payload)
        XCTAssertEqual(try JSONDecoder().decode(PreparedTransfer.self,
                       from: Data(contentsOf: folder.appendingPathComponent("transfer.json"))), item)
    }

    func testInvalidPreparedFirmwareLeavesNoQueuedCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("update.bin")
        try Data("not firmware".utf8).write(to: source)
        let preparedRoot = root.appendingPathComponent("prepared")
        XCTAssertThrowsError(try TransferPreparation.prepare(source, directory: preparedRoot))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: preparedRoot.path), [])
    }

    func testStatusSupportsLegacyAndIdentifiedReaders() throws {
        let legacy = Data(#"{"version":"v1","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":20000,"uptime":10,"device":"X3"}"#.utf8)
        let decoded = try JSONDecoder().decode(CrossPointStatus.self, from: legacy)
        XCTAssertNil(decoded.deviceID)
        XCTAssertNil(decoded.sessionEnd)
        var current = decoded
        current.deviceID = "12345678"
        current.sessionEnd = true
        XCTAssertEqual(try JSONDecoder().decode(CrossPointStatus.self, from: JSONEncoder().encode(current)), current)
    }

    func testStreamCancellationBeforeStartDoesNotWaitForWatchdog() async throws {
        let (url, payload) = try makePayloadFile(bytes: 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try FakeUploadReader(expectedPayload: payload.count, onHeader: { _ in nil }, onPayload: { _ in nil })
        let port = try await reader.start()
        defer { reader.stop() }
        let uploader = try PocketStreamUploader(fileURL: url, host: "127.0.0.1", port: Int(port),
            remotePath: "/.pocket-cancel.part", total: Int64(payload.count)) { _, _ in }
        let task = Task { try await uploader.upload() }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled upload succeeded") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
    }

    func testConnectionHeartbeatRequiresConsecutiveFailures() {
        var heartbeat = ConnectionHeartbeat()
        XCTAssertFalse(heartbeat.recordFailure())
        XCTAssertFalse(heartbeat.recordFailure())
        heartbeat.recordSuccess()
        XCTAssertEqual(heartbeat.consecutiveFailures, 0)
        for _ in 0 ..< (ConnectionHeartbeat.failureLimit - 1) { XCTAssertFalse(heartbeat.recordFailure()) }
        XCTAssertTrue(heartbeat.recordFailure())
    }

    func testHeartbeatWatchesAStagedInstallationMoreClosely() {
        let steady = ConnectionHeartbeat.Pace.steady
        let awaiting = ConnectionHeartbeat.Pace.awaitingInstallation
        XCTAssertEqual(steady.failureLimit, ConnectionHeartbeat.failureLimit)
        XCTAssertLessThan(awaiting.interval, steady.interval)
        var heartbeat = ConnectionHeartbeat()
        XCTAssertFalse(heartbeat.recordFailure(limit: awaiting.failureLimit))
        XCTAssertTrue(heartbeat.recordFailure(limit: awaiting.failureLimit))
    }

    func testPocketAdvertisementFallbackAcceptsServiceOrNameOnly() {
        XCTAssertTrue(NearbySyncController.isPocketAdvertisement(
            name: nil,
            serviceUUIDs: [NearbySyncProtocol.service]
        ))
        XCTAssertTrue(NearbySyncController.isPocketAdvertisement(
            name: "Pocket-AF70",
            serviceUUIDs: []
        ))
        XCTAssertFalse(NearbySyncController.isPocketAdvertisement(
            name: "Nearby Headphones",
            serviceUUIDs: []
        ))
    }

    func testCRC32MatchesWireFormat() {
        var crc = CRC32()
        crc.update(Data("123456789".utf8))
        XCTAssertEqual(crc.finalized, 0xCBF4_3926)
    }

    func testStatusAdvertisesPersistentUploadStream() throws {
        let data = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":16000,"uptime":4,"device":"X3","uploadStreamPort":82}"#.utf8)
        let status = try JSONDecoder().decode(CrossPointStatus.self, from: data)
        XCTAssertEqual(status.uploadStreamPort, 82)
        XCTAssertNil(status.uploadChunkBytes)
    }

    func testStatusFromReadersWithTheRemovedScreenPreviewStillDecodes() throws {
        let data = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":16000,"uptime":4,"device":"X3","screenPreviewAvailable":true,"screenPreviewBytes":52342}"#.utf8)
        let status = try JSONDecoder().decode(CrossPointStatus.self, from: data)
        XCTAssertEqual(status.device, "X3")
    }

    func testSubnetDiscoveryCoversSlash22AndStartsWithNeighbors() {
        let candidates = LocalReaderDiscovery.ipv4Candidates(
            address: 0xC0A8_443C, // 192.168.68.60
            netmask: 0xFFFF_FC00,
            limit: 2_048
        )
        XCTAssertEqual(candidates.prefix(2), ["192.168.68.59", "192.168.68.61"])
        XCTAssertTrue(candidates.contains("192.168.71.254"))
        XCTAssertFalse(candidates.contains("192.168.68.60"))
    }

    func testSubnetDiscoveryInterleavesOverlappingInterfaces() {
        let merged = LocalReaderDiscovery.interleaveCandidates([
            ["192.168.68.99", "192.168.68.101", "192.168.68.98"],
            ["192.168.68.59", "192.168.68.61", "192.168.68.58"],
            ["192.168.68.99", "192.168.68.102"],
        ])

        XCTAssertEqual(merged.prefix(6), [
            "192.168.68.99",
            "192.168.68.59",
            "192.168.68.101",
            "192.168.68.61",
            "192.168.68.102",
            "192.168.68.98",
        ])
        XCTAssertEqual(merged.filter { $0 == "192.168.68.99" }.count, 1)
    }

    func testParsesRequiredStatusAndIgnoresUnknownFields() throws {
        let status = try PocketDeviceStatus(
            record: "V=1;MODEL=X3;ID=89ABCDEF;FW=1.4.1;CAP=AP,HTTP,SD,COMMIT1;FUTURE=ignored"
        )
        XCTAssertEqual(status.protocolVersion, 1)
        XCTAssertEqual(status.model, "X3")
        XCTAssertEqual(status.deviceID, "89ABCDEF")
        XCTAssertEqual(status.capabilities, ["AP", "HTTP", "SD", "COMMIT1"])
    }

    func testRejectsDuplicateStatusFields() {
        XCTAssertThrowsError(try PocketDeviceStatus(record: "V=1;V=2;MODEL=X3;ID=A;CAP=AP"))
    }

    func testMapsBothSupportedHardwareModels() throws {
        XCTAssertEqual(PocketHardware(deviceName: "X3"), .x3)
        XCTAssertEqual(PocketHardware(deviceName: "Xteink X4"), .x4)
        XCTAssertNil(PocketHardware(deviceName: "X5"))

        let status = try PocketDeviceStatus(record: "V=1;MODEL=X4;ID=12345678;FW=2.0;CAP=AP,HTTP,SD,COMMIT1")
        XCTAssertEqual(PocketHardware(deviceName: status.model), .x4)
    }

    func testPublicHardwareNamesDescribeCompatibilityWithoutManufacturerBranding() {
        for hardware in PocketHardware.allCases {
            XCTAssertEqual(hardware.displayName, "\(hardware.rawValue)-compatible reader")
            XCTAssertFalse(hardware.displayName.localizedCaseInsensitiveContains("Xteink"))
            XCTAssertTrue(hardware.profileName.hasSuffix(" PROFILE"))
        }
    }

    @MainActor
    func testDemoModeIsExplicitAndLeavesNoConnectedReader() {
        let model = PocketModel()
        model.preferredHardware = .x4

        model.enterDemoMode()
        XCTAssertTrue(model.isDemoMode)
        XCTAssertEqual(model.hardware, .x4)
        XCTAssertEqual(model.readerStatus?.mode, "DEMO")
        XCTAssertNotNil(model.preferences)
        XCTAssertTrue(model.message.contains("disabled"))

        model.exitDemoMode()
        XCTAssertFalse(model.isDemoMode)
        XCTAssertNil(model.readerStatus)
        XCTAssertNil(model.preferences)
    }

    func testParsesHotspotLease() throws {
        let lease = try HotspotLease(record: "AP 12ABCDEF Pocket-89AB A1B2C3D4E5F6 192.168.4.1 80 81 300")
        XCTAssertEqual(lease.requestID, "12ABCDEF")
        XCTAssertEqual(lease.ssid, "Pocket-89AB")
        XCTAssertEqual(lease.passphrase, "A1B2C3D4E5F6")
        XCTAssertEqual(lease.webSocketPort, 81)
        XCTAssertEqual(lease.leaseSeconds, 300)
    }

    func testClassifiesPersistedHeapCrash() {
        let report = """
        CrossPoint version: 1.4.1-test

        Reset reason: panic

        Panic reason: abort() was called on core 0

        Last logs:
        [120] NEARBY started
        [130] HEAP pair: free=6004 largest=2420

        Stack memory:
        0x12345678: 0x00000000
        """
        let diagnostic = CrashDiagnostic(report: report)
        XCTAssertEqual(diagnostic.version, "1.4.1-test")
        XCTAssertEqual(diagnostic.resetReason, "panic")
        XCTAssertTrue(diagnostic.reason.contains("abort"))
        XCTAssertEqual(diagnostic.lastEvent, "[130] HEAP pair: free=6004 largest=2420")
        XCTAssertTrue(diagnostic.analysis.contains("memory pressure"))
    }

    func testClassifiesResetWithoutPanicMessage() {
        let report = """
        CrossPoint version: 1.4.1-test

        Reset reason: task watchdog

        Panic reason:

        Runtime breadcrumb: nearby:connected-awaiting-auth

        Last logs:
        [130] NEARBY ready heap=21000 largest=12000

        Stack memory:
        """
        let diagnostic = CrashDiagnostic(report: report)
        XCTAssertEqual(diagnostic.resetReason, "task watchdog")
        XCTAssertEqual(diagnostic.reason, "No panic message was captured.")
        XCTAssertEqual(diagnostic.breadcrumb, "nearby:connected-awaiting-auth")
        XCTAssertTrue(diagnostic.analysis.contains("watchdog"))
    }

    func testCrashArchiveDeduplicatesByContentHash() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let directory = fixture.base.appendingPathComponent("crash-reports", isDirectory: true)
        let report = "CrossPoint version: test\nReset reason: task watchdog\n"

        let first = try CrashReportArchive.store(report: report, device: "X3", directory: directory)
        let second = try CrashReportArchive.store(report: report, device: "X3", directory: directory)

        XCTAssertEqual(first, second)
        XCTAssertEqual(try String(contentsOf: first, encoding: .utf8), report)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 1)
    }

    func testCopiesLearningPackToSDLayoutWithoutOverwriting() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("jp-n3-ko.pdl")
        try Data("learning-pack".utf8).write(to: source)

        let relative = try PocketModel.copyToSDOffMain(source: source, root: fixture.sd).path
        XCTAssertEqual(relative, "/pocket-daily/learning/jp-n3-ko.pdl")
        XCTAssertEqual(
            try Data(contentsOf: fixture.sd.appendingPathComponent("pocket-daily/learning/jp-n3-ko.pdl")),
            Data("learning-pack".utf8)
        )
        XCTAssertThrowsError(try PocketModel.copyToSDOffMain(source: source, root: fixture.sd))
    }

    func testValidatesAndRoutesFontPackage() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("PocketSansWorld_12.cpfont")
        try Data([0x43, 0x50, 0x46, 0x4F, 0x4E, 0x54, 0x00, 0x00, 0x01]).write(to: source)

        let relative = try PocketModel.copyToSDOffMain(source: source, root: fixture.sd).path
        XCTAssertEqual(relative, "/.fonts/PocketSansWorld/PocketSansWorld_12.cpfont")
    }

    func testValidatesCompatibleFirmwareImage() throws {
        let image = makeFirmwareImage()
        let metadata = try FirmwareImageValidator.validate(image)

        XCTAssertEqual(metadata.byteCount, image.count)
        XCTAssertEqual(metadata.version, "1.4.1-test")
    }

    @MainActor
    func testInspectsALocalFirmwareBuildWithoutPreparingIt() async throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("update.bin")
        let image = makeFirmwareImage()
        try image.write(to: source)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO())
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"1.7.0","device":"X3","deviceID":"1234ABCD","ip":"192.0.2.1","mode":"STA","rssi":-40,"freeHeap":20000,"uptime":1}"#.utf8))
        let before = model.preparedTransfers

        let inspected = await model.inspectLocalFirmware(source)

        XCTAssertEqual(inspected, PocketModel.LocalFirmwareImage(file: source, version: "1.4.1-test", byteCount: image.count))
        XCTAssertEqual(model.preparedTransfers, before, "Inspection prepares nothing")
        XCTAssertEqual(try Data(contentsOf: source), image)
    }

    func testRejectsFirmwareForAnotherChip() {
        var image = makeFirmwareImage()
        image[12] = 0

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .unsupportedChip)
        }
    }

    func testRejectsCorruptedFirmwareChecksum() {
        var image = makeFirmwareImage()
        let digestOffset = image.count - 32
        image[digestOffset - 1] ^= 0x01

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .checksumMismatch)
        }
    }

    func testRejectsCorruptedFirmwareDigest() {
        var image = makeFirmwareImage()
        image[image.count - 1] ^= 0x01

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .digestMismatch)
        }
    }

    func testRejectsUnidentifiedESP32Firmware() {
        let image = makeFirmwareImage(identity: "Unrelated application")

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .incompatibleProduct)
        }
    }

    func testValidatesCompatibleFirmwareWithoutAppendedDigest() throws {
        let image = makeFirmwareImage(hashAppended: false)
        XCTAssertEqual(try FirmwareImageValidator.validate(image).version, "1.4.1-test")
    }

    func testRejectsTruncatedFirmwareSegments() {
        var image = makeFirmwareImage()
        image.removeLast()

        XCTAssertThrowsError(try FirmwareImageValidator.validate(image)) { error in
            XCTAssertEqual(error as? FirmwareValidationError, .malformedSegments)
        }
    }

    func testSDCopyPublishesValidatedFirmware() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("update.bin")
        try makeFirmwareImage().write(to: source)

        let result = try PocketModel.copyToSDOffMain(source: source, root: fixture.sd)
        XCTAssertEqual(result, SDCopyResult(path: "/update.bin", firmwareVersion: "1.4.1-test"))
        XCTAssertEqual(
            try Data(contentsOf: fixture.sd.appendingPathComponent("update.bin")),
            try Data(contentsOf: source)
        )
    }

    func testSDCopyRenamesFirmwareToUpdateBinAndReplacesPreviousStaging() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let first = fixture.base.appendingPathComponent("pocket-daily-1.4.0.bin")
        try makeFirmwareImage(identity: "CrossPoint version: 1.4.0-test\0PocketNearbySync\0").write(to: first)
        let second = fixture.base.appendingPathComponent("pocket-daily-1.4.1.bin")
        try makeFirmwareImage().write(to: second)

        XCTAssertEqual(try PocketModel.copyToSDOffMain(source: first, root: fixture.sd).firmwareVersion, "1.4.0-test")
        XCTAssertEqual(try PocketModel.copyToSDOffMain(source: second, root: fixture.sd).firmwareVersion, "1.4.1-test")
        XCTAssertEqual(try Data(contentsOf: fixture.sd.appendingPathComponent("update.bin")), try Data(contentsOf: second))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sd.appendingPathComponent("pocket-daily-1.4.1.bin").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.sd.path).filter { $0.contains("pocket-staging") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testSDCopyNeverOverwritesContentFiles() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("book.epub")
        try Data("first".utf8).write(to: source)

        XCTAssertEqual(try PocketModel.copyToSDOffMain(source: source, root: fixture.sd).path, "/book.epub")
        try Data("second".utf8).write(to: source)
        XCTAssertThrowsError(try PocketModel.copyToSDOffMain(source: source, root: fixture.sd))
        XCTAssertEqual(try Data(contentsOf: fixture.sd.appendingPathComponent("book.epub")), Data("first".utf8))
    }

    @MainActor
    func testStatusPostCarriesExplicitTone() {
        let model = PocketModel()
        XCTAssertEqual(model.messageTone, .neutral)
        model.post("Staged", tone: .pending)
        XCTAssertEqual(model.message, "Staged")
        XCTAssertEqual(model.messageTone, .pending)
        model.post(FirmwareValidationError.tooSmall)
        XCTAssertEqual(model.messageTone, .failure)
        XCTAssertEqual(model.message, FirmwareValidationError.tooSmall.errorDescription)
        model.post("Connected")
        XCTAssertEqual(model.messageTone, .neutral)
    }

#if os(iOS)
    func testHotspotJoinerTreatsExistingAssociationAsJoined() {
        let associated = NSError(domain: NEHotspotConfigurationErrorDomain, code: NEHotspotConfigurationError.alreadyAssociated.rawValue)
        let denied = NSError(domain: NEHotspotConfigurationErrorDomain, code: NEHotspotConfigurationError.userDenied.rawValue)
        let other = NSError(domain: NEHotspotConfigurationErrorDomain, code: NEHotspotConfigurationError.invalidSSID.rawValue)
        XCTAssertTrue(HotspotJoiner.alreadyJoined(associated))
        XCTAssertFalse(HotspotJoiner.alreadyJoined(denied))
        XCTAssertTrue(HotspotJoiner.userCancelled(denied))
        XCTAssertFalse(HotspotJoiner.alreadyJoined(other))
        XCTAssertFalse(HotspotJoiner.alreadyJoined(URLError(.timedOut)))
    }
#endif

    func testSDCopyRejectsInvalidFirmwareBeforePublication() throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let source = fixture.base.appendingPathComponent("update.bin")
        try Data(repeating: 0, count: FirmwareImageValidator.minimumSize).write(to: source)

        XCTAssertThrowsError(try PocketModel.copyToSDOffMain(source: source, root: fixture.sd))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.sd.appendingPathComponent("update.bin").path))
    }

    private func temporaryFixture() throws -> (base: URL, sd: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sd = base.appendingPathComponent("SD", isDirectory: true)
        try FileManager.default.createDirectory(at: sd, withIntermediateDirectories: true)
        return (base, sd)
    }

    private func makeFirmwareImage(
        identity: String = "CrossPoint version: 1.4.1-test\0PocketNearbySync\0",
        hashAppended: Bool = true
    ) -> Data {
        var header = Data(repeating: 0, count: 24)
        header[0] = 0xE9
        header[1] = 1
        header[12] = 5
        header[23] = hashAppended ? 1 : 0

        var segment = Data(repeating: 0xA5, count: 64 * 1_024)
        writeUInt32(0xABCD_5432, to: &segment, at: 0)
        segment.replaceSubrange(128 ..< 128 + identity.utf8.count, with: identity.utf8)

        var segmentHeader = Data(repeating: 0, count: 8)
        writeUInt32(UInt32(segment.count), to: &segmentHeader, at: 4)

        var image = header
        image.append(segmentHeader)
        image.append(segment)

        let checksum = segment.reduce(UInt8(0xEF), ^)
        let paddedEnd = (image.count + 16) & ~15
        image.append(Data(repeating: 0, count: paddedEnd - image.count - 1))
        image.append(checksum)
        if hashAppended {
            image.append(contentsOf: SHA256.hash(data: image))
        }
        return image
    }

    private func writeUInt32(_ value: UInt32, to data: inout Data, at offset: Int) {
        data[offset] = UInt8(truncatingIfNeeded: value)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }
}

@MainActor
private final class ControlledDiscoveryIO: ReaderDiscoveryIO {
    var rememberedHost: String? { nil }
    var bonjourCalls = 0
    var statusCalls = 0
    let delay: Duration
    var endpoint: (host: String, port: Int)?
    var statusDelay: Duration = .zero
    var response: CrossPointStatus?
    var holdBonjour = false
    private var heldBonjour: CheckedContinuation<Void, Never>?

    init(delay: Duration = .zero) { self.delay = delay }
    func candidates() -> [String] { [] }
    func firstBonjour(timeout: Duration) async -> (host: String, port: Int)? {
        bonjourCalls += 1
        if holdBonjour { await withCheckedContinuation { heldBonjour = $0 } }
        try? await Task.sleep(for: delay)
        return endpoint
    }
    func stop() {}
    func releaseBonjour() {
        holdBonjour = false
        heldBonjour?.resume()
        heldBonjour = nil
    }
    func status(host: String, port: Int, timeout: TimeInterval) async throws -> CrossPointStatus {
        statusCalls += 1
        try? await Task.sleep(for: statusDelay)
        if let response { return response }
        throw URLError(.cannotConnectToHost)
    }
}

@MainActor
private final class HeldAssociationIO: ReaderAssociationIO {
    private(set) var joinCount = 0
    private(set) var joinedSSIDs: [String] = []
    private(set) var leftSSIDs: [String] = []
    var holdLeave = false
    private var leaving: CheckedContinuation<Void, Never>?
    private var pending: [Int: CheckedContinuation<Void, Error>] = [:]

    func join(_ lease: HotspotLease) async throws {
        let index = joinCount
        joinCount += 1
        joinedSSIDs.append(lease.ssid)
        try await withCheckedThrowingContinuation { pending[index] = $0 }
    }
    func leave(ssid: String) async {
        leftSSIDs.append(ssid)
        if holdLeave { await withCheckedContinuation { leaving = $0 } }
    }
    func releaseLeave() {
        holdLeave = false
        leaving?.resume()
        leaving = nil
    }
    func succeed(_ index: Int) { pending.removeValue(forKey: index)?.resume() }
    func failAll() {
        releaseLeave()
        let waiters = Array(pending.values)
        pending.removeAll()
        for waiter in waiters { waiter.resume(throwing: URLError(.cannotConnectToHost)) }
    }
}

// MARK: - Resumable upload stream

/// A loopback stand-in for the reader's port-82 listener. It records the
/// request header, answers it with a scripted line, and answers again once the
/// scripted amount of payload has arrived.
private final class FakeUploadReader: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake.upload.reader")
    private var connection: NWConnection?
    private var buffer = Data()
    private var headerHandled = false
    private var payloadHandled = false
    private var readyContinuation: CheckedContinuation<UInt16, Error>?
    private(set) var header = ""
    private let expectedPayload: Int
    private let flowPrefix: Int?
    private var acknowledgedPayload = 0
    private var ackScheduled = false
    private(set) var flowViolation = false
    private let onHeader: @Sendable (String) -> Data?
    private let onPayload: @Sendable (Data) -> Data?

    init(
        expectedPayload: Int,
        flowPrefix: Int? = nil,
        onHeader: @escaping @Sendable (String) -> Data?,
        onPayload: @escaping @Sendable (Data) -> Data?
    ) throws {
        listener = try NWListener(using: .tcp, on: .any)
        self.expectedPayload = expectedPayload
        self.flowPrefix = flowPrefix
        self.onHeader = onHeader
        self.onPayload = onPayload
    }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            readyContinuation = continuation
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, let continuation = self.readyContinuation else { return }
                switch state {
                case .ready:
                    self.readyContinuation = nil
                    continuation.resume(returning: self.listener.port?.rawValue ?? 0)
                case let .failed(error):
                    self.readyContinuation = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connection = connection
                connection.start(queue: self.queue)
                self.receive(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        connection?.cancel()
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.process(connection)
            }
            if error == nil, !isComplete { self.receive(connection) }
        }
    }

    private func process(_ connection: NWConnection) {
        if !headerHandled, let terminator = buffer.range(of: Data("\n\n".utf8)) {
            headerHandled = true
            header = String(decoding: buffer[buffer.startIndex ..< terminator.lowerBound], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex ..< terminator.upperBound)
            if let reply = onHeader(header) {
                connection.send(content: reply, completion: .contentProcessed { _ in })
            }
        }
        if headerHandled, let prefix = flowPrefix {
            if buffer.count - acknowledgedPayload > 4096 { flowViolation = true }
            if buffer.count < expectedPayload, buffer.count - acknowledgedPayload == 4096, !ackScheduled {
                ackScheduled = true
                queue.asyncAfter(deadline: .now() + .milliseconds(1)) { [self] in
                    acknowledgedPayload = buffer.count
                    ackScheduled = false
                    let ack = Data("ACK \(prefix + acknowledgedPayload)\n".utf8)
                    connection.send(content: ack, completion: .contentProcessed { _ in })
                }
            }
        }
        if headerHandled, !payloadHandled, buffer.count >= expectedPayload {
            payloadHandled = true
            if let reply = onPayload(buffer) {
                connection.send(content: reply, completion: .contentProcessed { _ in })
            }
        }
    }
}

extension NearbySyncProtocolTests {
    private func recoveryClient(_ replies: [Result<Data, URLError>]) -> CrossPointClient {
        RecoveryURLProtocol.configure(replies)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RecoveryURLProtocol.self]
        return CrossPointClient(session: URLSession(configuration: config))
    }

    private var recoveryStatus: Data {
        Data(#"{"version":"test","ip":"127.0.0.1","mode":"STA","rssi":-50,"freeHeap":8000,"uptime":1,"device":"X3","deviceID":"12345678","uploadStreamWindow":4096}"#.utf8)
    }

    func testLANRecoveryWaitsForReaderBeforeResuming() async throws {
        let client = recoveryClient([.failure(URLError(.timedOut)), .failure(URLError(.cannotConnectToHost)), .success(recoveryStatus)])
        try await client.waitForReader(host: "reader.test", port: 80, expectedDeviceID: "12345678",
                                       recoveryBudget: .seconds(2), probeSpacing: .zero)
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 3)
        let decoded = try JSONDecoder().decode(CrossPointStatus.self, from: recoveryStatus)
        XCTAssertEqual(decoded.uploadStreamWindow, 4096)
    }

    func testRecoveryRejectsAddressReassignedToAnotherReader() async throws {
        let client = recoveryClient([.success(recoveryStatus)])
        do {
            try await client.waitForReader(host: "reader.test", port: 80, expectedDeviceID: "87654321",
                                           recoveryBudget: .seconds(2), probeSpacing: .zero)
            XCTFail("must not resume onto another reader")
        } catch let error as CrossPointClient.ClientError {
            guard case .unexpectedMessage = error else { return XCTFail("wrong error: \(error)") }
        }
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 1)
    }

    func testRecoveryDoesNotRetryMalformedStatus() async throws {
        let client = recoveryClient([.success(Data("{}".utf8))])
        do {
            try await client.waitForReader(host: "reader.test", port: 80, expectedDeviceID: nil,
                                           recoveryBudget: .seconds(2), probeSpacing: .zero)
            XCTFail("malformed response must fail")
        } catch is DecodingError { }
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 1)
    }

    func testRecoveryBudgetCanExpireWithoutOpeningAnotherSocket() async throws {
        let client = recoveryClient([])
        do {
            try await client.waitForReader(host: "reader.test", port: 80, expectedDeviceID: nil,
                                           recoveryBudget: .zero, probeSpacing: .zero)
            XCTFail("expired budget must fail")
        } catch let error as PocketStreamUploader.StreamError {
            XCTAssertEqual(error, .stalled)
        }
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 0)
    }

    func testFlowControlledFirmwareWaitsForSDCreditAcrossSixMegabytes() async throws {
        let (url, payload) = try makePayloadFile(bytes: 6 * 1024 * 1024 + 17)
        defer { try? FileManager.default.removeItem(at: url) }
        let prefix = 131_077 // non-aligned retained prefix, plus a short final block
        var crc = CRC32()
        crc.update(payload)
        let expectedCRC = crc.finalized
        let reader = try FakeUploadReader(
            expectedPayload: payload.count - prefix, flowPrefix: prefix,
            onHeader: { _ in Data("RESUME \(prefix)\n".utf8) },
            onPayload: { received in
                received == payload[prefix...]
                    ? Data("OK \(payload.count) \(String(format: "%08X", expectedCRC))\n".utf8)
                    : Data("ERROR payload mismatch\n".utf8)
            }
        )
        let port = try await reader.start()
        defer { reader.stop() }
        let started = ContinuousClock.now
        let lastProgress = LockedBox((bytes: Int64(0), at: started))
        let uploader = try PocketStreamUploader(
            fileURL: url, host: "127.0.0.1", port: Int(port), remotePath: "/.pocket-flow.part",
            total: Int64(payload.count), flowControl: true
        ) { bytes, _ in lastProgress.set((bytes: bytes, at: ContinuousClock.now)) }
        let result: UInt32
        do {
            result = try await uploader.upload()
        } catch {
            // Keep failure evidence bounded and local: offsets and durations,
            // never file bytes. Do not relax timeouts or silently retry a stall.
            let progress = lastProgress.value
            let now = ContinuousClock.now
            XCTFail("Loopback flow upload failed: \(error); confirmed offset \(progress.bytes)/\(payload.count), elapsed \(now - started), since progress \(now - progress.at)")
            return
        }
        XCTAssertEqual(result, expectedCRC)
        XCTAssertFalse(reader.flowViolation, "sender exceeded the reader's 4 KiB credit")
        XCTAssertTrue(reader.header.contains("Window: 4096"))
        XCTAssertTrue(reader.header.contains("Resume: 1"))
    }

    func testFlowControlRejectsUnsentAcknowledgement() async throws {
        let (url, payload) = try makePayloadFile(bytes: 9000)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try FakeUploadReader(expectedPayload: .max,
            onHeader: { _ in Data("RESUME 0\nACK 8192\n".utf8) }, onPayload: { _ in nil })
        let port = try await reader.start()
        defer { reader.stop() }
        let uploader = try PocketStreamUploader(fileURL: url, host: "127.0.0.1", port: Int(port),
            remotePath: "/.pocket-flow.part", total: Int64(payload.count), flowControl: true) { _, _ in }
        do {
            _ = try await uploader.upload()
            XCTFail("An ACK for unsent bytes must not grant credit")
        } catch let error as PocketStreamUploader.StreamError {
            XCTAssertEqual(error, .invalidResponse("ACK 8192"))
        }
    }

    func testLostFinalReplyCanResumeAtCompleteSizeWithoutResendingPayload() async throws {
        let (url, payload) = try makePayloadFile(bytes: 8193)
        defer { try? FileManager.default.removeItem(at: url) }
        var crc = CRC32()
        crc.update(payload)
        let expectedCRC = crc.finalized
        let reader = try FakeUploadReader(expectedPayload: 0,
            onHeader: { _ in Data("RESUME \(payload.count)\n".utf8) },
            onPayload: { bytes in
                bytes.isEmpty ? Data("OK \(payload.count) \(String(format: "%08X", expectedCRC))\n".utf8) : nil
            })
        let port = try await reader.start()
        defer { reader.stop() }
        let uploader = try PocketStreamUploader(fileURL: url, host: "127.0.0.1", port: Int(port),
            remotePath: "/.pocket-complete.part", total: Int64(payload.count), flowControl: true) { _, _ in }
        let result = try await uploader.upload()
        XCTAssertEqual(result, expectedCRC)
    }

    func testFlowControlCancellationDoesNotWaitForMissingAck() async throws {
        let (url, payload) = try makePayloadFile(bytes: 8192)
        defer { try? FileManager.default.removeItem(at: url) }
        let firstBlock = expectation(description: "first block reached reader")
        let reader = try FakeUploadReader(expectedPayload: 4096,
            onHeader: { _ in Data("RESUME 0\n".utf8) },
            onPayload: { _ in firstBlock.fulfill(); return nil })
        let port = try await reader.start()
        defer { reader.stop() }
        let uploader = try PocketStreamUploader(fileURL: url, host: "127.0.0.1", port: Int(port),
            remotePath: "/.pocket-cancel.part", total: Int64(payload.count), flowControl: true) { _, _ in }
        let task = Task { try await uploader.upload() }
        await fulfillment(of: [firstBlock], timeout: 3)
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("cancelled upload must stop")
        } catch is CancellationError { }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    func testFlowControlCancellationDuringPacedWindow() async throws {
        let (url, payload) = try makePayloadFile(bytes: 8192)
        defer { try? FileManager.default.removeItem(at: url) }
        let firstFragment = expectation(description: "first paced fragment arrived")
        let reader = try FakeUploadReader(expectedPayload: 512,
            onHeader: { _ in Data("RESUME 0\n".utf8) },
            onPayload: { _ in firstFragment.fulfill(); return nil })
        let port = try await reader.start()
        defer { reader.stop() }
        let uploader = try PocketStreamUploader(fileURL: url, host: "127.0.0.1", port: Int(port),
            remotePath: "/.pocket-paced.part", total: Int64(payload.count), flowControl: true) { _, _ in }
        let task = Task { try await uploader.upload() }
        await fulfillment(of: [firstFragment], timeout: 3)
        let start = ContinuousClock.now
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("scheduled fragments must not prevent cancellation")
        } catch is CancellationError { }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(1))
    }

    private func makePayloadFile(bytes: Int) throws -> (URL, Data) {
        var generator = SystemRandomNumberGenerator()
        let payload = Data((0 ..< bytes).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-stream-\(UUID().uuidString).bin")
        try payload.write(to: url)
        return (url, payload)
    }

    func testStatusAdvertisesResumableUploadStream() throws {
        let data = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":16000,"uptime":4,"device":"X3","uploadStreamPort":82,"uploadStreamResume":true}"#.utf8)
        let status = try JSONDecoder().decode(CrossPointStatus.self, from: data)
        XCTAssertEqual(status.uploadStreamResume, true)

        let legacy = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":16000,"uptime":4,"device":"X3","uploadStreamPort":82}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(CrossPointStatus.self, from: legacy).uploadStreamResume)
    }

    func testDiagnosticsSkippedOnLowHeapReader() throws {
        XCTAssertFalse(ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: 6_996, readerSaysAffordable: nil))
        XCTAssertTrue(ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: 16_312, readerSaysAffordable: nil))
        // A reader that measures itself wins over the app-side heuristic.
        XCTAssertTrue(ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: 6_996, readerSaysAffordable: true))
        XCTAssertFalse(ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: 32_000, readerSaysAffordable: false))

        let data = Data(#"{"version":"test","ip":"192.168.4.1","mode":"AP","rssi":0,"freeHeap":6996,"uptime":4,"device":"X3","diagnosticsAffordable":false}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(CrossPointStatus.self, from: data).diagnosticsAffordable, false)
    }

    func testFirmwareInstallCheckComparesStagedWithRunning() {
        let staged = "1.4.1-dev-main-551001f5-wacf0cb93"
        XCTAssertEqual(
            FirmwareInstallCheck.evaluate(readerVersion: staged, staged: staged),
            .installed(staged)
        )
        XCTAssertEqual(
            FirmwareInstallCheck.evaluate(readerVersion: "1.4.1-dev-main-551001f5-w6799521f", staged: staged),
            .stillPending(running: "1.4.1-dev-main-551001f5-w6799521f", staged: staged)
        )
        XCTAssertEqual(FirmwareInstallCheck.evaluate(readerVersion: staged, staged: nil), .nothingStaged)
        XCTAssertEqual(FirmwareInstallCheck.evaluate(readerVersion: staged, staged: ""), .nothingStaged)
        // Whitespace from either side must not defeat the comparison.
        XCTAssertEqual(FirmwareInstallCheck.evaluate(readerVersion: staged + "\n", staged: " " + staged), .installed(staged))
    }

    func testStreamHeaderAddsResumeOnlyWhenRequested() {
        let fresh = String(decoding: PocketStreamUploader.header(path: "/.pocket-a.part", size: 12, resume: false), as: UTF8.self)
        XCTAssertEqual(fresh, "POCKET-PUT/1\nPath: /.pocket-a.part\nSize: 12\n\n")
        let resumed = String(decoding: PocketStreamUploader.header(path: "/.pocket-a.part", size: 12, resume: true), as: UTF8.self)
        XCTAssertEqual(resumed, "POCKET-PUT/1\nPath: /.pocket-a.part\nSize: 12\nResume: 1\n\n")
    }

    func testStreamReplyParsing() {
        XCTAssertEqual(PocketStreamUploader.Reply.parse("OK 2621440 CBF43926\n"), .ok(size: 2_621_440, crc32: 0xCBF4_3926))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("RESUME 65536"), .resume(offset: 65_536))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("ERROR SD write failed"), .error("SD write failed"))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("OK 12"), .invalid("OK 12"))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("RESUME x"), .invalid("RESUME x"))
        XCTAssertEqual(PocketStreamUploader.Reply.parse("READY"), .invalid("READY"))
    }

    func testRetryPolicyRetriesTransportFailuresOnly() {
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.readerRejected("Upload timed out"), attempt: 1))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.readerRejected("Upload disconnected"), attempt: 1))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.disconnected, attempt: 1))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.stalled, attempt: 2))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(URLError(.networkConnectionLost), attempt: 1))
        XCTAssertTrue(UploadRetryPolicy.shouldRetry(NWError.posix(.ECONNRESET), attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.readerRejected("SD write failed"), attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.verificationFailed, attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.timedOut, attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(CancellationError(), attempt: 1))
        XCTAssertFalse(UploadRetryPolicy.shouldRetry(PocketStreamUploader.StreamError.disconnected, attempt: 3))
        XCTAssertEqual(UploadRetryPolicy.delay(afterAttempt: 1), .seconds(1))
        XCTAssertEqual(UploadRetryPolicy.delay(afterAttempt: 9), .seconds(3))
    }

    func testStreamUploaderResumesFromReaderPrefix() async throws {
        let (url, payload) = try makePayloadFile(bytes: 6 * 1024 * 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        let prefix = 131_072
        var whole = CRC32()
        whole.update(payload)
        let expectedCRC = whole.finalized

        let reader = try FakeUploadReader(
            expectedPayload: payload.count - prefix,
            onHeader: { _ in Data("RESUME \(prefix)\n".utf8) },
            onPayload: { received in
                received == payload[prefix...] ? Data("OK \(payload.count) \(String(format: "%08X", expectedCRC))\n".utf8)
                                               : Data("ERROR payload mismatch\n".utf8)
            }
        )
        let port = try await reader.start()
        defer { reader.stop() }

        let firstProgress = LockedBox<Int64?>(nil)
        let uploader = try PocketStreamUploader(
            fileURL: url, host: "127.0.0.1", port: Int(port), remotePath: "/.pocket-test.part",
            total: Int64(payload.count), resume: true
        ) { sent, _ in firstProgress.setIfNil(sent) }
        let crc = try await uploader.upload()

        XCTAssertEqual(crc, expectedCRC)
        XCTAssertEqual(firstProgress.value, Int64(prefix))
        XCTAssertTrue(reader.header.hasSuffix("Resume: 1"), reader.header)
    }

    func testStreamUploaderSurfacesEarlyReaderError() async throws {
        let (url, payload) = try makePayloadFile(bytes: 200_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try FakeUploadReader(
            expectedPayload: .max,
            onHeader: { _ in Data("ERROR SD write failed\n".utf8) },
            onPayload: { _ in nil }
        )
        let port = try await reader.start()
        defer { reader.stop() }

        let uploader = try PocketStreamUploader(
            fileURL: url, host: "127.0.0.1", port: Int(port), remotePath: "/.pocket-test.part",
            total: Int64(payload.count)
        ) { _, _ in }
        do {
            _ = try await uploader.upload()
            XCTFail("the reader's rejection must abort the transfer")
        } catch let error as PocketStreamUploader.StreamError {
            XCTAssertEqual(error, .readerRejected("SD write failed"))
            XCTAssertFalse(UploadRetryPolicy.shouldRetry(error, attempt: 1))
        }
        XCTAssertFalse(reader.header.contains("Resume"))
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func set(_ value: Value) { lock.withLock { stored = value } }
    func setIfNil<Wrapped>(_ newValue: Wrapped) where Value == Wrapped? {
        lock.withLock { if stored == nil { stored = newValue } }
    }
}

/// Requests remain pending until the test releases them or URLSession cancels.
/// No real sockets, device access, or scheduled response delay is involved.
private final class HeldReaderURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pending: [HeldReaderURLProtocol] = []
    private var stopped = false
    private var completed = false
    private var activeAtStart = 0
    var olderActiveRequests: Int { Self.lock.withLock { activeAtStart } }
    static var requests: [HeldReaderURLProtocol] { lock.withLock { pending } }
    var wasStopped: Bool { Self.lock.withLock { stopped } }
    static func reset() { lock.withLock { pending = [] } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.withLock {
            activeAtStart = Self.pending.filter { !$0.stopped && !$0.completed }.count
            Self.pending.append(self)
        }
    }
    override func stopLoading() { Self.lock.withLock { stopped = true } }
    func succeed(_ data: Data = Data()) { respond(status: 200, data) }
    func respond(status: Int, _ data: Data = Data()) {
        guard !wasStopped, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else { return }
        Self.lock.withLock { completed = true }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class RecoveryURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var replies: [Result<Data, URLError>] = []
    nonisolated(unsafe) private static var count = 0
    static var requestCount: Int { lock.withLock { count } }
    static func configure(_ values: [Result<Data, URLError>]) {
        lock.withLock { replies = values; count = 0 }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply: Result<Data, URLError> = Self.lock.withLock {
            Self.count += 1
            return Self.replies.isEmpty ? .failure(URLError(.timedOut)) : Self.replies.removeFirst()
        }
        switch reply {
        case let .failure(error): client?.urlProtocol(self, didFailWithError: error)
        case let .success(data):
            guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200,
                httpVersion: "HTTP/1.1", headerFields: nil) else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}


@MainActor
private final class QuietAuditDiscovery: ReaderDiscoveryIO {
    var rememberedHost: String? { "reader.test" }
    var entered = false
    var pending: CheckedContinuation<CrossPointStatus, Error>?
    func candidates() -> [String] { [] }
    func firstBonjour(timeout: Duration) async -> (host: String, port: Int)? { nil }
    func stop() {}
    func status(host: String, port: Int, timeout: TimeInterval) async throws -> CrossPointStatus {
        entered = true
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func release() throws {
        let status = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"t","device":"X3","deviceID":"1234ABCD","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"readingProgress":1}"#.utf8))
        pending?.resume(returning: status)
        pending = nil
    }
}

extension NearbySyncProtocolTests {
    @MainActor
    func testQuietProbeCannotContinueAfterDemoOrBackground() async throws {
        let key = "Pocket.lastReaderDeviceID"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set("1234ABCD", forKey: key)
        for demo in [true, false] {
            HeldReaderURLProtocol.reset()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [HeldReaderURLProtocol.self]
            let session = URLSession(configuration: config)
            let discovery = QuietAuditDiscovery()
            let model = PocketModel(discoveryIO: discovery, client: CrossPointClient(session: session))
            defer { model.pauseForBackground(); session.invalidateAndCancel() }
            model.quietReadingExchange(minimumInterval: 0, prepare: { _, _ in
                XCTFail("Stale exchange prepared offers"); return []
            }, finish: { _, _, _ in XCTFail("Stale exchange reported completion") })
            for _ in 0..<100 where !discovery.entered { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(discovery.entered)
            XCTAssertFalse(model.isWorking, "Background work must not disable user controls")
            if demo { model.enterDemoMode(); XCTAssertTrue(model.isDemoMode) }
            else { model.pauseForBackground() }
            try discovery.release() // Simulates an OS operation ignoring cancellation.
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertTrue(HeldReaderURLProtocol.requests.isEmpty)
        }
    }

    @MainActor
    func testForegroundEnablesQuietExchangeAndDemoCancelsItsActiveRead() async throws {
        let key = "Pocket.lastReaderDeviceID"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set("1234ABCD", forKey: key)
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        let discovery = QuietAuditDiscovery()
        let model = PocketModel(discoveryIO: discovery, client: CrossPointClient(session: session))
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        model.pauseForBackground()
        model.quietReadingExchange(minimumInterval: 0, prepare: { _, _ in [] }, finish: { _, _, _ in })
        XCTAssertFalse(discovery.entered)
        model.resumeForForeground()
        model.quietReadingExchange(minimumInterval: 0, prepare: { _, _ in
            XCTFail("Cancelled read prepared offers"); return []
        }, finish: { _, _, _ in XCTFail("Cancelled read completed") })
        for _ in 0..<100 where !discovery.entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(discovery.entered)
        try discovery.release()
        let request = try await heldRequest(0)
        XCTAssertEqual(request.request.url?.path, "/api/pocket/v1/reading")
        model.enterDemoMode()
        for _ in 0..<100 where !request.wasStopped { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(request.wasStopped)
        XCTAssertTrue(model.isDemoMode)
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 1)
    }

    @MainActor
    func testUserConnectionDrainsQuietProbeBeforeOpeningSocket() async throws {
        let key = "Pocket.lastReaderDeviceID"
        let previous = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        UserDefaults.standard.set("1234ABCD", forKey: key)
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        let discovery = QuietAuditDiscovery()
        let model = PocketModel(discoveryIO: discovery, client: CrossPointClient(session: session))
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        model.quietReadingExchange(minimumInterval: 0, prepare: { _, _ in
            XCTFail("Superseded exchange prepared offers"); return []
        }, finish: { _, _, _ in XCTFail("Superseded exchange completed") })
        for _ in 0..<100 where !discovery.entered { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(discovery.entered)
        let next = Task { await model.verify(host: "new-reader.test", port: 80) }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.isWorking)
        XCTAssertTrue(HeldReaderURLProtocol.requests.isEmpty, "Must drain the predecessor")
        try discovery.release()
        let request = try await heldRequest(0)
        XCTAssertEqual(request.request.url?.host, "new-reader.test")
        XCTAssertEqual(request.olderActiveRequests, 0)
        next.cancel()
        await next.value
    }

    func testSettingsPreflightRejectsChangedIdentityBeforePost() async throws {
        let body = Data(#"{"version":"t","device":"X3","deviceID":"BBBBBBBB","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8)
        let client = recoveryClient([.success(body)])
        do {
            try await client.save(preferences: ReaderPreferences(), host: "reader.test", port: 80, expectedDeviceID: "AAAAAAAA")
            XCTFail("Changed reader accepted settings")
        } catch {}
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 1, "Only the identity probe, no POST")
    }

    func testAtomicTransferAdmissionRejectsPlainCrossPoint() throws {
        let data = Data(#"{"version":"1.6.5","device":"X3","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8)
        let plain = try JSONDecoder().decode(CrossPointStatus.self, from: data)
        XCTAssertFalse(plain.supportsAtomicUpload)
        var pocket = plain
        pocket.transferControl = 1
        XCTAssertTrue(pocket.supportsAtomicUpload)
    }
}


extension NearbySyncProtocolTests {
    func testLostCommitResponseIsUnconfirmedAndRunsWriteAheadMarker() async throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let file = fixture.base.appendingPathComponent("book.epub")
        let marker = fixture.base.appendingPathComponent("pending")
        let bytes = Data("book".utf8)
        try bytes.write(to: file)
        var crc = CRC32()
        crc.update(bytes)
        let reply = Data("OK 4 \(String(format: "%08X", crc.finalized))\n".utf8)
        let reader = try FakeUploadReader(expectedPayload: 4, onHeader: { _ in nil }, onPayload: { _ in reply })
        let port = try await reader.start()
        defer { reader.stop() }
        let client = recoveryClient([.failure(URLError(.networkConnectionLost))])
        do {
            _ = try await client.uploadAtomically(fileURL: file, host: "127.0.0.1", port: 80,
                uploadStreamPort: Int(port), beforeCommit: { try Data("pending".utf8).write(to: marker) },
                progress: { _, _ in })
            XCTFail("Lost commit response reported success")
        } catch CrossPointClient.ClientError.publicationUnconfirmed {
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 1, "Commit must not be retried")
    }
}

extension NearbySyncProtocolTests {
    func testLostCommitResponseRecoversOnlyFromAnExactSameReaderReceipt() async throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let file = fixture.base.appendingPathComponent("book.epub")
        let bytes = Data("nonuniform book contents 1937".utf8)
        try bytes.write(to: file)
        var crc = CRC32(); crc.update(bytes)
        let receipt = Data("{\"size\":\(bytes.count),\"crc32\":\"\(String(format: "%08X", crc.finalized))\"}".utf8)
        let status = Data(#"{"version":"test","device":"X3","deviceID":"ABCD1234","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"publicationReceipt":1}"#.utf8)
        let reply = Data("OK \(bytes.count) \(String(format: "%08X", crc.finalized))\n".utf8)
        let reader = try FakeUploadReader(expectedPayload: bytes.count, onHeader: { _ in nil }, onPayload: { _ in reply })
        let port = try await reader.start()
        defer { reader.stop() }
        let client = recoveryClient([.failure(URLError(.networkConnectionLost)), .success(status), .success(receipt)])
        let path = try await client.uploadAtomically(fileURL: file, host: "127.0.0.1", port: 80,
            uploadStreamPort: Int(port), expectedDeviceID: "ABCD1234", publicationReceipt: true,
            progress: { _, _ in })
        XCTAssertEqual(path, "/book.epub")
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 3)
    }

    func testPublicationRecoveryAfterRestartDoesNotUploadAndRejectsOtherReaderOrChangedChecksum() async throws {
        let fixture = try temporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.base) }
        let file = fixture.base.appendingPathComponent("book.epub")
        let bytes = Data("book".utf8)
        try bytes.write(to: file)
        let transferID = UUID()
        let status = Data(#"{"version":"test","device":"X3","deviceID":"ABCD1234","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"publicationReceipt":1}"#.utf8)
        let wrong = recoveryClient([.success(status)])
        do {
            _ = try await wrong.uploadAtomically(fileURL: file, host: "reader.test", expectedDeviceID: "00000000",
                transferID: transferID, transferControl: true, publicationReceipt: true, recoverPublicationOnly: true,
                progress: { _, _ in XCTFail("Recovery must not upload") })
            XCTFail("Wrong identity confirmed a publication")
        } catch CrossPointClient.ClientError.publicationUnconfirmed { }
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 1)
        let corrupt = recoveryClient([.success(status), .success(Data(#"{"size":4,"crc32":"00000000"}"#.utf8))])
        do {
            _ = try await corrupt.confirmPublication(fileURL: file, publishedFilename: "book.epub", destination: "/",
                transferID: transferID, host: "reader.test", port: 80, expectedDeviceID: "ABCD1234")
            XCTFail("Wrong checksum confirmed a publication")
        } catch CrossPointClient.ClientError.publicationUnconfirmed { }
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 2)
        let receipt = Data("{\"size\":4,\"crc32\":\"\(String(format: "%08X", CRC32.checksum(bytes)))\"}".utf8)
        let correct = recoveryClient([.success(status), .success(receipt)])
        let path = try await correct.confirmPublication(fileURL: file, publishedFilename: "book.epub", destination: "/",
            transferID: transferID, host: "reader.test", port: 80, expectedDeviceID: "ABCD1234")
        XCTAssertEqual(path, "/book.epub")
        XCTAssertEqual(RecoveryURLProtocol.requestCount, 2)
    }
}

extension NearbySyncProtocolTests {
    @MainActor func testSameWiFiSessionEndsThroughAdvertisedEndpoint() async throws {
        HeldReaderURLProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HeldReaderURLProtocol.self]
        let session = URLSession(configuration: config)
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session))
        defer { model.pauseForBackground(); session.invalidateAndCancel() }
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"test","device":"X3","deviceID":"ABCD1234","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1,"sessionEnd":true}"#.utf8))
        XCTAssertFalse(model.hasDirectSession)
        model.endConnection()
        let request = try await heldRequest(0)
        XCTAssertEqual(request.request.url?.path, "/api/pocket/v1/session/end")
        XCTAssertEqual(request.request.httpMethod, "POST")
        request.succeed(Data(#"{"ended":true}"#.utf8))
        for _ in 0..<100 where model.isWorking { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.readerStatus)
        XCTAssertFalse(model.isWorking)
        XCTAssertEqual(HeldReaderURLProtocol.requests.count, 1)
    }
}
