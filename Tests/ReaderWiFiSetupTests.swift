import CoreBluetooth
import XCTest
@testable import Pocket

@MainActor
final class ReaderWiFiSetupTests: XCTestCase {
    func testConfirmationWaitsForRollbackBeyondThreeFastSearches() async throws {
        var time: TimeInterval = 0
        var polls = 0
        let message = try await ReaderWiFiConfirmation.observe(now: { time }, pause: { time += 5 }) {
            polls += 1
            return time >= 45 ? "Verified old-network rollback" : nil
        }
        XCTAssertEqual(message, "Verified old-network rollback")
        XCTAssertEqual(polls, 9)
        XCTAssertEqual(time, 45)
    }

    func testUnconfirmedWiFiResultStopsAtDeadline() async throws {
        var time: TimeInterval = 0
        var polls = 0
        let message = try await ReaderWiFiConfirmation.observe(now: { time }, pause: { time += 5 }) {
            polls += 1
            return nil
        }
        XCTAssertNil(message)
        XCTAssertEqual(time, 90)
        XCTAssertEqual(polls, 18)
    }

    func testCancelledWiFiObservationDoesNotPollAgain() async {
        var polls = 0
        do {
            _ = try await ReaderWiFiConfirmation.observe(pause: { throw CancellationError() }) {
                polls += 1
                return nil
            }
            XCTFail("Cancellation must propagate")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(polls, 0)
    }

    func testUnavailableMacBluetoothKeepsTheOnlineReaderOnWiFi() async throws {
        let domain = "Pocket.wifi-preflight." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer { defaults.removePersistentDomain(forName: domain); try? FileManager.default.removeItem(at: root) }
        let store = RememberedBluetoothReaderStore(defaults: defaults)
        store.reader = RememberedBluetoothReader(peripheralID: UUID(), readerID: "89ABCDEF", model: "X3")
        let link = ReaderBluetoothLink(transport: ReaderBluetoothLinkTests.FakeTransport(), store: store,
            sync: ReadingSync(defaults: defaults, iCloudAvailable: { false }), books: { [] },
            scheduler: ReaderBluetoothLinkTests.ManualScheduler())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RejectOnboardingNetwork.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let model = PocketModel(discoveryIO: EmptyReaderDiscoveryIO(), client: CrossPointClient(session: session),
            sessionStorage: ReaderSessionStorage(root: root, defaults: defaults), bluetoothLink: link)
        defer { model.pauseForBackground() }
        for _ in 0..<100 where model.bookTransferJobsLoading { try await Task.sleep(for: .milliseconds(10)) }
        model.readerStatus = try JSONDecoder().decode(CrossPointStatus.self, from: Data(
            #"{"deviceID":"89ABCDEF","version":"dev","device":"X3","ip":"192.0.2.1","mode":"STA","rssi":-50,"freeHeap":70000,"uptime":1,"wifiSetup":1}"#.utf8))
        var checked = 0, sent = 0
        model.prepareReaderBluetooth = { checked += 1; throw ReaderWakeConnector.Failure.timedOut(.waiting) }
        model.sendReaderWiFi = { _, _ in sent += 1; return "01ABCDEF" }
        model.configureReaderWiFi(ReaderWiFiCredentials(ssid: "Test only", password: "test-password"))
        XCTAssertTrue(model.isConfiguringReaderWiFi)
        for _ in 0..<100 where model.isWorking || model.isConfiguringReaderWiFi { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(checked, 1)
        XCTAssertEqual(sent, 0)
        XCTAssertEqual(model.readerStatus?.deviceID, "89ABCDEF")
        XCTAssertFalse(model.isConfiguringReaderWiFi)
        XCTAssertTrue(model.readerWiFiSetupMessage.contains("Bluetooth did not become ready"))
        XCTAssertTrue(model.readerWiFiSetupMessage.contains("No Wi-Fi details were sent"))
    }

    func testRetryEditingClearsOldOutcomeAndRequiresNewPassword() throws {
        var form = ReaderWiFiSetupForm()
        form.ssid = "Example"
        form.password = "test-password"
        let sent = try XCTUnwrap(form.submit())
        XCTAssertEqual(sent.password, "test-password")
        XCTAssertEqual(form.password, "")
        XCTAssertTrue(form.submitted, "Clearing a sent secret must keep its result visible")
        XCTAssertNil(form.submit(), "Never replay credentials cleared after an attempt")
        form.ssid = "Corrected network"
        XCTAssertFalse(form.submitted, "An old failure/success must not label edited credentials")
        XCTAssertNotNil(form.validation, "Retry needs a new password after failure")
        form.password = "correct-password"
        XCTAssertNil(form.validation)
        XCTAssertEqual(form.submit()?.ssid, "Corrected network")
        form.password = "another-password"
        XCTAssertFalse(form.submitted)
        form.openNetwork = true
        XCTAssertEqual(form.password, "")
        XCTAssertEqual(form.submit()?.password, "")
        form.openNetwork = false
        XCTAssertFalse(form.submitted)
        XCTAssertNotNil(form.validation)
    }

    func testDeniedAutofillStillAllowsExplicitManualSubmission() async throws {
        let lookup = CurrentWiFiName(fetch: { throw CurrentWiFiName.Failure.permission })
        let name = await lookup.read()
        XCTAssertNil(name)
        var form = ReaderWiFiSetupForm()
        form.ssid = "Manually entered"
        XCTAssertNil(form.submit(), "Missing keychain password is not an open network")
        form.password = "manual-password"
        XCTAssertEqual(form.submit()?.ssid, "Manually entered")
        XCTAssertEqual(form.password, "")
    }

    func testPairingEncryptionFailuresExplainRecoveryWithoutHidingOtherFailures() {
        for code in [CBATTError.Code.insufficientEncryption, .insufficientAuthentication] {
            let message = NearbySyncController.failureMessage(for: CBATTError(code))
            XCTAssertTrue(message.contains("Pair Reader"))
            XCTAssertTrue(message.contains("system prompt"))
            XCTAssertTrue(message.contains("old pairing"))
        }
        let other = CBATTError(.invalidHandle)
        XCTAssertEqual(NearbySyncController.failureMessage(for: other), other.localizedDescription)
        XCTAssertEqual(NearbySyncController.failureMessage(for: CBError(.peerRemovedPairingInformation)),
                       NearbySyncController.staleBondMessage)
    }

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

private final class RejectOnboardingNetwork: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Bluetooth preflight failure must not send an HTTP request to the reader")
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }
    override func stopLoading() {}
}
