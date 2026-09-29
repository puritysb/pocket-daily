import CoreBluetooth
import Foundation
#if os(iOS)
import UIKit
#endif

/// CoreBluetooth for `ReaderBluetoothLink`: one central that keeps a pending
/// connection to the paired reader. On iOS it carries a restore identifier, so
/// eligible connections can resume while suspended or after system termination.
/// Background execution/restoration is OS controlled, not guaranteed delivery.
@MainActor
final class CoreBluetoothReaderTransport: NSObject, ReaderLinkTransport {
    static let restoreIdentifier = "PocketReaderReadingSync"

    var onEvent: ((ReaderLinkTransportEvent) -> Void)?
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var restored: [CBPeripheral] = []
    private var commandCharacteristic: CBCharacteristic?
    private var statusCharacteristic: CBCharacteristic?
    private var status: Data?
    private var notifying = false
    private var preparing = false

    var isAvailable: Bool { central?.state == .poweredOn }

    func activate() {
        guard central == nil else { return }
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
#if os(iOS)
        options[CBCentralManagerOptionRestoreIdentifierKey] = Self.restoreIdentifier
#endif
        central = CBCentralManager(delegate: self, queue: .main, options: options)
    }

    func connect(to identifier: UUID) -> Bool {
        guard let central, central.state == .poweredOn else { return false }
        let known = restored.first { $0.identifier == identifier }
            ?? central.retrievePeripherals(withIdentifiers: [identifier]).first
        for candidate in restored where candidate.identifier != identifier {
            central.cancelPeripheralConnection(candidate)
        }
        restored = []
        guard let known else { return false }
        reset()
        peripheral = known
        known.delegate = self
        if known.state == .connected {
            // Restored already connected: the session can start at once.
            onEvent?(.connected(identifier))
        } else {
            central.connect(known)
        }
        return true
    }

    func cancelConnection() {
        for candidate in restored { central?.cancelPeripheralConnection(candidate) }
        restored = []
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        reset()
    }

    func prepareSession() {
        guard let peripheral, peripheral.state == .connected else {
            onEvent?(.failed(NearbySyncError.notConnected))
            return
        }
        preparing = true
        peripheral.discoverServices([NearbySyncProtocol.service])
    }

    func write(_ record: Data) {
        guard let peripheral, let commandCharacteristic else {
            onEvent?(.wrote(NearbySyncError.notConnected))
            return
        }
        peripheral.writeValue(record, for: commandCharacteristic, type: .withResponse)
    }

    private func reset() {
        commandCharacteristic = nil
        statusCharacteristic = nil
        status = nil
        notifying = false
        preparing = false
    }

    private func readyIfComplete() {
        guard preparing, notifying, let status else { return }
        preparing = false
        onEvent?(.ready(status: status))
    }

    private func fail(_ error: Error) {
        preparing = false
        onEvent?(.failed(error))
    }
}

extension CoreBluetoothReaderTransport: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn: onEvent?(.availabilityChanged(true))
            case .unknown, .resetting: break
            default:
                peripheral = nil
                reset()
                onEvent?(.availabilityChanged(false))
            }
        }
    }

#if os(iOS)
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        }
    }
#endif

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard self.peripheral == peripheral else { return }
            onEvent?(.connected(peripheral.identifier))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral == peripheral else { return }
            self.peripheral = nil
            reset()
            onEvent?(.disconnected(error))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral == peripheral else { return }
            self.peripheral = nil
            reset()
            onEvent?(.disconnected(error))
        }
    }
}

extension CoreBluetoothReaderTransport: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral == peripheral, preparing else { return }
            if let error { fail(error); return }
            guard let service = peripheral.services?.first(where: { $0.uuid == NearbySyncProtocol.service }) else {
                fail(NearbySyncError.missingCharacteristic)
                return
            }
            peripheral.discoverCharacteristics(
                [NearbySyncProtocol.status, NearbySyncProtocol.command, NearbySyncProtocol.event], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral == peripheral, preparing else { return }
            if let error { fail(error); return }
            let characteristics = service.characteristics ?? []
            statusCharacteristic = characteristics.first { $0.uuid == NearbySyncProtocol.status }
            commandCharacteristic = characteristics.first { $0.uuid == NearbySyncProtocol.command }
            guard let statusCharacteristic, commandCharacteristic != nil,
                  let event = characteristics.first(where: { $0.uuid == NearbySyncProtocol.event }) else {
                fail(NearbySyncError.missingCharacteristic)
                return
            }
            peripheral.setNotifyValue(true, for: event)
            peripheral.readValue(for: statusCharacteristic)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral == peripheral, characteristic.uuid == NearbySyncProtocol.event else { return }
            if let error { fail(error); return }
            notifying = characteristic.isNotifying
            readyIfComplete()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral == peripheral else { return }
            if let error {
                if preparing { fail(error) }
                return
            }
            guard let value = characteristic.value else { return }
            if characteristic.uuid == NearbySyncProtocol.status {
                status = value
                readyIfComplete()
            } else if characteristic.uuid == NearbySyncProtocol.event {
                onEvent?(.received(value))
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard self.peripheral == peripheral, characteristic.uuid == NearbySyncProtocol.command else { return }
            onEvent?(.wrote(error))
        }
    }
}

/// Extra background time on iOS for a timer that must run after a background
/// exchange; nothing on macOS, where the app keeps running.
struct BackgroundActivity {
#if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
#endif

    /// False when the app is in the background and the system grants no time.
    @MainActor
    mutating func begin(expired: @escaping @MainActor () -> Void) -> Bool {
#if os(iOS)
        guard identifier == .invalid else { return true }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Reader reading sync") {
            MainActor.assumeIsolated { expired() }
        }
        return identifier != .invalid || UIApplication.shared.applicationState != .background
#else
        return true
#endif
    }

    @MainActor
    mutating func end() {
#if os(iOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
#endif
    }
}
