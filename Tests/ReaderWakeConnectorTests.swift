import XCTest
@testable import Pocket

@MainActor
final class ReaderWakeConnectorTests: XCTestCase {
    private typealias Transport = ReaderBluetoothLinkTests.FakeTransport
    private typealias Scheduler = ReaderBluetoothLinkTests.ManualScheduler
    private let reader = RememberedBluetoothReader(peripheralID: UUID(), readerID: "89ABCDEF", model: "X3")

    private func ready(_ transport: Transport, id: String = "89ABCDEF", cap: String = "READ1,WAKE1") {
        transport.send(.connected(reader.peripheralID))
        transport.send(.ready(status: Data("V=1;MODEL=X3;ID=\(id);FW=dev;CAP=\(cap);WIN=1".utf8)))
    }

    private func started(_ transport: Transport) async {
        for _ in 0..<100 where transport.connects.isEmpty { await Task.yield() }
        XCTAssertEqual(transport.connects, [reader.peripheralID])
    }

    func testBluetoothPreflightDoesNotConnectOrWriteAndReleasesItsDeadline() async throws {
        let transport = Transport(), scheduler = Scheduler()
        transport.isAvailable = false
        let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
        let task = Task { try await connector.ensureAvailable() }
        for _ in 0..<100 where transport.activations == 0 { await Task.yield() }
        XCTAssertEqual(transport.activations, 1)
        XCTAssertTrue(transport.connects.isEmpty)
        transport.isAvailable = true
        transport.send(.availabilityChanged(true))
        try await task.value
        XCTAssertTrue(transport.connects.isEmpty)
        XCTAssertTrue(transport.writes.isEmpty)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testBluetoothPreflightTimeoutAndDenialCannotSendReaderCommands() async {
        for deny in [false, true] {
            let transport = Transport(), scheduler = Scheduler()
            transport.isAvailable = false
            let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
            let task = Task { try await connector.ensureAvailable() }
            for _ in 0..<100 where transport.activations == 0 { await Task.yield() }
            if deny { transport.send(.availabilityChanged(false)) } else { scheduler.fire(20) }
            do { try await task.value; XCTFail("Unavailable radio must fail preflight") }
            catch { XCTAssertEqual(error as? ReaderWakeConnector.Failure, deny ? .unavailable : .timedOut(.waiting)) }
            transport.isAvailable = true
            transport.send(.availabilityChanged(true))
            XCTAssertTrue(transport.connects.isEmpty)
            XCTAssertTrue(transport.writes.isEmpty)
            XCTAssertTrue(scheduler.pending.isEmpty)
        }
    }

    func testBondedRequestRequiresMatchingAcknowledgement() async throws {
        let transport = Transport(), scheduler = Scheduler()
        transport.known = [reader.peripheralID]
        let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
        let task = Task { try await connector.wake(reader) }
        await started(transport)
        ready(transport)
        let command = try XCTUnwrap(transport.writes.first.flatMap { String(data: $0, encoding: .utf8) })
        XCTAssertTrue(command.hasPrefix("START_WIFI "))
        XCTAssertEqual(transport.writes.count, 1)
        transport.send(.wrote(nil))
        transport.send(.received(Data("OK incorrect".utf8)))
        XCTAssertEqual(transport.cancels, 0, "A write acknowledgement is not command acceptance")
        let request = String(command.suffix(8))
        transport.send(.received(Data("OK \(request)".utf8)))
        try await task.value
        XCTAssertEqual(transport.cancels, 1)
        XCTAssertTrue(scheduler.pending.isEmpty)
        transport.send(.received(Data("OK \(request)".utf8)))
        XCTAssertEqual(transport.cancels, 1)
    }

    func testStalledConnectionRequestsOneBondedRecoveryWithoutReplayingWake() async throws {
        let transport = Transport(), scheduler = Scheduler()
        transport.known = [reader.peripheralID]
        let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
        let task = Task { try await connector.wake(reader) }
        await started(transport)
        XCTAssertTrue(transport.discoveries.isEmpty)
        scheduler.fire(8)
        XCTAssertEqual(transport.discoveries, [reader.peripheralID])
        XCTAssertEqual(transport.connects.count, 1)
        XCTAssertTrue(transport.writes.isEmpty)
        ready(transport)
        let command = try XCTUnwrap(transport.writes.first.flatMap { String(data: $0, encoding: .utf8) })
        transport.send(.received(Data("OK \(command.suffix(8))".utf8)))
        try await task.value
        XCTAssertEqual(transport.writes.count, 1)
        XCTAssertEqual(transport.cancels, 1)
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testDiscoveryCannotStartAfterConnectionCancellationOrTimeout() async {
        for outcome in ["connected", "cancelled", "timeout", "wrong-reader"] {
            let transport = Transport(), scheduler = Scheduler()
            transport.known = [reader.peripheralID]
            let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
            let task = Task { try await connector.wake(reader) }
            await started(transport)
            switch outcome {
            case "connected": transport.send(.connected(reader.peripheralID))
            case "cancelled":
                task.cancel()
                _ = await task.result
            case "wrong-reader": transport.send(.connected(UUID()))
            default: scheduler.fire(20)
            }
            scheduler.fire(8)
            XCTAssertTrue(transport.discoveries.isEmpty, outcome)
            XCTAssertTrue(transport.writes.isEmpty, outcome)
            scheduler.fire(20)
            _ = await task.result
            XCTAssertTrue(scheduler.pending.isEmpty, outcome)
        }
    }

    func testActiveDiscoveryEndsAtOriginalDeadlineCancellationOrBluetoothLoss() async {
        for outcome in ["timeout", "cancelled", "unavailable"] {
            let transport = Transport(), scheduler = Scheduler()
            transport.known = [reader.peripheralID]
            let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
            let task = Task { try await connector.wake(reader) }
            await started(transport)
            scheduler.fire(8)
            XCTAssertEqual(transport.discoveries, [reader.peripheralID])
            switch outcome {
            case "cancelled": task.cancel()
            case "unavailable": transport.send(.availabilityChanged(false))
            default: scheduler.fire(20)
            }
            do { try await task.value; XCTFail("Expected failure: \(outcome)") } catch { }
            XCTAssertEqual(transport.connects.count, 1)
            XCTAssertEqual(transport.cancels, 1, "Transport must cancel discovery and connection")
            XCTAssertTrue(transport.writes.isEmpty)
            XCTAssertTrue(scheduler.pending.isEmpty)
        }
    }

    func testDiscoveryDelayStartsWhenBluetoothBecomesAvailable() async throws {
        let transport = Transport(), scheduler = Scheduler()
        transport.known = [reader.peripheralID]
        transport.isAvailable = false
        let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
        var events: [ReaderWakeConnector.Observation] = []
        connector.observe = { events.append($0) }
        let task = Task { try await connector.wake(reader) }
        for _ in 0..<100 where transport.activations == 0 { await Task.yield() }
        scheduler.fire(8)
        XCTAssertTrue(transport.discoveries.isEmpty)
        transport.isAvailable = true
        transport.send(.availabilityChanged(true))
        await started(transport)
        scheduler.fire(8)
        XCTAssertEqual(transport.discoveries, [reader.peripheralID])
        XCTAssertEqual(events, [.connecting], "Requesting discovery is not evidence that the radio started scanning")
        transport.send(.discoveryStarted)
        transport.send(.knownAdvertisement)
        ready(transport)
        let command = try XCTUnwrap(transport.writes.first.flatMap { String(data: $0, encoding: .utf8) })
        transport.send(.received(Data("OK \(command.suffix(8))".utf8)))
        try await task.value
        XCTAssertEqual(events, [.connecting, .discoveryStarted, .knownAdvertisement, .connected,
                                .authenticated, .commandSent, .accepted])
        XCTAssertTrue(scheduler.pending.isEmpty)
    }

    func testRediscoveryRequiresCancellationThenFreshAdvertisementExactlyOnce() {
        var recovery = ReaderRediscovery()
        XCTAssertFalse(recovery.cancelled())
        XCTAssertFalse(recovery.found())
        XCTAssertTrue(recovery.begin())
        XCTAssertFalse(recovery.begin())
        XCTAssertFalse(recovery.found(), "A cached or raced advertisement cannot reconnect before cancellation")
        XCTAssertTrue(recovery.cancelled())
        XCTAssertFalse(recovery.cancelled())
        XCTAssertTrue(recovery.found())
        XCTAssertFalse(recovery.found(), "Duplicate advertisements cannot create another connection")
        XCTAssertEqual(recovery.phase, .reconnecting)
        recovery.reset()
        XCTAssertFalse(recovery.found())
        XCTAssertFalse(recovery.cancelled(), "Late cancellation after timeout must not restart scanning")
    }

    func testWrongReaderAndOldFirmwareNeverReceiveWakeCommand() async {
        for (identity, capabilities) in [("OTHER", "READ1,WAKE1"), ("89ABCDEF", "READ1")] {
            let transport = Transport(), scheduler = Scheduler()
            transport.known = [reader.peripheralID]
            let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
            let task = Task { try await connector.wake(reader) }
            await started(transport)
            ready(transport, id: identity, cap: capabilities)
            do { try await task.value; XCTFail("Expected refusal") } catch { }
            XCTAssertTrue(transport.writes.isEmpty)
            XCTAssertEqual(transport.cancels, 1)
        }
    }

    func testTimeoutAndCancellationDoNotReplayWake() async {
        for cancel in [false, true] {
            let transport = Transport(), scheduler = Scheduler()
            transport.known = [reader.peripheralID]
            let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
            let task = Task { try await connector.wake(reader) }
            await started(transport)
            ready(transport)
            if cancel { task.cancel() } else { scheduler.fire(20) }
            do { try await task.value; XCTFail("Expected cancellation or timeout") } catch { }
            XCTAssertEqual(transport.connects.count, 1)
            XCTAssertEqual(transport.writes.count, 1)
            XCTAssertEqual(transport.cancels, 1)
            XCTAssertTrue(scheduler.pending.isEmpty)
        }
    }

    func testWakeCommandRejectsInvalidIdentifiers() {
        XCTAssertEqual(NearbySyncProtocol.startWifi(requestID: "01ABCDEF"), Data("START_WIFI 01ABCDEF".utf8))
        for id in ["01abcDEF", "01ABCDE", "01ABCDEFG", "01ABCDEF\n"] {
            XCTAssertNil(NearbySyncProtocol.startWifi(requestID: id))
        }
    }

    func testTimeoutIdentifiesTheFailedStageWithoutSendingAnotherCommand() async {
        for phase in [ReaderWakeConnector.Phase.connecting, .preparing, .requesting] {
            let transport = Transport(), scheduler = Scheduler()
            transport.known = [reader.peripheralID]
            let connector = ReaderWakeConnector(transport: transport, scheduler: scheduler)
            let task = Task { try await connector.wake(reader) }
            await started(transport)
            if phase == .preparing { transport.send(.connected(reader.peripheralID)) }
            if phase == .requesting { ready(transport) }
            scheduler.fire(20)
            do { try await task.value; XCTFail("Expected timeout") }
            catch { XCTAssertEqual(error as? ReaderWakeConnector.Failure, .timedOut(phase)) }
            XCTAssertEqual(transport.writes.count, phase == .requesting ? 1 : 0)
            XCTAssertEqual(transport.cancels, 1)
        }
    }
}
