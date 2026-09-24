import Foundation

struct ContentStateReceipt: Decodable {
    let schema: UInt16
    let deviceID: String
    let capabilities: UInt16
    let active: ContentActiveReceipt?
    private enum CodingKeys: String, CodingKey { case schema, deviceID, capabilities, active }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schema = try values.decode(UInt16.self, forKey: .schema)
        deviceID = try values.decode(String.self, forKey: .deviceID)
        capabilities = try values.decode(UInt16.self, forKey: .capabilities)
        guard values.contains(.active) else {
            throw DecodingError.keyNotFound(CodingKeys.active, .init(codingPath: decoder.codingPath,
                                                                    debugDescription: "Missing verified active state"))
        }
        active = try values.decodeIfPresent(ContentActiveReceipt.self, forKey: .active)
    }

    static func decode(_ data: Data, deviceID: String) throws -> ContentDeviceState {
        let receipt = try JSONDecoder().decode(Self.self, from: data)
        guard receipt.schema == 1, receipt.deviceID == deviceID, receipt.capabilities & 1 != 0 else {
            throw ContentDeployment.Failure.invalidReceipt
        }
        if let active = receipt.active {
            guard active.generation > 0, active.revision.utf8.count == 64,
                  active.revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw ContentDeployment.Failure.invalidReceipt
            }
        }
        return .init(deviceID: receipt.deviceID, schema: receipt.schema,
                     capabilities: receipt.capabilities, active: receipt.active)
    }
}
