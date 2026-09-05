import Foundation

/// A weak Wi-Fi link or a reader briefly busy serving a preview/transfer must
/// not end the session: allow five consecutive misses with a generous timeout.
struct ConnectionHeartbeat {
    static let failureLimit = 5
    private(set) var consecutiveFailures = 0

    mutating func recordSuccess() {
        consecutiveFailures = 0
    }

    mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        return consecutiveFailures >= Self.failureLimit
    }
}

/// A no-PSRAM X3 keeps only ~6 KB of heap on its private hotspot. Fetching a
/// 53 KB screen preview plus a crash report there tripped the reader's task
/// watchdog (crash breadcrumb `nearby:screen-preview`). Below this floor the
/// app skips both so the link stays available for the transfer itself.
enum ReaderDiagnosticsPolicy {
    static let minimumFreeHeap = 10 * 1024

    static func canFetchDiagnostics(freeHeap: Int, readerSaysAffordable: Bool?) -> Bool {
        if let readerSaysAffordable { return readerSaysAffordable }
        return freeHeap >= minimumFreeHeap
    }
}

/// Answers "did my firmware actually get installed?" without guessing. The
/// app remembers the exact version string embedded in the image it staged and,
/// on the next connection, compares it with what the reader reports running.
enum FirmwareInstallCheck {
    enum Outcome: Equatable {
        case installed(String)
        case stillPending(running: String, staged: String)
        case nothingStaged
    }

    static func evaluate(readerVersion: String, staged: String?) -> Outcome {
        guard let staged, !staged.isEmpty else { return .nothingStaged }
        let normalizedReader = readerVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStaged = staged.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedReader == normalizedStaged
            ? .installed(normalizedStaged)
            : .stillPending(running: normalizedReader, staged: normalizedStaged)
    }
}

@MainActor
final class PocketModel: ObservableObject {
    private static let lastReaderHostKey = "Pocket.lastReaderHost"
    private static let stagedFirmwareVersionKey = "Pocket.stagedFirmwareVersion"

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
    @Published var message = "Wake your reader, open Pocket Daily, and press Sync."
    @Published var isWorking = false
    @Published var uploadProgress: Double = 0
    @Published var preferences: ReaderPreferences?
    @Published var crashDiagnostic: CrashDiagnostic?
    @Published var readerScreenImageData: Data?
    @Published var preferencesDirty = false
    @Published var preferredHardware: PocketHardware = .x3
    @Published var manualHotspotFallback = false
    @Published var locationPermissionRequired = false
    @Published var isDemoMode = false

    private let client = CrossPointClient()
    private let localDiscovery = LocalReaderDiscovery()
    private var activeHost = "192.168.4.1"
    private var activeHTTPPort = 80
    private var discoveryTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var connectionAttempt = 0
    private var nearbyLease: HotspotLease?

    init() {
        if let hardwareArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--hardware=") }),
           let hardware = PocketHardware(rawValue: String(hardwareArgument.dropFirst("--hardware=".count)).uppercased()) {
            preferredHardware = hardware
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            enterDemoMode()
        }
    }

    var hardware: PocketHardware {
        isDemoMode ? preferredHardware : (readerStatus.flatMap { PocketHardware(deviceName: $0.device) } ?? preferredHardware)
    }

    func selectHardware(named name: String) {
        if let hardware = PocketHardware(deviceName: name) { preferredHardware = hardware }
    }

    func connectToExistingHotspot() {
        exitDemoMode()
        Task { await verify(host: "192.168.4.1", port: 80) }
    }

    func startConnectionSearch() {
        nearbyLease = nil
        manualHotspotFallback = false
        locationPermissionRequired = false
        findOnLocalNetwork()
    }

    func findOnLocalNetwork(retryIfMissing: Bool = true) {
        exitDemoMode()
        if let nearbyLease {
            if manualHotspotFallback {
                useNearbyLease(nearbyLease)
            } else {
                Task { await verifyNearbyLease(nearbyLease) }
            }
            return
        }
        connectionAttempt += 1
        heartbeatTask?.cancel()
        let attempt = connectionAttempt
        discoveryTask?.cancel()
        discoveryTask = Task {
            isWorking = true
            message = "Checking the current Wi-Fi and nearby hotspot…"
            defer { isWorking = false }

            let bonjourTask = Task { await localDiscovery.first(timeout: .seconds(5)) }
            let lastHost = UserDefaults.standard.string(forKey: Self.lastReaderHostKey)
            if let lastHost, !lastHost.isEmpty,
               let status = try? await client.status(host: lastHost, port: 80, timeout: 3) {
                guard !Task.isCancelled, attempt == connectionAttempt else { return }
                localDiscovery.stop()
                bonjourTask.cancel()
                await accept(status: status, host: lastHost, httpPort: 80)
                return
            }

            // Bonjour handles crosspoint.local separately. Keeping hostname DNS
            // resolution in this task group can delay cancellation even after a
            // nearby IP has already answered.
            var candidates = ["192.168.4.1"]
                + LocalReaderDiscovery.localIPv4Candidates()
            if let lastHost, !lastHost.isEmpty {
                candidates.removeAll { $0 == lastHost }
            }
            let priorityCount = min(12, candidates.count)
            let priority = await probe(
                hosts: Array(candidates.prefix(priorityCount)),
                timeout: 1.2,
                batchSize: 1
            )
            let found: (String, CrossPointStatus)?
            if let priority {
                found = priority
            } else {
                found = await probe(
                    hosts: Array(candidates.dropFirst(priorityCount)),
                    timeout: 0.8,
                    batchSize: 8
                )
            }

            guard !Task.isCancelled, attempt == connectionAttempt else { return }
            if let (host, status) = found {
                localDiscovery.stop()
                bonjourTask.cancel()
                await accept(status: status, host: host, httpPort: 80)
            } else if let endpoint = await bonjourTask.value,
                      let status = try? await client.status(host: endpoint.host, port: endpoint.port) {
                await accept(status: status, host: endpoint.host, httpPort: endpoint.port)
            } else if readerStatus == nil {
                if retryIfMissing {
                    message = "Reader not ready yet. Retrying nearby addresses…"
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(800))
                        guard let self, self.readerStatus == nil,
                              attempt == self.connectionAttempt else { return }
                        self.findOnLocalNetwork(retryIfMissing: false)
                    }
                } else {
                    message = "No Pocket reader was visible. In Pocket Daily, press Sync; or use File Transfer → Create Hotspot."
                }
            }
        }
    }

    func enterDemoMode() {
        connectionAttempt += 1
        discoveryTask?.cancel()
        heartbeatTask?.cancel()
        localDiscovery.stop()
        nearbyLease = nil
        isWorking = false
        uploadProgress = 0
        isDemoMode = true
        readerStatus = CrossPointStatus(
            version: "DEMO 1.0",
            ip: "LOCAL PREVIEW",
            mode: "DEMO",
            rssi: -42,
            freeHeap: 131_072,
            uptime: 3_600,
            device: preferredHardware.rawValue,
            crashReportAvailable: false,
            crashReportBytes: 0,
            screenPreviewAvailable: false,
            screenPreviewBytes: 0,
            uploadChunkBytes: nil,
            uploadStreamPort: nil,
            uploadStreamResume: nil,
            diagnosticsAffordable: nil
        )
        preferences = ReaderPreferences()
        crashDiagnostic = nil
        readerScreenImageData = nil
        preferencesDirty = false
        manualHotspotFallback = false
        locationPermissionRequired = false
        message = "Demo preview is local only. File transfer and device changes are disabled."
    }

    func exitDemoMode() {
        guard isDemoMode else { return }
        isDemoMode = false
        readerStatus = nil
        preferences = nil
        readerScreenImageData = nil
        preferencesDirty = false
        message = "Wake your reader, open Pocket Daily, and press Sync."
    }

    private func probe(
        hosts: [String],
        timeout: TimeInterval,
        batchSize: Int = 8
    ) async -> (String, CrossPointStatus)? {
        guard !hosts.isEmpty else { return nil }
        for start in stride(from: 0, to: hosts.count, by: batchSize) {
            if Task.isCancelled { return nil }
            let end = min(start + batchSize, hosts.count)
            let batch = hosts[start ..< end]
            let found: (String, CrossPointStatus)? = await withTaskGroup(
                of: (String, CrossPointStatus)?.self
            ) { group in
                for host in batch {
                    group.addTask { [client] in
                        guard let status = try? await client.status(host: host, port: 80, timeout: timeout) else {
                            return nil
                        }
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
            if let found { return found }
        }
        return nil
    }

    func useNearbyLease(_ lease: HotspotLease) {
        connectionAttempt += 1
        heartbeatTask?.cancel()
        discoveryTask?.cancel()
        localDiscovery.stop()
        nearbyLease = lease
        manualHotspotFallback = false
        locationPermissionRequired = false
        readerStatus = nil
        preferences = nil
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await HotspotJoiner.join(lease)
                await waitForReader(lease)
            } catch {
                manualHotspotFallback = true
#if os(macOS)
                locationPermissionRequired = (error as? HotspotJoinError) == .locationPermissionRequired
#else
                locationPermissionRequired = false
#endif
                message = error.localizedDescription
            }
        }
    }

    func openLocationSettings() {
#if os(macOS)
        HotspotJoiner.openLocationSettings()
#endif
    }

    func verifyNearbyLease(_ lease: HotspotLease) async {
        connectionAttempt += 1
        heartbeatTask?.cancel()
        nearbyLease = lease
        isWorking = true
        defer { isWorking = false }
        await waitForReader(lease)
    }

    private func waitForReader(_ lease: HotspotLease) async {
        message = "Waiting for Pocket's private transfer link…"
        let deadline = ContinuousClock.now + .seconds(18)
        while ContinuousClock.now < deadline {
            if let status = try? await client.status(host: lease.host, port: lease.httpPort) {
                await accept(status: status, host: lease.host, httpPort: lease.httpPort)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        readerStatus = nil
        preferences = nil
        nearbyLease = lease
        manualHotspotFallback = true
        message = "Private link not ready. Join \(lease.ssid), then tap Verify connection."
    }

    func verify(host: String, port: Int) async {
        connectionAttempt += 1
        heartbeatTask?.cancel()
        isWorking = true
        defer { isWorking = false }
        do {
            let status = try await client.status(host: host, port: port)
            await accept(status: status, host: host, httpPort: port)
        } catch {
            readerStatus = nil
            preferences = nil
            readerScreenImageData = nil
            message = "Reader not found. Open Create Hotspot on the reader and try again."
        }
    }

    private func accept(status: CrossPointStatus, host: String, httpPort: Int) async {
        readerStatus = status
        UserDefaults.standard.set(host, forKey: Self.lastReaderHostKey)
        selectHardware(named: status.device)
        activeHost = host
        activeHTTPPort = httpPort
        manualHotspotFallback = false
        locationPermissionRequired = false
        preferences = try? await client.preferences(host: host, port: httpPort)
        readerScreenImageData = nil
        let diagnosticsAffordable = ReaderDiagnosticsPolicy.canFetchDiagnostics(
            freeHeap: status.freeHeap,
            readerSaysAffordable: status.diagnosticsAffordable
        )
        if diagnosticsAffordable, status.screenPreviewAvailable == true,
           let bytes = status.screenPreviewBytes,
           let preview = try? await client.screenPreview(host: host, port: httpPort, expectedBytes: bytes) {
            readerScreenImageData = preview
        }
        crashDiagnostic = nil
        if diagnosticsAffordable, status.crashReportAvailable == true, let bytes = status.crashReportBytes, bytes > 0,
           let diagnostic = try? await client.crashDiagnostic(host: host, port: httpPort, expectedBytes: bytes) {
            crashDiagnostic = diagnostic
            _ = try? await Task.detached(priority: .utility) {
                try CrashReportArchive.store(report: diagnostic.report, device: status.device)
            }.value
        }
        preferencesDirty = false
        let staged = UserDefaults.standard.string(forKey: Self.stagedFirmwareVersionKey)
        switch FirmwareInstallCheck.evaluate(readerVersion: status.version, staged: staged) {
        case let .installed(version):
            UserDefaults.standard.removeObject(forKey: Self.stagedFirmwareVersionKey)
            message = "Firmware installed: the reader is now running \(version)."
            startHeartbeat(host: host, port: httpPort)
            return
        case let .stillPending(running, stagedVersion):
            message = "Not installed yet: the reader still runs \(running). The staged \(stagedVersion) is on the SD card as /update.bin — install it from Settings → System → Update firmware."
            startHeartbeat(host: host, port: httpPort)
            return
        case .nothingStaged:
            break
        }
        if !diagnosticsAffordable {
            message = "Connected to \(status.device). Reader memory is low (\(status.freeHeap / 1024) KB free), so the screen preview and crash report were skipped to keep transfers stable."
        } else if crashDiagnostic != nil {
            message = "Connected to \(status.device). A saved crash report is available below."
        } else if readerScreenImageData != nil {
            message = "Connected to \(status.device). The captured reader frame is shown exactly."
        } else if status.mode == "STA" {
            message = "Connected to \(status.device) over your Wi-Fi network — the most reliable path for firmware and content transfers."
        } else {
            message = "Connected to \(status.device). Reconnect from Pocket Daily Nearby Sync to capture its screen."
        }
        startHeartbeat(host: host, port: httpPort)
    }

    private func startHeartbeat(host: String, port: Int) {
        heartbeatTask?.cancel()
        let attempt = connectionAttempt
        heartbeatTask = Task { @MainActor [weak self] in
            var heartbeat = ConnectionHeartbeat()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard let self, !Task.isCancelled,
                      attempt == self.connectionAttempt,
                      self.readerStatus != nil else { return }
                if self.isWorking { continue }

                do {
                    let status = try await self.client.status(host: host, port: port, timeout: 6)
                    heartbeat.recordSuccess()
                    self.readerStatus = status
                } catch {
                    guard heartbeat.recordFailure() else { continue }
                    self.readerStatus = nil
                    self.preferences = nil
                    self.readerScreenImageData = nil
                    self.preferencesDirty = false
                    self.nearbyLease = nil
                    self.message = "Pocket connection ended. Open Nearby Sync and reconnect."
                    return
                }
            }
        }
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
        guard !isDemoMode else {
            message = "Demo preview does not change a reader."
            return
        }
        guard let preferences else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await client.save(preferences: preferences, host: activeHost, port: activeHTTPPort)
                preferencesDirty = false
                message = "Settings were applied to \(hardware.rawValue)."
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func upload(_ url: URL) {
        guard !isDemoMode else {
            message = "Connect a reader before sending files."
            return
        }
        Task {
            isWorking = true
            uploadProgress = 0
            defer { isWorking = false }
            do {
                let isFirmware = url.pathExtension.lowercased() == "bin"
                let firmware: FirmwareImageMetadata?
                if isFirmware {
                    guard let device = readerStatus?.device,
                          PocketHardware(deviceName: device) != nil else {
                        throw FirmwareValidationError.unsupportedReader(readerStatus?.device ?? "unknown")
                    }
                    message = "Validating firmware before staging…"
                    firmware = try await Task.detached(priority: .userInitiated) {
                        try FirmwareImageValidator.validate(fileURL: url)
                    }.value
                } else {
                    firmware = nil
                }
                let path = try await client.uploadAtomically(
                    fileURL: url,
                    publishedFilename: isFirmware ? "update.bin" : nil,
                    destination: destination(for: url),
                    host: activeHost,
                    port: activeHTTPPort,
                    uploadChunkBytes: readerStatus?.uploadChunkBytes,
                    uploadStreamPort: readerStatus?.uploadStreamPort,
                    uploadStreamResume: readerStatus?.uploadStreamResume ?? false,
                    note: { [weak self] text in Task { @MainActor in self?.message = text } },
                    reconnect: { [weak self] in await self?.reconnectForTransfer() ?? false }
                ) { [weak self] sent, total in
                    Task { @MainActor in self?.uploadProgress = total > 0 ? Double(sent) / Double(total) : 0 }
                }
                uploadProgress = 1
                if isFirmware, let version = firmware?.version {
                    UserDefaults.standard.set(version, forKey: Self.stagedFirmwareVersionKey)
                    message = "STAGED, NOT INSTALLED YET — \(version) was verified and written to /update.bin. Install it from Settings → System → Update firmware, then reconnect: the app will confirm whether the reader is running it."
                } else {
                    message = "\(url.lastPathComponent) was verified and published at \(path)."
                }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Called by the upload client when the reader stopped answering mid-transfer.
    /// macOS in particular can auto-switch away from an internet-less hotspot;
    /// rejoin the leased network so the interrupted upload can resume.
    private func reconnectForTransfer() async -> Bool {
        guard let lease = nearbyLease else { return false }
        message = "Private link dropped. Rejoining \(lease.ssid)…"
        do {
            try await HotspotJoiner.join(lease)
        } catch {
            return false
        }
        let deadline = ContinuousClock.now + .seconds(18)
        while ContinuousClock.now < deadline {
            if (try? await client.status(host: lease.host, port: lease.httpPort, timeout: 3)) != nil { return true }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
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
        case "bin":
            _ = try FirmwareImageValidator.validate(fileURL: source)
            relativeDirectory = ""
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
