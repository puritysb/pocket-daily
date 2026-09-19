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

/// How the single status line should be presented. Carried explicitly with
/// the message so the UI never has to guess from the wording.
enum StatusTone: Equatable {
    case neutral
    case success
    case pending
    case failure
}

struct SDCopyResult: Equatable {
    let path: String
    let firmwareVersion: String?
}

struct PreparedTransfer: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let firmwareVersion: String?
    var readerID: String?
}

/// Files are copied out of cloud/file-provider URLs before changing networks.
enum TransferPreparation {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pocket/Transfers", isDirectory: true)
    }

    static func prepare(_ source: URL, directory: URL = directory) throws -> PreparedTransfer {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let id = UUID()
        let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let destination = folder.appendingPathComponent(source.lastPathComponent)
            let coordinator = NSFileCoordinator()
            var coordinationError: NSError?
            var copyError: Error?
            coordinator.coordinate(readingItemAt: source, options: [], error: &coordinationError) { readable in
                do { try FileManager.default.copyItem(at: readable, to: destination) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
            let firmware = source.pathExtension.lowercased() == "bin"
                ? try FirmwareImageValidator.validate(fileURL: destination) : nil
            let item = PreparedTransfer(id: id, filename: source.lastPathComponent,
                                        firmwareVersion: firmware?.version)
            try JSONEncoder().encode(item).write(to: folder.appendingPathComponent("transfer.json"), options: .atomic)
            return item
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    static func file(_ item: PreparedTransfer) -> URL {
        directory.appendingPathComponent(item.id.uuidString).appendingPathComponent(item.filename)
    }
}

@MainActor
final class PocketModel: ObservableObject, DeviceSession {
    static let initialMessage = "Prepare files, then find the reader on your Wi-Fi or connect directly when away."

    /// Studio-facing snapshot fed from this session's transitions. Views read
    /// the legacy published fields until they migrate onto the mirror.
    let mirror = DeviceMirror()
    var syncMode: DeviceSyncMode { SyncModePolicy.syncMode(status: readerStatus, isDemoMode: isDemoMode) }

    private var liveSync: LiveSyncClient?
    private var frameFetchPolicy = FrameFetchPolicy()

    private func startLiveSync(host: String, wsPort: Int) {
        guard liveSync == nil else { return }
        let client = LiveSyncClient(host: host, wsPort: wsPort)
        client.onEvent = { [weak self] event in
            self?.handleLiveEvent(event)
        }
        liveSync = client
        client.start()
    }

    private func stopLiveSync() {
        liveSync?.stop()
        liveSync = nil
        frameFetchPolicy.reset()
    }

    private func handleLiveEvent(_ event: LiveStudioEvent) {
        switch event {
        case let .status(status):
            readerStatus = status
            mirror.apply(.status(status))
        case let .frame(seq, bytes):
            fetchLiveFrame(seq: seq, bytes: bytes)
        case .prefsChanged:
            reloadPreferencesFromReader()
        case .hello, .bye:
            break
        }
    }

    private func fetchLiveFrame(seq: Int, bytes: Int) {
        guard frameFetchPolicy.shouldFetch(seq: seq) else { return }
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        Task {
            do {
                let data = try await client.screenLive(host: host, port: port, expectedBytes: bytes)
                guard attempt == connectionAttempt else { return }
                readerScreenImageData = data
                mirror.apply(.frame(seq: seq, capturedAt: Date(), data: data))
            } catch {
                guard attempt == connectionAttempt else { return }
            }
            if let next = frameFetchPolicy.fetchCompleted() {
                fetchLiveFrame(seq: next, bytes: bytes)
            }
        }
    }

    private func reloadPreferencesFromReader() {
        let attempt = connectionAttempt
        Task {
            guard let loaded = try? await client.preferences(host: activeHost, port: activeHTTPPort),
                  attempt == connectionAttempt else { return }
            preferences = loaded
            preferencesDirty = false
            mirror.apply(.preferences(loaded))
        }
    }

    /// Addresses adjacent to this device, tried together before the wider sweep.
    private static let priorityHostCount = 24
    /// Requests kept in flight while sweeping the rest of the subnet. Each probe is a
    /// separate host, so they do not contend, and a /22 finishes in seconds instead of
    /// the ~100 s a batch of 8 took.
    private static let sweepConcurrency = 48
    /// Upper bound on one discovery pass. Without it, a subnet with no reader on it
    /// left the user watching a spinner for minutes before any actionable message.
    /// Sized so a full /22 still fits: ~1000 addresses at 48 in flight and a 0.6 s
    /// timeout is ~13 s of sweeping, so the budget bounds the wait without cutting
    /// coverage short on the largest home subnet the candidate list builds.
    private static let discoveryBudget: Duration = .seconds(20)
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
    @Published private(set) var message = PocketModel.initialMessage
    @Published private(set) var messageTone: StatusTone = .neutral
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
    private var joinTask: Task<Void, Never>?
    private var transferTask: Task<Void, Never>?
    private var expectedDeviceID: String?
    @Published private(set) var directConnectionRequested = false
    @Published private(set) var preparedTransfers: [PreparedTransfer] = []
    var hasDirectSession: Bool { directConnectionRequested || nearbyLease != nil }
    var canPrepareFiles: Bool { !isDemoMode && !isWorking }
    var isTransferring: Bool { transferTask != nil }

    func expectDirectReader(_ id: String) { expectedDeviceID = id }

    private var firmwareKey: String? {
        (readerStatus?.deviceID ?? expectedDeviceID).map { Self.stagedFirmwareVersionKey + "." + $0 }
    }


    init() {
        if let folders = try? FileManager.default.contentsOfDirectory(at: TransferPreparation.directory,
                                                                       includingPropertiesForKeys: nil) {
            preparedTransfers = folders.compactMap { folder in
                guard let data = try? Data(contentsOf: folder.appendingPathComponent("transfer.json")),
                      let item = try? JSONDecoder().decode(PreparedTransfer.self, from: data),
                      FileManager.default.fileExists(atPath: TransferPreparation.file(item).path) else { return nil }
                return item
            }.sorted {
                let leftFirmware = $0.filename.lowercased().hasSuffix(".bin")
                let rightFirmware = $1.filename.lowercased().hasSuffix(".bin")
                if leftFirmware != rightFirmware { return !leftFirmware }
                return $0.id.uuidString < $1.id.uuidString
            }
        }
        if let hardwareArgument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--hardware=") }),
           let hardware = PocketHardware(rawValue: String(hardwareArgument.dropFirst("--hardware=".count)).uppercased()) {
            preferredHardware = hardware
        }
        if ProcessInfo.processInfo.arguments.contains("--demo") {
            enterDemoMode()
        }
    }

    func post(_ text: String, tone: StatusTone = .neutral) {
        message = text
        messageTone = tone
    }

    func post(_ error: Error) {
        post(error.localizedDescription, tone: .failure)
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
        guard !isWorking, !hasDirectSession else { return }
        readerStatus = nil
        expectedDeviceID = nil
        nearbyLease = nil
        manualHotspotFallback = false
        locationPermissionRequired = false
        mirror.apply(.connection(.searching))
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
            post("Checking your current Wi-Fi without changing networks…")
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
            // Addresses next to this device answer first on a typical home network, so
            // try a small nearby set quickly before sweeping the rest of the subnet.
            let priorityCount = min(Self.priorityHostCount, candidates.count)
            let deadline = ContinuousClock.now + Self.discoveryBudget
            var found = await probe(
                hosts: Array(candidates.prefix(priorityCount)),
                timeout: 1.0,
                concurrency: Self.priorityHostCount,
                deadline: deadline
            )
            if found == nil {
                post("Scanning your Wi-Fi network for the reader…")
                found = await probe(
                    hosts: Array(candidates.dropFirst(priorityCount)),
                    timeout: 0.6,
                    concurrency: Self.sweepConcurrency,
                    deadline: deadline
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
                    // Sweep once more, and only once: a reader that finished joining
                    // the network mid-scan is invisible to the first pass but answers
                    // the second. Each pass is bounded by discoveryBudget, so the two
                    // together still resolve in well under a minute.
                    post("Reader not ready yet. Scanning once more…")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .milliseconds(800))
                        guard let self, self.readerStatus == nil,
                              attempt == self.connectionAttempt else { return }
                        self.findOnLocalNetwork(retryIfMissing: false)
                    }
                } else {
                    post("No Pocket reader was visible. Open File Transfer → Join a Network on the reader, or choose Connect directly when away.", tone: .failure)
                }
            }
        }
    }

    func enterDemoMode() {
        guard !isWorking, !hasDirectSession else { return }
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
        mirror.apply(.status(readerStatus!))
        mirror.apply(.preferences(preferences))
        post("Demo preview is local only. File transfer and device changes are disabled.")
    }

    func exitDemoMode() {
        guard isDemoMode else { return }
        isDemoMode = false
        readerStatus = nil
        preferences = nil
        readerScreenImageData = nil
        preferencesDirty = false
        stopLiveSync()
        mirror.apply(.connection(.disconnected))
        post(Self.initialMessage)
    }

    /// Probes candidate addresses for a reader, keeping `concurrency` requests in
    /// flight at once and stopping at `deadline`.
    ///
    /// A sliding window rather than fixed batches: every address that is not a
    /// reader costs the full timeout, so a batch is only ever as fast as its
    /// slowest member, and a strictly sequential pass over a home subnet took
    /// minutes to report a reader that simply was not there.
    private func probe(
        hosts: [String],
        timeout: TimeInterval,
        concurrency: Int,
        deadline: ContinuousClock.Instant
    ) async -> (String, CrossPointStatus)? {
        guard !hosts.isEmpty, concurrency > 0 else { return nil }
        let client = self.client
        return await withTaskGroup(of: (String, CrossPointStatus)?.self) { group in
            var next = 0
            while next < hosts.count, next < concurrency {
                let host = hosts[next]
                group.addTask {
                    guard let status = try? await client.status(host: host, port: 80, timeout: timeout) else {
                        return nil
                    }
                    return (host, status)
                }
                next += 1
            }

            while let result = await group.next() {
                if let result {
                    group.cancelAll()
                    return result
                }
                if Task.isCancelled || ContinuousClock.now >= deadline {
                    group.cancelAll()
                    return nil
                }
                guard next < hosts.count else { continue }
                let host = hosts[next]
                group.addTask {
                    guard let status = try? await client.status(host: host, port: 80, timeout: timeout) else {
                        return nil
                    }
                    return (host, status)
                }
                next += 1
            }
            return nil
        }
    }

    func useNearbyLease(_ lease: HotspotLease) {
        guard directConnectionRequested, !isTransferring else { return }
        isWorking = true
        connectionAttempt += 1
        heartbeatTask?.cancel()
        discoveryTask?.cancel()
        localDiscovery.stop()
        nearbyLease = lease
        manualHotspotFallback = false
        locationPermissionRequired = false
        readerStatus = nil
        preferences = nil
        let attempt = connectionAttempt
        joinTask?.cancel()
        joinTask = Task {
            isWorking = true
            defer { isWorking = false; joinTask = nil }
            do {
                try await HotspotJoiner.join(lease)
                guard !Task.isCancelled, attempt == connectionAttempt else {
                    await HotspotJoiner.leave(ssid: lease.ssid)
                    return
                }
                await waitForReader(lease)
            } catch {
                guard !Task.isCancelled, attempt == connectionAttempt else { return }
                manualHotspotFallback = true
#if os(macOS)
                locationPermissionRequired = (error as? HotspotJoinError) == .locationPermissionRequired
#else
                locationPermissionRequired = false
#endif
                post(error)
            }
        }
    }

    func openLocationSettings() {
#if os(macOS)
        HotspotJoiner.openLocationSettings()
#endif
    }

    func verifyNearbyLease(_ lease: HotspotLease) async {
        guard directConnectionRequested, !isWorking else { return }
        connectionAttempt += 1
        heartbeatTask?.cancel()
        nearbyLease = lease
        isWorking = true
        defer { isWorking = false }
        await waitForReader(lease)
    }

    private func waitForReader(_ lease: HotspotLease) async {
        post("Waiting for Pocket's private transfer link…")
        mirror.apply(.connection(.waitingForReader))
        let deadline = ContinuousClock.now + .seconds(18)
        let attempt = connectionAttempt
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, attempt == connectionAttempt else { return }
            if let status = try? await client.status(host: lease.host, port: lease.httpPort) {
                guard !Task.isCancelled, attempt == connectionAttempt else { return }
                await accept(status: status, host: lease.host, httpPort: lease.httpPort)
                return
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        readerStatus = nil
        preferences = nil
        nearbyLease = lease
        manualHotspotFallback = true
        stopLiveSync()
        mirror.apply(.connection(.disconnected))
        post("Private link not ready. Join \(lease.ssid), then tap Verify connection.", tone: .failure)
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
            stopLiveSync()
        mirror.apply(.connection(.disconnected))
            post("Reader not found. Open Create Hotspot on the reader and try again.", tone: .failure)
        }
    }

    private func accept(status: CrossPointStatus, host: String, httpPort: Int) async {
        guard !Task.isCancelled else { return }
        guard PocketHardware(deviceName: status.device) != nil else {
            post("The discovered endpoint is not a supported reader.", tone: .failure)
            return
        }
        if let expectedDeviceID, let actual = status.deviceID, expectedDeviceID != actual {
            post("The Wi-Fi reader does not match the paired reader. End the session and reconnect.", tone: .failure)
            return
        }
        readerStatus = status
        mirror.apply(.status(status))
        UserDefaults.standard.set(host, forKey: Self.lastReaderHostKey)
        selectHardware(named: status.device)
        activeHost = host
        activeHTTPPort = httpPort
        manualHotspotFallback = false
        locationPermissionRequired = false
        let attempt = connectionAttempt
        let loadedPreferences = try? await client.preferences(host: host, port: httpPort)
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        preferences = loadedPreferences
        mirror.apply(.preferences(preferences))
        readerScreenImageData = nil
        let diagnosticsAffordable = nearbyLease == nil && ReaderDiagnosticsPolicy.canFetchDiagnostics(
            freeHeap: status.freeHeap,
            readerSaysAffordable: status.diagnosticsAffordable
        )
        if diagnosticsAffordable, status.screenPreviewAvailable == true,
           let bytes = status.screenPreviewBytes,
           let preview = try? await client.screenPreview(host: host, port: httpPort, expectedBytes: bytes) {
            guard !Task.isCancelled, attempt == connectionAttempt else { return }
            readerScreenImageData = preview
            mirror.apply(.frame(seq: mirror.state.frameSequence + 1, capturedAt: Date(), data: preview))
        }
        crashDiagnostic = nil
        if diagnosticsAffordable, status.crashReportAvailable == true, let bytes = status.crashReportBytes, bytes > 0,
           let diagnostic = try? await client.crashDiagnostic(host: host, port: httpPort, expectedBytes: bytes) {
            guard !Task.isCancelled, attempt == connectionAttempt else { return }
            crashDiagnostic = diagnostic
            _ = try? await Task.detached(priority: .utility) {
                try CrashReportArchive.store(report: diagnostic.report, device: status.device)
            }.value
        }
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        preferencesDirty = false
        if case let .push(wsPort) = SyncModePolicy.syncMode(status: status, isDemoMode: false) {
            startLiveSync(host: host, wsPort: wsPort)
        }
        let staged = firmwareKey.flatMap { UserDefaults.standard.string(forKey: $0) }
        switch FirmwareInstallCheck.evaluate(readerVersion: status.version, staged: staged) {
        case let .installed(version):
            if let firmwareKey { UserDefaults.standard.removeObject(forKey: firmwareKey) }
            post("Firmware installed: the reader is now running \(version).", tone: .success)
            startHeartbeat(host: host, port: httpPort)
            return
        case let .stillPending(running, stagedVersion):
            post("Not installed yet: the reader still runs \(running). The staged \(stagedVersion) is on the SD card as /update.bin — install it from Settings → System → Update firmware.", tone: .pending)
            startHeartbeat(host: host, port: httpPort)
            return
        case .nothingStaged:
            break
        }
        if nearbyLease != nil {
            post("Direct connection ready. Optional diagnostics are deferred to leave memory for transfers. Keep this app open.")
        } else if !diagnosticsAffordable {
            post("Connected to \(status.device). Reader memory is low (\(status.freeHeap / 1024) KB free), so the screen preview and crash report were skipped to keep transfers stable.")
        } else if crashDiagnostic != nil {
            post("Connected to \(status.device). A saved crash report is available below.")
        } else if readerScreenImageData != nil {
            post("Connected to \(status.device). The captured reader frame is shown exactly.")
        } else if status.mode == "STA" {
            post("Connected to \(status.device) over your Wi-Fi network — the most reliable path for firmware and content transfers.")
        } else {
            post("Connected to \(status.device). Reconnect from Pocket Daily Nearby Sync to capture its screen.")
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
            if let id = self.readerStatus?.deviceID, status.deviceID != id {
                self.readerStatus = nil
                self.preferences = nil
                self.stopLiveSync()
                self.mirror.apply(.connection(.disconnected))
                self.post("A different reader answered at this address. Reconnect before sending files.", tone: .failure)
                return
                    }
                    self.readerStatus = status
                    self.mirror.apply(.status(status))
                } catch {
                    guard heartbeat.recordFailure() else { continue }
                    self.readerStatus = nil
                    self.preferences = nil
                    self.readerScreenImageData = nil
                    self.preferencesDirty = false
                    self.stopLiveSync()
                    self.mirror.apply(.connection(.disconnected))
                    self.post("Pocket connection ended. Open Nearby Sync and reconnect.", tone: .failure)
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

    func loadReaderPreview() {
        guard !isDemoMode, !isWorking, readerStatus != nil else { return }
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                let status = try await client.status(host: host, port: port)
                guard attempt == connectionAttempt else { return }
                guard status.deviceID == readerStatus?.deviceID,
                      status.screenPreviewAvailable == true,
                      ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: status.freeHeap,
                                                                 readerSaysAffordable: status.diagnosticsAffordable),
                      let bytes = status.screenPreviewBytes else {
                    post("A preview is unavailable in this reader profile or memory state.")
                    return
                }
                let data = try await client.screenPreview(host: host, port: port, expectedBytes: bytes)
                guard attempt == connectionAttempt else { return }
                readerScreenImageData = data
                mirror.apply(.frame(seq: mirror.state.frameSequence + 1, capturedAt: Date(), data: data))
                post("Loaded the reader frame captured before Sync opened.")
            } catch {
                guard attempt == connectionAttempt else { return }
                post(error)
            }
        }
    }

    func savePreferences() {
        guard !isDemoMode else {
            post("Demo preview does not change a reader.")
            return
        }
        guard let preferences else { return }
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                try await client.save(preferences: preferences, host: activeHost, port: activeHTTPPort)
                preferencesDirty = false
                post("Settings were applied to \(hardware.rawValue).", tone: .success)
            } catch {
                post(error)
            }
        }
    }

    func upload(_ url: URL) {
        guard canPrepareFiles else { return }
        if url.pathExtension.lowercased() == "bin",
           preparedTransfers.contains(where: { $0.filename.lowercased().hasSuffix(".bin") }) {
            post("Only one firmware image can be prepared at a time. Remove the pending files to replace it.", tone: .failure)
            return
        }
        isWorking = true
        post("Preparing an offline copy before transfer…")
        Task {
            defer { isWorking = false }
            do {
                let item = try await Task.detached(priority: .userInitiated) {
                    try TransferPreparation.prepare(url)
                }.value
                if item.filename.lowercased().hasSuffix(".bin") { preparedTransfers.append(item) }
                else {
                    let index = preparedTransfers.firstIndex { $0.filename.lowercased().hasSuffix(".bin") }
                        ?? preparedTransfers.count
                    preparedTransfers.insert(item, at: index)
                }
                post(readerStatus != nil
                    ? "\(item.filename) is ready. Choose Send prepared files."
                    : "\(item.filename) is ready offline. Connect, then send prepared files.")
            } catch { post(error) }
        }
    }

    func sendPreparedFiles() {
        guard !isDemoMode, !isWorking, let expectedStatus = readerStatus, !preparedTransfers.isEmpty else { return }
        let host = activeHost
        let port = activeHTTPPort
        let key = firmwareKey
        isWorking = true
        transferTask = Task {
            defer { isWorking = false; transferTask = nil }
            do {
                let status = try await client.status(host: host, port: port)
                try Task.checkCancellation()
                guard status.device == expectedStatus.device,
                      expectedStatus.deviceID == nil || expectedStatus.deviceID == status.deviceID else {
                    throw CrossPointClient.ClientError.unexpectedMessage("The reader changed. Reconnect before sending files.")
                }
                if let expectedDeviceID, let actual = status.deviceID, expectedDeviceID != actual {
                    throw CrossPointClient.ClientError.unexpectedMessage("The reader does not match the paired identity.")
                }
                while var item = preparedTransfers.first {
                    try Task.checkCancellation()
                    if let bound = item.readerID, bound != status.deviceID {
                        throw CrossPointClient.ClientError.unexpectedMessage("This pending file belongs to another reader. Remove it and prepare it again to change readers.")
                    }
                    item.readerID = status.deviceID
                    try JSONEncoder().encode(item).write(to: TransferPreparation.directory
                        .appendingPathComponent(item.id.uuidString).appendingPathComponent("transfer.json"), options: .atomic)
                    preparedTransfers[0] = item
                    let url = TransferPreparation.file(item)
                    let isFirmware = url.pathExtension.lowercased() == "bin"
                    if isFirmware {
                        guard PocketHardware(deviceName: status.device) != nil else {
                            throw FirmwareValidationError.unsupportedReader(status.device)
                        }
                    }
                    uploadProgress = 0
                    post("Sending \(item.filename)…")
                    let path = try await client.uploadAtomically(
                        fileURL: url, publishedFilename: isFirmware ? "update.bin" : nil,
                        destination: destination(for: url), host: host, port: port,
                        uploadChunkBytes: status.uploadChunkBytes, uploadStreamPort: status.uploadStreamPort,
                        uploadStreamResume: status.uploadStreamResume ?? false,
                        transferID: status.deviceID == nil ? UUID() : item.id,
                        note: { [weak self] text in Task { @MainActor in self?.post(text) } },
                        reconnect: { [weak self] in await self?.reconnectForTransfer() ?? false }
                    ) { [weak self] sent, total in
                        Task { @MainActor in
                            let progress = total > 0 ? Double(sent) / Double(total) : 0
                            self?.uploadProgress = progress
                            self?.mirror.apply(.transferProgress(progress))
                        }
                    }
                    uploadProgress = 1
                    mirror.apply(.transferProgress(1))
                    if isFirmware {
                        if let key, let version = item.firmwareVersion { UserDefaults.standard.set(version, forKey: key) }
                        post(Self.stagedFirmwareMessage(version: item.firmwareVersion ?? "unknown version"), tone: .pending)
                    } else {
                        post("\(item.filename) was verified and published at \(path).", tone: .success)
                    }
                    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    preparedTransfers.removeFirst()
                }
                if hasDirectSession { await finishConnection(preserveMessage: true) }
            } catch {
                if Task.isCancelled { post("Transfer paused. Files remain ready offline; reconnect and send to resume.", tone: .pending) }
                else { post(error) }
            }
        }
    }

    func removePreparedFiles() {
        guard !isWorking else { return }
        do {
            while let item = preparedTransfers.first {
                let folder = TransferPreparation.file(item).deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: folder.path) {
                    try FileManager.default.removeItem(at: folder)
                }
                preparedTransfers.removeFirst()
            }
            uploadProgress = 0
            post("Prepared files removed. Choose another file to continue.")
        } catch { post(error) }
    }

    func resumeDirectConnection() -> Bool {
        guard let lease = nearbyLease else { return false }
        useNearbyLease(lease)
        return true
    }

    func beginDirectConnection() {
        guard !isWorking, !isDemoMode, readerStatus == nil else { return }
        connectionAttempt += 1
        discoveryTask?.cancel()
        heartbeatTask?.cancel()
        localDiscovery.stop()
        directConnectionRequested = true
        mirror.apply(.connection(.waitingForReader))
        post("On the reader, open Pocket Daily → Nearby Sync. Keep this app open during direct transfer.")
    }

    func endConnection() {
        guard !isWorking else { return }
        isWorking = true
        Task {
            await finishConnection(preserveMessage: false)
            isWorking = false
        }
    }

    func pauseTransfer() { transferTask?.cancel() }

    func pauseForBackground() {
        transferTask?.cancel()
        // joinOnce is released by iOS while in the background. Never rejoin there.
        connectionAttempt += 1
        joinTask?.cancel()
        discoveryTask?.cancel()
        heartbeatTask?.cancel()
        localDiscovery.stop()
        if hasDirectSession {
            manualHotspotFallback = nearbyLease != nil
            readerStatus = nil
            preferences = nil
            stopLiveSync()
        mirror.apply(.connection(.disconnected))
            post("Direct connection paused. Return to the app and reconnect to continue.", tone: .pending)
        }
    }

    private func finishConnection(preserveMessage: Bool) async {
        directConnectionRequested = false
        connectionAttempt += 1
        joinTask?.cancel()
        discoveryTask?.cancel()
        heartbeatTask?.cancel()
        localDiscovery.stop()
        let legacyDirectSession = nearbyLease != nil && readerStatus?.sessionEnd != true
        var readerEnded = true
        if nearbyLease != nil, readerStatus?.sessionEnd == true {
            do { try await client.endDirectSession(host: activeHost, port: activeHTTPPort) }
            catch { readerEnded = false }
        }
        if let lease = nearbyLease { await HotspotJoiner.leave(ssid: lease.ssid) }
        nearbyLease = nil
        expectedDeviceID = nil
        directConnectionRequested = false
        manualHotspotFallback = false
        locationPermissionRequired = false
        readerStatus = nil
        preferences = nil
        readerScreenImageData = nil
        stopLiveSync()
        mirror.apply(.connection(.disconnected))
        if !preserveMessage { post("Session ended. Check Wi-Fi settings if your usual connection has not returned.") }
        if legacyDirectSession { post(message + " Close Sync on the reader when finished.", tone: messageTone) }
        if !readerEnded { post(message + " Close Sync on the reader; its session-end response was not received.", tone: .pending) }
    }

    static func stagedFirmwareMessage(version: String) -> String {
        "STAGED, NOT INSTALLED YET — \(version) was verified and written to /update.bin. Install it from Settings → System → Update firmware, then reconnect: the app will confirm whether the reader is running it."
    }

    /// Called by the upload client when the reader stopped answering mid-transfer.
    /// macOS in particular can auto-switch away from an internet-less hotspot;
    /// rejoin the leased network so the interrupted upload can resume.
    private func reconnectForTransfer() async -> Bool {
        guard !Task.isCancelled, let lease = nearbyLease else { return false }
        post("Private link dropped. Rejoining \(lease.ssid)…")
        do {
            try await HotspotJoiner.join(lease)
        } catch {
            return false
        }
        let deadline = ContinuousClock.now + .seconds(18)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return false }
            if let status = try? await client.status(host: lease.host, port: lease.httpPort, timeout: 3) {
                guard !Task.isCancelled else { return false }
                if let expectedDeviceID, let actual = status.deviceID, actual != expectedDeviceID { return false }
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    func copyToSD(_ source: URL, root: URL) {
        Task {
            isWorking = true
            defer { isWorking = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try Self.copyToSDOffMain(source: source, root: root)
                }.value
                if let version = result.firmwareVersion {
                    post("STAGED, NOT INSTALLED YET — \(version) was written to /update.bin. Install on the reader and check its version there; an SD folder does not identify the reader.", tone: .pending)
                } else {
                    post("Copied to SD card: \(result.path)", tone: .success)
                }
            } catch {
                post(error)
            }
        }
    }

    private func destination(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "pdl": "/pocket-daily/learning"
        default: "/"
        }
    }

    /// Copies one user-selected file into the mounted SD card layout. Firmware
    /// is validated first and always published as `/update.bin` (replacing a
    /// previously staged image) so the SD path matches the wireless path and
    /// the install check can confirm it on the next connection. Other files
    /// are never overwritten.
    nonisolated static func copyToSDOffMain(source: URL, root: URL) throws -> SDCopyResult {
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
        var publishedName = source.lastPathComponent
        var firmwareVersion: String?
        switch source.pathExtension.lowercased() {
        case "pdl":
            relativeDirectory = "pocket-daily/learning"
        case "cpfont":
            try validateFont(source)
            relativeDirectory = ".fonts/\(fontFamily(from: source.deletingPathExtension().lastPathComponent))"
        case "bin":
            let metadata = try FirmwareImageValidator.validate(fileURL: source)
            firmwareVersion = metadata.version ?? "unknown version"
            publishedName = "update.bin"
            relativeDirectory = ""
        default:
            relativeDirectory = ""
        }

        let directory = relativeDirectory.isEmpty ? root : root.appendingPathComponent(relativeDirectory, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(publishedName)
        let isFirmware = firmwareVersion != nil
        guard isFirmware || !manager.fileExists(atPath: destination.path) else {
            throw StorageError.destinationExists(publishedName)
        }

        let staging = directory.appendingPathComponent(".\(publishedName).pocket-staging-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: staging) }
        try manager.copyItem(at: source, to: staging)
        if isFirmware, manager.fileExists(atPath: destination.path) {
            _ = try manager.replaceItemAt(destination, withItemAt: staging)
        } else {
            try manager.moveItem(at: staging, to: destination)
        }
        let path = destination.path.replacingOccurrences(of: root.path, with: "", options: [.anchored])
        return SDCopyResult(path: path, firmwareVersion: firmwareVersion)
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
