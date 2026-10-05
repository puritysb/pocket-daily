import XCTest
@testable import Pocket

final class DeviceSnapshotTests: XCTestCase {
    private func status(_ extra: String = "", deviceID: String? = "1234ABCD") throws -> CrossPointStatus {
        let id = deviceID.map { #","deviceID":"\#($0)""# } ?? ""
        return try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"t","device":"XTEINK X4","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1\#(id)\#(extra)}"#.utf8))
    }

    func testOfflineReaderIsUnnamedAndOffersNothing() {
        let device = DeviceSnapshot.crossPoint(status: nil, isDemo: false,
                                               isConnecting: false, isDirect: false)
        XCTAssertNil(device.model, "No model is claimed before a reader reports one")
        XCTAssertEqual(device.statusText, "Not connected")
        XCTAssertEqual(device.link, .offline)
        XCTAssertFalse(device.isConnected)
        XCTAssertTrue(device.capabilities.isEmpty)
        XCTAssertEqual(device.family.sections, [.connection, .screens, .files])
    }

    func testConnectedReaderMapsStatusFieldsToCapabilities() throws {
        let reader = try status(#","pocketProfile":1,"readerFiles":1,"readingProgress":1,"transferControl":1"#)
        let device = DeviceSnapshot.crossPoint(status: reader, isDemo: false,
                                               isConnecting: false, isDirect: false, bluetoothPaired: true, bluetoothSupported: true)
        XCTAssertEqual(device.model, "X4", "The connected reader names itself")
        XCTAssertEqual(device.link, .sameWiFi)
        XCTAssertEqual(device.statusText, "X4 · Same Wi-Fi")
        XCTAssertEqual(device.capabilities, [.screens, .files, .readingPositions, .firmwareUpdate, .bluetoothSync])
    }

    func testPairingAloneDoesNotClaimReadingSyncSupport() {
        let device = DeviceSnapshot.crossPoint(status: nil, isDemo: false, isConnecting: false,
                                               isDirect: false, bluetoothPaired: true)
        XCTAssertFalse(device.capabilities.contains(.bluetoothSync))
    }

    func testDirectSessionAndConnectingStates() throws {
        let direct = DeviceSnapshot.crossPoint(status: try status(), isDemo: false,
                                               isConnecting: false, isDirect: true)
        XCTAssertEqual(direct.link, .direct)
        XCTAssertEqual(direct.statusText, "X4 · Direct")
        XCTAssertTrue(direct.isConnected)
        let connecting = DeviceSnapshot.crossPoint(status: nil, isDemo: false,
                                                   isConnecting: true, isDirect: true)
        XCTAssertEqual(connecting.link, .connecting)
        XCTAssertFalse(connecting.isConnected)
    }

    func testUnidentifiedReaderCannotEditScreensOrExchangePositions() throws {
        let legacy = try status(#","pocketProfile":1,"readingProgress":1,"readerFiles":1"#, deviceID: nil)
        let device = DeviceSnapshot.crossPoint(status: legacy, isDemo: false,
                                               isConnecting: false, isDirect: false)
        XCTAssertEqual(device.capabilities, [.files])
    }

    func testDemoReaderIsShownButOffersNothing() throws {
        let reader = try status(#","pocketProfile":1,"readerFiles":1,"readingProgress":1"#)
        let device = DeviceSnapshot.crossPoint(status: reader, isDemo: true,
                                               isConnecting: false, isDirect: false, bluetoothPaired: true, bluetoothSupported: true)
        XCTAssertEqual(device.link, .demo)
        XCTAssertEqual(device.statusText, "Demo")
        XCTAssertFalse(device.isConnected)
        XCTAssertTrue(device.capabilities.isEmpty)
    }
}

// MARK: Same Wi-Fi reconnect

@MainActor
private final class RememberedReaderDiscovery: ReaderDiscoveryIO {
    var rememberedHost: String? { "reader.test" }
    var answersWithID: String? = "1234ABCD"
    private(set) var probes = 0
    func candidates() -> [String] { XCTFail("Reconnect must not sweep the network"); return [] }
    func firstBonjour(timeout: Duration) async -> (host: String, port: Int)? {
        XCTFail("Reconnect must not browse Bonjour"); return nil
    }
    func stop() {}
    func status(host: String, port: Int, timeout: TimeInterval) async throws -> CrossPointStatus {
        probes += 1
        XCTAssertEqual(host, "reader.test")
        guard let id = answersWithID else { throw URLError(.cannotConnectToHost) }
        return try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"version":"t","device":"X3","deviceID":"\#(id)","ip":"127.0.0.1","mode":"STA","rssi":-60,"freeHeap":20000,"uptime":1}"#.utf8))
    }
}

/// Every other reader request fails at once, so a session opens without a device.
private final class RefusingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)) }
    override func stopLoading() {}
}

extension DeviceSnapshotTests {
    private static let keys = ["Pocket.lastReaderDeviceID", "Pocket.lastReaderHost", PocketModel.autoReconnectKey]

    @MainActor
    private func withRememberedReader(_ body: (PocketModel, RememberedReaderDiscovery) async throws -> Void) async throws {
        let saved = Self.keys.map { UserDefaults.standard.object(forKey: $0) }
        defer { for (key, value) in zip(Self.keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        UserDefaults.standard.set("1234ABCD", forKey: "Pocket.lastReaderDeviceID")
        UserDefaults.standard.removeObject(forKey: PocketModel.autoReconnectKey)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefusingURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let discovery = RememberedReaderDiscovery()
        let model = PocketModel(discoveryIO: discovery, client: CrossPointClient(session: session))
        defer { model.pauseForBackground() }
        try await body(model, discovery)
    }

    @MainActor
    private func settle(_ model: PocketModel, until condition: () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(5)) }
    }

    @MainActor
    func testRememberedReaderReconnectsAtItsLastAddress() async throws {
        try await withRememberedReader { model, discovery in
            model.reconnectRememberedReader()
            try await settle(model) { model.readerStatus != nil }
            XCTAssertEqual(model.readerStatus?.deviceID, "1234ABCD")
            XCTAssertEqual(model.device.link, .sameWiFi)
            XCTAssertEqual(discovery.probes, 1)
        }
    }

    @MainActor
    func testAnotherReaderAtTheAddressIsLeftAlone() async throws {
        try await withRememberedReader { model, discovery in
            discovery.answersWithID = "FFFF0000"
            model.reconnectRememberedReader()
            try await settle(model) { discovery.probes > 0 }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNil(model.readerStatus)
        }
    }

    @MainActor
    func testDemoAndTheSettingStopReconnect() async throws {
        try await withRememberedReader { model, discovery in
            model.enterDemoMode()
            model.reconnectRememberedReader()
            model.exitDemoMode()
            UserDefaults.standard.set(false, forKey: PocketModel.autoReconnectKey)
            model.reconnectRememberedReader()
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(discovery.probes, 0)
            XCTAssertNil(model.readerStatus)
        }
    }

    @MainActor
    func testEndSessionHoldsUntilTheReaderLeavesSync() async throws {
        try await withRememberedReader { model, discovery in
            model.reconnectRememberedReader()
            try await settle(model) { model.readerStatus != nil && !model.isWorking }
            XCTAssertNotNil(model.readerStatus)
            model.endConnection()
            try await settle(model) { model.readerStatus == nil && !model.isWorking }
            XCTAssertNil(model.readerStatus)

            model.reconnectRememberedReader()
            try await settle(model) { discovery.probes == 2 }
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNil(model.readerStatus, "A reader still in Sync must not come back right after End session")

            discovery.answersWithID = nil // The reader left Sync.
            model.reconnectRememberedReader()
            try await settle(model) { discovery.probes == 3 }
            try await Task.sleep(for: .milliseconds(20))
            discovery.answersWithID = "1234ABCD"
            model.reconnectRememberedReader()
            try await settle(model) { model.readerStatus != nil }
            XCTAssertNotNil(model.readerStatus)
        }
    }
}
