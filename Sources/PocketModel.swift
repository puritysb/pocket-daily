import Foundation

@MainActor
final class PocketModel: ObservableObject {
    enum StorageError: LocalizedError {
        case invalidSDRoot
        case destinationExists(String)
        case invalidFont

        var errorDescription: String? {
            switch self {
            case .invalidSDRoot: "Select the mounted SD card's top-level folder."
            case let .destinationExists(name): "\(name) already exists on the SD card. Remove it first or rename the new file."
            case .invalidFont: "The selected file is not a valid .cpfont package."
            }
        }
    }

    @Published var readerStatus: CrossPointStatus?
    @Published var message = "Wake your reader and open File Transfer or Nearby Sync."
    @Published var isWorking = false
    @Published var uploadProgress: Double = 0

    private let client = CrossPointClient()
    private var activeHost = "192.168.4.1"
    private var activeWebSocketPort = 81

    func connectToExistingHotspot() {
        Task { await verify(host: "192.168.4.1", port: 80) }
    }

    func useNearbyLease(_ lease: HotspotLease) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await HotspotJoiner.join(lease)
                try await Task.sleep(for: .milliseconds(800))
                await verify(host: lease.host, httpPort: lease.httpPort, webSocketPort: lease.webSocketPort)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func verify(host: String, port: Int) async {
        await verify(host: host, httpPort: port, webSocketPort: 81)
    }

    func verify(host: String, httpPort: Int, webSocketPort: Int) async {
        isWorking = true
        defer { isWorking = false }
        do {
            readerStatus = try await client.status(host: host, port: httpPort)
            activeHost = host
            activeWebSocketPort = webSocketPort
            message = "Connected to \(readerStatus?.device ?? "Pocket")."
        } catch {
            readerStatus = nil
            message = "Reader not found. Open Create Hotspot on the reader and try again."
        }
    }

    func upload(_ url: URL) {
        Task {
            isWorking = true
            uploadProgress = 0
            defer { isWorking = false }
            do {
                try await client.upload(
                    fileURL: url,
                    destination: destination(for: url),
                    host: activeHost,
                    port: activeWebSocketPort
                ) { [weak self] sent, total in
                    Task { @MainActor in self?.uploadProgress = total > 0 ? Double(sent) / Double(total) : 0 }
                }
                uploadProgress = 1
                message = "\(url.lastPathComponent) was sent to Pocket."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func copyToSD(_ source: URL, root: URL) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                let destination = try await Task.detached(priority: .userInitiated) {
                    try Self.copyToSDOffMain(source: source, root: root)
                }.value
                message = "Copied to SD card: \(destination)"
            } catch {
                message = error.localizedDescription
            }
        }
    }

    private func destination(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdl": "/pocket-daily/learning"
        default: "/"
        }
    }

    nonisolated static func copyToSDOffMain(source: URL, root: URL) throws -> String {
        let sourceScoped = source.startAccessingSecurityScopedResource()
        let rootScoped = root.startAccessingSecurityScopedResource()
        defer {
            if sourceScoped { source.stopAccessingSecurityScopedResource() }
            if rootScoped { root.stopAccessingSecurityScopedResource() }
        }

        let values = try root.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { throw StorageError.invalidSDRoot }

        let manager = FileManager.default
        let relativeDirectory: String
        switch source.pathExtension.lowercased() {
        case "pdl":
            relativeDirectory = "pocket-daily/learning"
        case "cpfont":
            try validateFont(source)
            relativeDirectory = ".fonts/\(fontFamily(from: source.deletingPathExtension().lastPathComponent))"
        default:
            relativeDirectory = ""
        }

        let directory = relativeDirectory.isEmpty ? root : root.appendingPathComponent(relativeDirectory, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        guard !manager.fileExists(atPath: destination.path) else {
            throw StorageError.destinationExists(source.lastPathComponent)
        }

        let staging = directory.appendingPathComponent(".\(source.lastPathComponent).pocket-staging-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        try manager.moveItem(at: staging, to: destination)
        return destination.path.replacingOccurrences(of: root.path, with: "", options: [.anchored])
    }

    nonisolated private static func validateFont(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let expected = Data([0x43, 0x50, 0x46, 0x4F, 0x4E, 0x54, 0x00, 0x00])
        guard try handle.read(upToCount: expected.count) == expected else { throw StorageError.invalidFont }
    }

    nonisolated private static func fontFamily(from stem: String) -> String {
        let cut = [stem.lastIndex(of: "_"), stem.lastIndex(of: "-")].compactMap { $0 }.max()
        let raw = cut.map { String(stem[..<$0]) } ?? stem
        let sanitized = raw.map { character -> Character in
            character.isASCII && (character.isLetter || character.isNumber || character == "_" || character == "-")
                ? character : "_"
        }
        return sanitized.isEmpty ? "PocketFont" : String(sanitized)
    }
}
