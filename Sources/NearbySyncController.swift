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
    @Published private(set) var traceEntries: [String] = []

    /// Created on the first Find & Connect, not at launch: instantiating a
    /// central manager is what triggers the system Bluetooth permission prompt.
    private var central: CBCentralManager?
    private var scanRequested = false
    private var peripheral: CBPeripheral?
    private var statusCharacteristic: CBCharacteristic?
    private var commandCharacteristic: CBCharacteristic?
    private var eventCharacteristic: CBCharacteristic?
    private var pendingStatus: PocketDeviceStatus?
    private var eventNotificationsReady = false
    private var pendingHotspotRequestID: String?
    private var scanTimeout: Task<Void, Never>?

    override init() {
        super.init()
        traceEntries = Self.loadTrace()
        record("Pocket BLE controller initialized")
    }

    var traceReport: String { traceEntries.joined(separator: "\n") }

    var traceAnalysis: String {
        let lower = traceReport.lowercased()
        if lower.contains("connect failed") && lower.contains("timed out") {
            return "The reader was discovered, but the BLE link timed out before GATT setup completed."
        }
        if lower.contains("authentication rejected") {
            return "BLE reached pairing but authentication was rejected. Remove a stale bond and retry."
        }
        if lower.contains("device discovered") && !lower.contains("gatt service discovered") {
            return "The reader was visible, but service discovery did not complete."
        }
        if lower.contains("status received") {
            return "BLE discovery and the encrypted status exchange completed."
        }
        return "The local trace is retained even if the reader reboots before HTTP diagnostics are available."
    }

    func scan() {
        guard let central else {
            // First use: ask for Bluetooth now and start scanning once the
            // system reports the radio state.
            scanRequested = true
            state = .scanning
            record("Requesting Bluetooth access")
            self.central = CBCentralManager(delegate: self, queue: .main)
            return
        }
        switch central.state {
        case .poweredOn:
            beginScan(central)
        case .unauthorized:
            state = .failed(Self.unauthorizedMessage)
        default:
            state = .bluetoothUnavailable
        }
    }

    static let unauthorizedMessage = "Bluetooth access is off for Pocket Daily. Allow it in Settings, or connect over Wi-Fi with File Transfer → Join a Network."

    private func beginScan(_ central: CBCentralManager) {
        disconnect()
        record("BLE scan started")
        state = .scanning
        central.scanForPeripherals(
            withServices: [NearbySyncProtocol.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        scanTimeout?.cancel()
        scanTimeout = Task { [weak self] in
            // A Pocket Daily Sync press performs a clean-heap reader restart
            // before BLE advertising. Prefer the low-noise service-filtered
            // scan, but fall back to the authenticated Pocket name when macOS
            // omits a 128-bit service UUID from its filtered scan cache.
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, self.state == .scanning else { return }
            central.stopScan()
            self.record("Filtered BLE scan found no service; trying Pocket name fallback")
            central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
            )

            try? await Task.sleep(for: .seconds(22))
            guard !Task.isCancelled, self.state == .scanning else { return }
            central.stopScan()
            self.record("BLE scan timed out after service and Pocket name searches")
            self.state = .failed("No Pocket Sync signal. Open Pocket Daily on the reader, press Sync, then try again.")
        }
    }

    nonisolated static func isPocketAdvertisement(name: String?, serviceUUIDs: [CBUUID]) -> Bool {
        serviceUUIDs.contains(NearbySyncProtocol.service) || name?.hasPrefix("Pocket-") == true
    }

    func disconnect() {
        scanRequested = false
        central?.stopScan()
        scanTimeout?.cancel()
        scanTimeout = nil
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        statusCharacteristic = nil
        commandCharacteristic = nil
        eventCharacteristic = nil
        pendingStatus = nil
        eventNotificationsReady = false
        pendingHotspotRequestID = nil
        hotspotLease = nil
        if central?.state == .poweredOn { state = .idle }
    }

    func requestHotspot() throws {
        guard let peripheral, let commandCharacteristic else { throw NearbySyncError.notConnected }
        let requestID = NearbySyncProtocol.requestID()
        guard let command = NearbySyncProtocol.startHotspot(requestID: requestID) else {
            throw NearbySyncError.malformedRecord
        }
        pendingHotspotRequestID = requestID
        record("Authenticated hotspot handoff requested")
        state = .switchingToHotspot
        peripheral.writeValue(command, for: commandCharacteristic, type: .withResponse)
    }

    private func fail(_ error: Error) {
        record("BLE operation failed: \(error.localizedDescription)")
        state = .failed(error.localizedDescription)
    }

    private func record(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        traceEntries.append("\(timestamp) \(message)")
        if traceEntries.count > 80 { traceEntries.removeFirst(traceEntries.count - 80) }
        let report = traceReport
        let url = Self.traceURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? report.write(to: url, atomically: true, encoding: .utf8)
    }

    private static var traceURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Pocket", isDirectory: true).appendingPathComponent("nearby-sync.log")
    }

    private static func loadTrace() -> [String] {
        guard let report = try? String(contentsOf: traceURL, encoding: .utf8) else { return [] }
        return Array(report.components(separatedBy: .newlines).filter { !$0.isEmpty }.suffix(80))
    }

    private func publishConnectedIfReady() {
        guard eventNotificationsReady, let pendingStatus else { return }
        state = .connected(pendingStatus)
    }
}
extension NearbySyncController: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if scanRequested {
                    scanRequested = false
                    beginScan(central)
                } else if state == .bluetoothUnavailable {
                    state = .idle
                }
            case .unauthorized:
                scanRequested = false
                record("Bluetooth access denied")
                state = .failed(Self.unauthorizedMessage)
            case .unknown, .resetting:
                break
            default:
                scanRequested = false
                state = .bluetoothUnavailable
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
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let serviceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let name = advertisedName ?? peripheral.name
            guard Self.isPocketAdvertisement(name: name, serviceUUIDs: serviceUUIDs) else { return }
            record("Pocket device discovered: \(name ?? "unnamed") RSSI=\(RSSI)")
            central.stopScan()
            scanTimeout?.cancel()
            scanTimeout = nil
            self.peripheral = peripheral
            peripheral.delegate = self
            state = .connecting(name ?? "Pocket")
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            guard self.peripheral == peripheral else { return }
            record("BLE link connected; discovering GATT service")
            peripheral.discoverServices([NearbySyncProtocol.service])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.peripheral == peripheral else { return }
            let reason = error ?? NearbySyncError.notConnected
            record("BLE connect failed: \(reason.localizedDescription)")
            fail(reason)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.peripheral == peripheral else { return }
            self.peripheral = nil
            record("BLE link disconnected\(error.map { ": \($0.localizedDescription)" } ?? "")")
            if hotspotLease == nil, let error { fail(error) }
            else if hotspotLease == nil { state = .idle }
        }
    }
}

extension NearbySyncController: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard self.peripheral == peripheral else { return }
            if let error { fail(error); return }
            guard let service = peripheral.services?.first(where: { $0.uuid == NearbySyncProtocol.service }) else {
                fail(NearbySyncError.missingCharacteristic)
                return
            }
            record("Pocket GATT service discovered")
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
            guard self.peripheral == peripheral else { return }
            if let error { fail(error); return }
            statusCharacteristic = service.characteristics?.first { $0.uuid == NearbySyncProtocol.status }
            commandCharacteristic = service.characteristics?.first { $0.uuid == NearbySyncProtocol.command }
            eventCharacteristic = service.characteristics?.first { $0.uuid == NearbySyncProtocol.event }
            guard let statusCharacteristic, commandCharacteristic != nil, let eventCharacteristic else {
                fail(NearbySyncError.missingCharacteristic)
                return
            }
            record("Pocket GATT characteristics discovered")
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
            guard self.peripheral == peripheral else { return }
            if let error { fail(error); return }
            guard let data = characteristic.value, let record = String(data: data, encoding: .utf8) else {
                fail(NearbySyncError.malformedRecord)
                return
            }

            do {
                if characteristic.uuid == NearbySyncProtocol.status {
                    pendingStatus = try PocketDeviceStatus(record: record)
                    self.record("Encrypted Pocket status received")
                    publishConnectedIfReady()
                } else if characteristic.uuid == NearbySyncProtocol.event {
                    let parts = record.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                    if parts.first == "AP" {
                        let lease = try HotspotLease(record: record)
                        guard lease.requestID == pendingHotspotRequestID else { return }
                        hotspotLease = lease
                        self.record("Authenticated hotspot lease received")
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
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard self.peripheral == peripheral else { return }
            if let error { fail(error); return }
            guard characteristic.uuid == NearbySyncProtocol.event else { return }
            eventNotificationsReady = characteristic.isNotifying
            record(characteristic.isNotifying ? "Encrypted event notifications active"
                                               : "Event notifications inactive")
            publishConnectedIfReady()
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
