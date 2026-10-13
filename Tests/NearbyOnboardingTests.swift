import CoreBluetooth
import XCTest
@testable import Pocket

@MainActor
final class NearbyOnboardingTests: XCTestCase {
    func testUnavailableLocalNetworkCanFinishCancelAndRetryWithoutAPairedReader() async throws {
        let domain = "Pocket.onboarding-discovery." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let transport = ReaderBluetoothLinkTests.FakeTransport()
        let link = ReaderBluetoothLink(transport: transport,
            store: RememberedBluetoothReaderStore(defaults: defaults),
            sync: ReadingSync(defaults: defaults, iCloudAvailable: { false }), books: { [] },
            scheduler: ReaderBluetoothLinkTests.ManualScheduler())
        let io = DeniedDiscovery()
        let model = PocketModel(discoveryIO: io,
            sessionStorage: ReaderSessionStorage(root: root, defaults: defaults), bluetoothLink: link)
        defer { model.pauseForBackground() }
        func drain() async throws {
            let end = ContinuousClock.now + .seconds(5)
            while model.isWorking || model.bookTransferJobsLoading {
                XCTAssertLessThan(ContinuousClock.now, end)
                if ContinuousClock.now >= end { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await drain()
        model.startConnectionSearch()
        try await drain()
        XCTAssertEqual(model.messageTone, .failure)
        XCTAssertTrue(model.message.contains("Local Network"))
        XCTAssertTrue(model.message.contains("Same Wi-Fi"))
        XCTAssertNil(model.readerStatus)
        XCTAssertGreaterThan(io.requests, 0)
        XCTAssertTrue(transport.connects.isEmpty, "Offline first use must not wake an unrelated remembered reader")
        model.startConnectionSearch()
        model.cancelConnectionAttempt()
        try await drain()
        XCTAssertFalse(model.hasDirectSession)
        XCTAssertFalse(model.isCancellingConnection)
        let requests = io.requests
        model.startConnectionSearch()
        try await drain()
        XCTAssertGreaterThan(io.requests, requests)
        XCTAssertEqual(model.messageTone, .failure)
    }

    @MainActor
    func testNearbyCancellationWhilePermissionPendingIgnoresLateRadioChanges() {
        var ownership: [Bool] = []
        let controller = NearbySyncController(persistsTrace: false, ownershipChanged: { ownership.append($0) })
        XCTAssertFalse(controller.prepareScan(for: .unknown))
        XCTAssertEqual(controller.state, .scanning)
        XCTAssertTrue(controller.ownsBluetooth)

        controller.disconnect()
        for radioState: CBManagerState in [.unauthorized, .poweredOff, .poweredOn] {
            XCTAssertFalse(controller.updateBluetoothState(radioState))
            XCTAssertEqual(controller.state, .idle)
            XCTAssertFalse(controller.ownsBluetooth)
        }
        XCTAssertEqual(ownership, [true, false])
    }

    @MainActor
    func testNearbyPermissionDenialAndRadioLossRequireExplicitRetry() {
        for radioState: CBManagerState in [.unauthorized, .poweredOff, .unsupported] {
            let controller = NearbySyncController(persistsTrace: false)
            XCTAssertTrue(controller.prepareScan(for: .poweredOn))
            XCTAssertTrue(controller.ownsBluetooth)
            XCTAssertFalse(controller.updateBluetoothState(radioState))
            let failure = controller.state
            XCTAssertNotNil(failure.failureMessage)
            if radioState == .unauthorized {
                XCTAssertEqual(failure, .failed(NearbySyncController.unauthorizedMessage))
            }
            XCTAssertFalse(controller.ownsBluetooth)
            XCTAssertNil(controller.hotspotLease)
            XCTAssertNil(controller.connectedPeripheralID)
            XCTAssertFalse(controller.updateBluetoothState(.poweredOn))
            XCTAssertEqual(controller.state, failure)
            XCTAssertTrue(controller.prepareScan(for: .poweredOn))
            XCTAssertEqual(controller.state, .scanning)
            controller.disconnect()
        }
    }

    @MainActor
    func testNearbyRetryWhileRadioInitializesWaitsForPowerOn() {
        let controller = NearbySyncController(persistsTrace: false)
        for radioState: CBManagerState in [.unknown, .resetting] {
            XCTAssertFalse(controller.prepareScan(for: radioState))
            XCTAssertEqual(controller.state, .scanning)
            XCTAssertTrue(controller.ownsBluetooth)
            XCTAssertTrue(controller.updateBluetoothState(.poweredOn))
            XCTAssertFalse(controller.updateBluetoothState(.poweredOn), "Start each requested scan only once")
            controller.disconnect()
        }
    }

    @MainActor
    func testNearbyLateWriteFailureCannotReplaceCancellationOrRetry() {
        let controller = NearbySyncController(persistsTrace: false)
        let oldPeripheral = UUID()
        XCTAssertTrue(controller.prepareScan(for: .poweredOn))
        controller.disconnect()
        controller.handleWriteFailure(CBError(.operationCancelled), peripheralID: oldPeripheral)
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.prepareScan(for: .poweredOn))
        controller.handleWriteFailure(CBError(.operationCancelled), peripheralID: oldPeripheral)
        XCTAssertEqual(controller.state, .scanning)
        XCTAssertTrue(controller.ownsBluetooth)
        controller.disconnect()
    }

}

@MainActor
private final class DeniedDiscovery: ReaderDiscoveryIO {
    var rememberedHost: String? { nil }
    var requests = 0
    func candidates() -> [String] { ["192.0.2.1"] }
    func firstBonjour(timeout: Duration) async -> (host: String, port: Int)? { nil }
    func stop() {}
    func status(host: String, port: Int, timeout: TimeInterval) async throws -> CrossPointStatus {
        requests += 1
        throw URLError(.dataNotAllowed)
    }
}
