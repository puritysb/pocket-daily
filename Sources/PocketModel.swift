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
    @Published var preferences: ReaderPreferences?
    @Published var preferencesDirty = false

    private let client = CrossPointClient()
    private let localDiscovery = LocalReaderDiscovery()
    private var activeHost = "192.168.4.1"
    private var activeHTTPPort = 80
    private var activeWebSocketPort = 81
    private var discoveryTask: Task<Void, Never>?

    func connectToExistingHotspot() {
        Task { await verify(host: "192.168.4.1", port: 80) }
    }

    func findOnLocalNetwork() {
        discoveryTask?.cancel()
        discoveryTask = Task {
            isWorking = true
            message = "Checking the current Wi-Fi and nearby hotspot…"
            defer { isWorking = false }

            let bonjourTask = Task { await localDiscovery.first(timeout: .seconds(5)) }
            let candidates = ["crosspoint.local", "192.168.4.1"]
            let found: (String, CrossPointStatus)? = await withTaskGroup(of: (String, CrossPointStatus)?.self) { group in
                for host in candidates {
                    group.addTask { [client] in
                        guard let status = try? await client.status(host: host, port: 80) else { return nil }
                        return (host, status)
                    }
                }
                for await result in group {
                    if let result {
                        group.cancelAll()
                        return result
                    }
                }
                return nil
            }

            guard !Task.isCancelled else { return }
            if let (host, status) = found {
                localDiscovery.stop()
                bonjourTask.cancel()
                await accept(status: status, host: host, httpPort: 80, webSocketPort: 81)
            } else if let endpoint = await bonjourTask.value,
                      let status = try? await client.status(host: endpoint.host, port: endpoint.port) {
                await accept(status: status, host: endpoint.host, httpPort: endpoint.port, webSocketPort: 81)
            } else if readerStatus == nil {
                message = "X3 was not visible. On X3 open Nearby Sync, or open Create Hotspot and join its Wi-Fi."
            }
        }
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
            let status = try await client.status(host: host, port: httpPort)
            await accept(status: status, host: host, httpPort: httpPort, webSocketPort: webSocketPort)
        } catch {
            readerStatus = nil
            preferences = nil
            message = "Reader not found. Open Create Hotspot on the reader and try again."
        }
    }

    private func accept(status: CrossPointStatus, host: String, httpPort: Int, webSocketPort: Int) async {
        readerStatus = status
        activeHost = host
        activeHTTPPort = httpPort
        activeWebSocketPort = webSocketPort
        preferences = try? await client.preferences(host: host, port: httpPort)
        preferencesDirty = false
        message = "Connected to \(status.device)."
    }

    func setStartupPocketDaily(_ enabled: Bool) {
        preferences?.startupApp = enabled ? 1 : 0
        preferencesDirty = true
    }

    func setPocketDailySleepCover(_ enabled: Bool) {
        preferences?.pocketDailySleepCover = enabled
        preferencesDirty = true
    }

    func setSleepTimeout(_ minutes: Int) {
        preferences?.sleepTimeoutMinutes = minutes
        preferencesDirty = true
    }

    func setFontSize(_ size: Int) {
        preferences?.fontSize = size
        preferencesDirty = true
    }

    func savePreferences() {
        guard let preferences else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await client.save(preferences: preferences, host: activeHost, port: activeHTTPPort)
                preferencesDirty = false
                message = "Settings were applied to X3."
            } catch {
                message = error.localizedDescription
            }
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
