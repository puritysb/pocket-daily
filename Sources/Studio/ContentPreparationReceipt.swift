import Foundation

/// `/api/pocket/v1/content/prepare`: bits refer to canonical manifest order.
/// A complete mask proves asset bytes, not semantic validation or activation.
struct ContentPreparationReceipt: Decodable {
    let schema: UInt16
    let deviceID: String
    let revision: String
    let fileCount: UInt16
    let verifiedMask: UInt16

    static func decode(_ data: Data, target: ContentRevision, deviceID: String) throws -> ContentPreparation {
        let receipt = try JSONDecoder().decode(Self.self, from: data)
        guard receipt.schema == 1, receipt.deviceID == deviceID,
              receipt.revision == target.revision, receipt.fileCount == target.files.count,
              UInt32(receipt.verifiedMask) >> target.files.count == 0 else {
            throw ContentDeployment.Failure.invalidReceipt
        }
        let verified = target.files.enumerated().compactMap { index, asset -> ContentManifest.File? in
            guard receipt.verifiedMask & (UInt16(1) << index) != 0 else { return nil }
            return .init(path: asset.path, kind: asset.kind, bytes: UInt32(asset.data.count), sha256: asset.sha256)
        }
        return ContentPreparation(destination: .init(deviceID: receipt.deviceID, revision: receipt.revision),
                                  verifiedFiles: verified)
    }
}
