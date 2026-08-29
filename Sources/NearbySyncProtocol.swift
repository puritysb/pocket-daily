import CoreBluetooth
import Foundation

enum NearbySyncProtocol {
    static let version = 1
    static let service = CBUUID(string: "7B8D5001-8E5B-4A7E-9D9A-7E42D2C50001")
    static let status = CBUUID(string: "7B8D5002-8E5B-4A7E-9D9A-7E42D2C50001")
    static let command = CBUUID(string: "7B8D5003-8E5B-4A7E-9D9A-7E42D2C50001")
    static let event = CBUUID(string: "7B8D5004-8E5B-4A7E-9D9A-7E42D2C50001")
    static let maximumRecordBytes = 220

    static func requestID() -> String {
        String(format: "%08X", UInt32.random(in: UInt32.min ... UInt32.max))
    }

    static func startHotspot(requestID: String) -> Data? {
        encode("START_AP \(requestID)")
    }

    static func ping(requestID: String) -> Data? {
        encode("PING \(requestID)")
    }

    private static func encode(_ value: String) -> Data? {
        guard let data = value.data(using: .utf8), data.count <= maximumRecordBytes else { return nil }
        return data
    }
}
struct PocketDeviceStatus: Equatable {
    let protocolVersion: Int
    let model: String
    let deviceID: String
    let firmware: String?
    let capabilities: Set<String>

    init(record: String) throws {
        let fields = try RecordParser.fields(record)
        guard let versionText = fields["V"], let version = Int(versionText),
              let model = fields["MODEL"], !model.isEmpty,
              let deviceID = fields["ID"], !deviceID.isEmpty,
              let capabilities = fields["CAP"]
        else { throw NearbySyncError.malformedRecord }

        protocolVersion = version
        self.model = model
        self.deviceID = deviceID
        firmware = fields["FW"]
        self.capabilities = Set(capabilities.split(separator: ",").map(String.init))
    }
}

struct HotspotLease: Equatable {
    let requestID: String
    let ssid: String
    let passphrase: String
    let host: String
    let httpPort: Int
    let webSocketPort: Int
    let leaseSeconds: Int

    init(record: String) throws {
        let parts = record.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 8, parts[0] == "AP",
              let httpPort = Int(parts[5]), let webSocketPort = Int(parts[6]),
              let leaseSeconds = Int(parts[7]),
              !parts[1].isEmpty, !parts[2].isEmpty, parts[3].count >= 8, !parts[4].isEmpty
        else { throw NearbySyncError.malformedRecord }

        requestID = parts[1]
        ssid = parts[2]
        passphrase = parts[3]
        host = parts[4]
        self.httpPort = httpPort
        self.webSocketPort = webSocketPort
        self.leaseSeconds = leaseSeconds
    }
}

enum RecordParser {
    static func fields(_ record: String) throws -> [String: String] {
        guard record.utf8.count <= NearbySyncProtocol.maximumRecordBytes,
              !record.contains("\n"), !record.contains("\r")
        else { throw NearbySyncError.malformedRecord }

        var result: [String: String] = [:]
        for item in record.split(separator: ";") {
            let pair = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2, !pair[0].isEmpty, result[pair[0]] == nil else {
                throw NearbySyncError.malformedRecord
            }
            result[pair[0]] = pair[1]
        }
        return result
    }
}

enum NearbySyncError: LocalizedError, Equatable {
    case bluetoothUnavailable
    case malformedRecord
    case missingCharacteristic
    case notConnected
    case rejected(String)

    var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable: "Bluetooth is unavailable."
        case .malformedRecord: "The reader sent an invalid Nearby Sync record."
        case .missingCharacteristic: "This reader does not provide the required Nearby Sync service."
        case .notConnected: "No Pocket reader is connected."
        case let .rejected(code): "The reader rejected the request (\(code))."
        }
    }
}
