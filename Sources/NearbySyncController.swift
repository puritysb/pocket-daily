import CoreBluetooth
import Foundation

@MainActor
final class NearbySyncController: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case bluetoothUnavailable
        case scanning
        case connecting(String)
        case connected(PocketDeviceStatus)
        case switchingToHotspot
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var hotspotLease: HotspotLease?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var statusCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var eventCharacteristic: CBCharacteristic?
    private var pendingHotspotRequestID: String?
    private var scanTimeout: Task<Void, Never>?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func scan() {
        guard central.state == .poweredOn else {
            state = .bluetoothUnavailable
            return
        }
        disconnect()
        state = .scanning
        central.scanForPeripherals(
            withServices: [NearbySyncProtocol.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(12))
            guard !Task.isCancelled, let self, self.state == .scanning else { return }
            self.central.stopScan()
            self.state = .failed("No Nearby Sync signal. Open Nearby Sync on the reader, then try again.")
        }
    }

    func disconnect() {
        central.stopScan()
        scanTimeout?.cancel()
        scanTimeout = nil
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        statusCharacteristic = nil
        commandCharacteristic = nil
        eventCharacteristic = nil
        pendingHotspotRequestID = nil
        hotspotLease = nil
        if central.state == .poweredOn { state = .idle }
    }

    func requestHotspot() throws {
        guard let peripheral, let commandCharacteristic else { throw NearbySyncError.notConnected }
        let requestID = NearbySyncProtocol.requestID()
        guard let command = NearbySyncProtocol.startHotspot(requestID: requestID) else {
            throw NearbySyncError.malformedRecord
        }
        pendingHotspotRequestID = requestID
        state = .switchingToHotspot
        peripheral.writeValue(command, for: commandCharacteristic, type: .withResponse)
    }

    private func fail(_ error: Error) {
        state = .failed(error.localizedDescription)
    }
}
extension NearbySyncController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state != .poweredOn {
                state = .bluetoothUnavailable
            } else if state == .bluetoothUnavailable {
                state = .idle
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            guard self.peripheral == nil else { return }
            central.stopScan()
            scanTimeout?.cancel()
            scanTimeout = nil
            self.peripheral = peripheral
            peripheral.delegate = self
            state = .connecting(peripheral.name ?? "Pocket")
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in peripheral.discoverServices([NearbySyncProtocol.service]) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in fail(error ?? NearbySyncError.notConnected) }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            self.peripheral = nil
            if hotspotLease == nil, let error { fail(error) }
            else if hotspotLease == nil { state = .idle }
        }
    }
}

extension NearbySyncController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error { fail(error); return }
            guard let service = peripheral.services?.first(where: { $0.uuid == NearbySyncProtocol.service }) else {
                fail(NearbySyncError.missingCharacteristic)
                return
            }
            peripheral.discoverCharacteristics(
                [NearbySyncProtocol.status, NearbySyncProtocol.command, NearbySyncProtocol.event],
                for: service
            )
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            if let error { fail(error); return }
            statusCharacteristic = service.characteristics?.first { $0.uuid == NearbySyncProtocol.status }
            commandCharacteristic = service.characteristics?.first { $0.uuid == NearbySyncProtocol.command }
            eventCharacteristic = service.characteristics?.first { $0.uuid == NearbySyncProtocol.event }
            guard let statusCharacteristic, commandCharacteristic != nil, let eventCharacteristic else {
                fail(NearbySyncError.missingCharacteristic)
                return
            }
            peripheral.setNotifyValue(true, for: eventCharacteristic)
            peripheral.readValue(for: statusCharacteristic)
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            if let error { fail(error); return }
            guard let data = characteristic.value, let record = String(data: data, encoding: .utf8) else {
                fail(NearbySyncError.malformedRecord)
                return
            }

            do {
                if characteristic.uuid == NearbySyncProtocol.status {
                    state = .connected(try PocketDeviceStatus(record: record))
                } else if characteristic.uuid == NearbySyncProtocol.event {
                    let parts = record.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    if parts.first == "AP" {
                        let lease = try HotspotLease(record: record)
                        guard lease.requestID == pendingHotspotRequestID else { return }
                        hotspotLease = lease
                    } else if parts.first == "ERR", parts.count >= 3,
                              parts[1] == pendingHotspotRequestID {
                        throw NearbySyncError.rejected(parts[2])
                    }
                }
            } catch {
                fail(error)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error { Task { @MainActor in fail(error) } }
    }
}
