import Foundation

/// One immutable target revision and reader per deployment. No discovery,
/// network switching, firmware upload, or automatic activation retry.
@MainActor
final class ReaderContentTransport: ContentDeploymentTransport {
    struct Operations {
        var state: () async throws -> ContentDeviceState
        var stage: (Data, String, String) async throws -> String
        var inspect: () async throws -> ContentPreparation
        var activate: () async throws -> Void
    }

    private let target: ContentRevision
    private let deviceID: String
    private let operations: Operations
    private var directory: String { "/pocket-daily/content-staging/" + target.revision }

    init(target: ContentRevision, deviceID: String, operations: Operations) {
        self.target = target
        self.deviceID = deviceID
        self.operations = operations
    }

    convenience init(target: ContentRevision, deviceID: String, host: String, port: Int,
                     client: CrossPointClient = CrossPointClient()) {
        self.init(target: target, deviceID: deviceID, operations: .init(
            state: { try await client.contentState(deviceID: deviceID, host: host, port: port) },
            stage: { data, filename, destination in
                // Obtain current capabilities from the same identified reader.
                // Stream upload creates nested staging directories; do not guess
                // that legacy multipart upload supports that contract.
                let status = try await client.status(host: host, port: port)
                guard status.deviceID == deviceID else { throw ContentDeployment.Failure.identityMismatch }
                guard let streamPort = status.uploadStreamPort, (1...65535).contains(streamPort) else {
                    throw ContentDeployment.Failure.unsupported
                }
                let file = try await Task.detached {
                    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try data.write(to: url, options: .atomic)
                    return url
                }.value
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                return try await client.uploadAtomically(
                    fileURL: file, publishedFilename: filename, destination: destination,
                    host: host, port: port, uploadStreamPort: streamPort,
                    uploadStreamResume: status.uploadStreamResume == true,
                    uploadStreamWindow: status.uploadStreamWindow, expectedDeviceID: deviceID,
                    progress: { _, _ in })
            },
            inspect: { try await client.inspectPreparedContent(target, deviceID: deviceID, host: host, port: port) },
            activate: { try await client.activateContent(target, deviceID: deviceID, host: host, port: port) }
        ))
    }

    func readState() async throws -> ContentDeviceState {
        try Task.checkCancellation()
        let state = try await operations.state()
        guard state.deviceID == deviceID else { throw ContentDeployment.Failure.identityMismatch }
        let required = target.requiredCapabilities
        guard state.schema == 1, state.capabilities & required == required else {
            throw ContentDeployment.Failure.unsupported
        }
        return state
    }

    func prepare(revision: String, manifest: Data) async throws -> ContentPreparation {
        try requireTarget(revision)
        guard manifest == target.manifest else { throw ContentDeployment.Failure.invalidReceipt }
        _ = try await readState()
        try await stage(manifest, filename: "manifest.pdcm")
        return try await inspect()
    }

    func upload(_ asset: ContentRevision.Asset, revision: String) async throws -> ContentDestination {
        try requireTarget(revision)
        guard target.files.contains(where: {
            $0.path == asset.path && $0.kind == asset.kind && $0.data == asset.data && $0.sha256 == asset.sha256
        }) else { throw ContentDeployment.Failure.invalidReceipt }
        _ = try await readState()
        try await stage(asset.data, filename: asset.path)
        let receipt = try await inspect()
        guard receipt.verifiedFiles.contains(where: {
            $0.path == asset.path && $0.kind == asset.kind && $0.bytes == asset.data.count && $0.sha256 == asset.sha256
        }) else { throw ContentDeployment.Failure.invalidReceipt }
        return receipt.destination
    }

    func activate(revision: String) async throws {
        try requireTarget(revision)
        _ = try await readState()
        try Task.checkCancellation()
        try await operations.activate()
    }

    private func requireTarget(_ revision: String) throws {
        guard revision == target.revision else { throw ContentDeployment.Failure.invalidReceipt }
    }

    private func stage(_ data: Data, filename: String) async throws {
        try Task.checkCancellation()
        let path = try await operations.stage(data, filename, directory)
        guard path == directory + "/" + filename else { throw ContentDeployment.Failure.invalidReceipt }
        try Task.checkCancellation()
    }

    private func inspect() async throws -> ContentPreparation {
        try Task.checkCancellation()
        let receipt = try await operations.inspect()
        guard receipt.destination.deviceID == deviceID,
              receipt.destination.revision == target.revision else { throw ContentDeployment.Failure.invalidReceipt }
        return receipt
    }
}
