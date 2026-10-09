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
}
