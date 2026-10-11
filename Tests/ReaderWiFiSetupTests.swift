import XCTest
@testable import Pocket

@MainActor
final class ReaderWiFiSetupTests: XCTestCase {
    func testCurrentWiFiLookupIsExplicitAndPreservesSSIDExactly() async {
        var calls = 0
        let lookup = CurrentWiFiName(fetch: { calls += 1; return " 카페 WiFi " })
        XCTAssertEqual(calls, 0, "Opening the form must not read Wi-Fi or request permission")
        let value = await lookup.read()
        XCTAssertEqual(value, " 카페 WiFi ")
        XCTAssertEqual(calls, 1)
        XCTAssertFalse(lookup.isLoading)
        XCTAssertNil(lookup.message)
    }

    func testUnavailableOrInvalidWiFiNameOffersManualFallback() async {
        for value: String? in [nil, "", "bad\nSSID", String(repeating: "가", count: 11)] {
            let lookup = CurrentWiFiName(fetch: { value })
            let result = await lookup.read()
            XCTAssertNil(result)
            XCTAssertNotNil(lookup.message)
            XCTAssertFalse(lookup.isLoading)
        }
    }

    func testWiFiPermissionFailuresDoNotExposeSystemDetails() async {
        for error in [CurrentWiFiName.Failure.permission, .preciseLocation] {
            let lookup = CurrentWiFiName(fetch: { throw error })
            let result = await lookup.read()
            XCTAssertNil(result)
            XCTAssertTrue(lookup.message?.contains("enter it yourself") == true)
        }
        let lookup = CurrentWiFiName(fetch: { throw NSError(domain: "private-network-name", code: 1) })
        _ = await lookup.read()
        XCTAssertFalse(lookup.message?.contains("private-network-name") == true)
    }

    func testCancelledWiFiLookupCannotFillDismissedForm() async {
        let lookup = CurrentWiFiName(fetch: {
            // Even a non-cooperative system callback must not publish late data.
            try? await Task.sleep(for: .seconds(30))
            return "Late network"
        })
        let task = Task { await lookup.read() }
        while !lookup.isLoading { await Task.yield() }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertNil(lookup.message)
        XCTAssertFalse(lookup.isLoading)
    }

    func testCredentialEncodingHasMatchingFirmwareBytes() {
        let input = ReaderWiFiCredentials(ssid: "Home WiFi", password: "abcd1234")
        XCTAssertEqual(input.command(requestID: "01ABCDEF"), Data("WIFI_JOIN 01ABCDEF 486F6D652057694669 6162636431323334".utf8))
        let open = ReaderWiFiCredentials(ssid: "가 나", password: "")
        XCTAssertEqual(open.command(requestID: "01ABCDEF"), Data("WIFI_JOIN 01ABCDEF EAB08020EB8298 -".utf8))
        XCTAssertNotNil(ReaderWiFiCredentials(ssid: String(repeating: "s", count: 32), password: String(repeating: "F", count: 64)).command(requestID: "01ABCDEF"))
        XCTAssertEqual(ReaderWiFiCredentials(ssid: " x ", password: " password ").ssid, " x ")
    }

    func testInvalidInputCannotProduceCommand() {
        for ssid in ["", String(repeating: "a", count: 33), String(repeating: "가", count: 11), "x\n", "x\0", "x\u{7f}"] {
            XCTAssertNil(ReaderWiFiCredentials(ssid: ssid, password: "password").command(requestID: "01ABCDEF"))
        }
        for password in ["short", "abcde\nfg", "password가", String(repeating: "g", count: 64), String(repeating: "F", count: 65)] {
            XCTAssertNil(ReaderWiFiCredentials(ssid: "Home", password: password).command(requestID: "01ABCDEF"))
        }
        XCTAssertNil(ReaderWiFiCredentials(ssid: "Home", password: "password").command(requestID: "01abcDEF"))
    }

    func testAcceptanceAndUnrelatedReceiptsAreNeverReportedAsSaved() {
        for state in ["pending", "none", "unknown"] {
            XCTAssertNil(ReaderWiFiSetupReceipt(requestID: "01ABCDEF", state: state).message(for: "01ABCDEF"))
        }
        XCTAssertNil(ReaderWiFiSetupReceipt(requestID: "DEADBEEF", state: "saved").message(for: "01ABCDEF"))
        XCTAssertTrue(ReaderWiFiSetupReceipt(requestID: "01ABCDEF", state: "failed").message(for: "01ABCDEF")!.contains("previous"))
        XCTAssertTrue(ReaderWiFiSetupReceipt(requestID: "01ABCDEF", state: "save_failed").message(for: "01ABCDEF")!.contains("could not save"))
    }

    func testProvisioningChecksIdentityAndCapabilityBeforeSendingSecrets() async throws {
        typealias Fake = ReaderBluetoothLinkTests.FakeTransport
        let reader = RememberedBluetoothReader(peripheralID: UUID(), readerID: "89ABCDEF", model: "X3")
        for (identity, cap, succeeds) in [("89ABCDEF", "WIFI1", true), ("OTHER", "WIFI1", false), ("89ABCDEF", "WAKE1", false)] {
            let transport = Fake(), scheduler = ReaderBluetoothLinkTests.ManualScheduler()
            transport.known = [reader.peripheralID]
            let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
            let task = Task { try await connector.configureWiFi(reader, credentials: ReaderWiFiCredentials(ssid: "Home", password: "password")) }
            for _ in 0..<100 where transport.connects.isEmpty { await Task.yield() }
            transport.send(.connected(reader.peripheralID))
            transport.send(.ready(status: Data("V=1;MODEL=X3;ID=\(identity);FW=dev;CAP=\(cap);WIN=0".utf8)))
            if succeeds {
                let data = try XCTUnwrap(transport.writes.first)
                let command = try XCTUnwrap(String(data: data, encoding: .utf8))
                let id = String(command.split(separator: " ")[1])
                XCTAssertTrue(command.hasPrefix("WIFI_JOIN "))
                transport.send(.received(Data("OK BAD00000".utf8)))
                XCTAssertEqual(transport.cancels, 0)
                transport.send(.received(Data("OK \(id)".utf8)))
                let returnedID = try await task.value
                XCTAssertEqual(returnedID, id)
                XCTAssertEqual(transport.writes.count, 1)
            } else {
                do { _ = try await task.value; XCTFail("Must reject") } catch { }
                XCTAssertTrue(transport.writes.isEmpty)
            }
            XCTAssertEqual(transport.cancels, 1)
        }
    }

    func testLostAcknowledgementIsObservableWithoutReplayingSecrets() async throws {
        let reader = RememberedBluetoothReader(peripheralID: UUID(), readerID: "89ABCDEF", model: "X3")
        let transport = ReaderBluetoothLinkTests.FakeTransport()
        let scheduler = ReaderBluetoothLinkTests.ManualScheduler()
        transport.known = [reader.peripheralID]
        let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
        let task = Task { try await connector.configureWiFi(reader, credentials: ReaderWiFiCredentials(ssid: "Home", password: "password")) }
        for _ in 0..<100 where transport.connects.isEmpty { await Task.yield() }
        transport.send(.connected(reader.peripheralID))
        transport.send(.ready(status: Data("V=1;MODEL=X3;ID=89ABCDEF;FW=dev;CAP=WIFI1;WIN=0".utf8)))
        let data = try XCTUnwrap(transport.writes.first)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let id = String(text.split(separator: " ")[1])
        scheduler.fire(20)
        do { _ = try await task.value; XCTFail("Lost acknowledgement is not success") }
        catch { XCTAssertEqual(error as? ReaderWakeConnector.Failure, .wifiOutcomeUnknown(id)) }
        XCTAssertEqual(transport.writes.count, 1)
        XCTAssertEqual(transport.cancels, 1)
    }

    func testDemoCannotStartCredentialTransport() async {
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO())
        model.enterDemoMode()
        var writes = 0
        model.sendReaderWiFi = { _, _ in writes += 1; return "01ABCDEF" }
        model.configureReaderWiFi(ReaderWiFiCredentials(ssid: "Home", password: "password"))
        await Task.yield()
        XCTAssertEqual(writes, 0)
        XCTAssertFalse(model.isConfiguringReaderWiFi)
        XCTAssertFalse(model.canConfigureReaderWiFi)
    }
}
