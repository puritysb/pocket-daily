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

struct SDCopyResult: Equatable, Sendable {
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
    struct LocalFileOperations: Sendable {
        var prepare: @Sendable (URL) async throws -> PreparedTransfer = { url in
            try await Task.detached(priority: .userInitiated) { try TransferPreparation.prepare(url) }.value
        }
        var copy: @Sendable (URL, URL) async throws -> SDCopyResult = { source, root in
            try await Task.detached(priority: .userInitiated) {
                try PocketModel.copyToSDOffMain(source: source, root: root)
            }.value
        }
    }
    static let initialMessage = "Prepare files, then find the reader on your Wi-Fi or connect directly when away."

    /// Studio-facing snapshot fed from this session's transitions. Views read
    /// the legacy published fields until they migrate onto the mirror.
    let mirror = DeviceMirror()
    var syncMode: DeviceSyncMode { SyncModePolicy.syncMode(status: readerStatus, isDemoMode: isDemoMode) }

    private var liveSync: LiveSyncClient?
    private var frameFetchPolicy = FrameFetchPolicy()
    private var frameTask: Task<Void, Never>?
    private var preferencesTask: Task<Void, Never>?
    private var pendingFrameBytes = 0
    private var liveGeneration = 0

    private func startLiveSync(host: String, wsPort: Int) {
        guard !isWorking, !isInBackground, liveSync?.isRunning != true else { return }
        stopLiveSync()
        let generation = liveGeneration
        let client = LiveSyncClient(host: host, wsPort: wsPort)
        client.onEvent = { [weak self] event in
            guard self?.liveGeneration == generation else { return }
            self?.handleLiveEvent(event)
        }
        liveSync = client
        client.start()
    }

    private func stopLiveSync() {
        liveGeneration += 1
        frameTask?.cancel()
        preferencesTask?.cancel()
        frameTask = nil
        preferencesTask = nil
        liveSync?.stop()
        liveSync = nil
        frameFetchPolicy.reset()
    }

    private func handleLiveEvent(_ event: LiveStudioEvent) {
        guard !isWorking, readerStatus != nil else { return }
        switch event {
        case let .status(status):
            guard readerStatus?.deviceID == nil || readerStatus?.deviceID == status.deviceID else {
                stopLiveSync()
                return
            }
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
        guard !isWorking, readerStatus != nil, bytes > 0 else { return }
        pendingFrameBytes = bytes
        if frameTask != nil {
            frameFetchPolicy.enqueue(seq: seq)
            return
        }
        _ = frameFetchPolicy.shouldFetch(seq: seq)
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        let generation = liveGeneration
        frameTask = Task {
            defer { if generation == liveGeneration { frameTask = nil } }
            var nextSeq = seq
            while !Task.isCancelled, generation == liveGeneration, attempt == connectionAttempt, !isWorking {
                if !frameFetchPolicy.inFlight {
                    do { try await Task.sleep(for: .seconds(frameFetchPolicy.delayUntilNextFetch())) }
                    catch { return }
                    guard !Task.isCancelled, generation == liveGeneration else { return }
                    nextSeq = frameFetchPolicy.pendingSeq ?? nextSeq
                    guard frameFetchPolicy.shouldFetch(seq: nextSeq) else { continue }
                }
                let expectedBytes = pendingFrameBytes
                do {
                    let data = try await client.screenLive(host: host, port: port, expectedBytes: expectedBytes)
                    guard !Task.isCancelled, generation == liveGeneration, attempt == connectionAttempt else { return }
                    readerScreenImageData = data
                    mirror.apply(.frame(seq: nextSeq, capturedAt: Date(), data: data))
                } catch {
                    guard !Task.isCancelled, generation == liveGeneration, attempt == connectionAttempt else { return }
                }
                guard let pending = frameFetchPolicy.fetchCompleted() else { return }
                nextSeq = pending
            }
        }
    }

    private func reloadPreferencesFromReader() {
        guard !isWorking, preferencesTask == nil else { return }
        let attempt = connectionAttempt
        let generation = liveGeneration
        preferencesTask = Task {
            defer { if generation == liveGeneration { preferencesTask = nil } }
            guard let loaded = try? await client.preferences(host: activeHost, port: activeHTTPPort),
                  !Task.isCancelled, generation == liveGeneration, attempt == connectionAttempt else { return }
            preferences = loaded
            preferencesDirty = false
            mirror.apply(.preferences(loaded))
        }
    }

    /// A transfer owns the reader connection until commit/apply finishes.
    /// Cancel AND drain existing requests before opening the upload socket.
    private func quiesceReaderTraffic() async {
        let frame = frameTask
        let prefs = preferencesTask
        let heartbeat = heartbeatTask
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopLiveSync()
        await frame?.value
        await prefs?.value
        await heartbeat?.value
    }

    private func resumeReaderTraffic(attempt: Int) {
        guard attempt == connectionAttempt, readerStatus != nil, !isDemoMode, !isInBackground else { return }
        // Let the next paced status poll observe the listener after its
        // transfer cooldown; never reconnect to a stale WS advertisement.
        startHeartbeat(host: activeHost, port: activeHTTPPort)
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

    @Published var readerStatus: CrossPointStatus? {
        didSet {
            // Never show another reader's (or a disconnected reader's) inputs.
            // Fetching happens inside the sequential reader lanes, not here.
            if readerDisplay != nil, readerDisplay?.deviceID != readerStatus?.deviceID || isDemoMode {
                readerDisplay = nil
            }
        }
    }
    /// Resolved content-page inputs of the connected reader; nil means previews
    /// use the labelled reference style (demo, offline or older firmware).
    @Published private(set) var readerDisplay: ReaderDisplayState?
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
    @Published private(set) var contentDeployment: ContentDeployment?
    @Published private(set) var contentRedrawReceipt: ContentActiveReceipt?
    private var contentDeploymentReaderID: String?
    private var activationJournal: ContentActivationJournal?
    @Published private(set) var activationRecordError: String?
    @Published private(set) var activationRecordBackup: URL?
    private var savedContentEditor: ContentEditorModel?
    private var savedThemeEditor: ThemeEditorModel?
    private var demoThemeEditor: ThemeEditorModel?

    func themeEditorModel() throws -> ThemeEditorModel {
        if isDemoMode {
            if let demoThemeEditor { return demoThemeEditor }
            let editor = ThemeEditorModel(store: nil)
            demoThemeEditor = editor
            return editor
        }
        if let savedThemeEditor { return savedThemeEditor }
#if DEBUG
        if let fixture = ProcessInfo.processInfo.environment["POCKET_UI_TEST_THEME_DRAFT_ID"],
           let id = UUID(uuidString: fixture) {
            let editor = ThemeEditorModel(store: ThemeDraftUITestStore(id: id))
            savedThemeEditor = editor
            return editor
        }
#endif
        let editor = ThemeEditorModel(store: try ThemeDraftStore.applicationStore())
        savedThemeEditor = editor
        return editor
    }

    /// One read-only GET inside an existing sequential reader lane (the reader
    /// serves one HTTP client at a time). nil = labelled reference preview.
    private func loadReaderDisplay(_ status: CrossPointStatus, host: String, port: Int) async -> ReaderDisplayState? {
        guard !isDemoMode, status.contentPresentation == true, let identity = status.deviceID else { return nil }
        return try? await client.readerDisplay(deviceID: identity, host: host, port: port)
    }

    func contentEditorModel() throws -> ContentEditorModel {
        // Demo gets an isolated in-memory session; its view never loads/saves.
        if !isDemoMode, let savedContentEditor { return savedContentEditor }
        #if DEBUG
        if !isDemoMode, let raw = ProcessInfo.processInfo.environment["POCKET_UI_TEST_CONTENT_FILES_ID"],
           let id = UUID(uuidString: raw) {
            let editor = ContentEditorModel(store: ContentDraftStore(file: ContentDraftUITestFiles.storeURL(id)))
            savedContentEditor = editor
            return editor
        }
        #endif
        let editor = ContentEditorModel(store: try ContentDraftStore.applicationStore(), isDemo: isDemoMode)
        if !isDemoMode { savedContentEditor = editor }
        return editor
    }

    private func contentJournal() throws -> ContentActivationJournal {
        if let activationJournal { return activationJournal }
        let journal = try ContentActivationJournal.applicationStore()
        activationJournal = journal
        return journal
    }

    private func loadContentIntent(_ journal: ContentActivationJournal) async throws -> PendingContentActivation? {
        do {
            let pending = try await journal.load()
            activationRecordError = nil
            return pending
        } catch {
            activationRecordError = error.localizedDescription
            throw error
        }
    }

    func restorePendingContentActivation() async {
        guard !isDemoMode, !isWorking, contentDeployment == nil else { return }
        do {
            let journal = try contentJournal()
            let pending = try await loadContentIntent(journal)
            guard !isDemoMode, !isWorking, contentDeployment == nil, let pending else { return }
            contentDeployment = ContentDeployment(restoring: pending, journal: journal)
            contentDeploymentReaderID = pending.deviceID
        } catch { post(error) }
    }

    private let client: CrossPointClient
    private let localFiles: LocalFileOperations
    // Bind each immutable revision to the selected session. Keeping this seam
    // at the I/O boundary lets the real Apply lifecycle run without a reader.
    typealias ContentTransportFactory = @MainActor (ContentRevision, String, String, Int) -> any ContentDeploymentTransport
    private let contentTransportFactory: ContentTransportFactory
    private let discoveryIO: any ReaderDiscoveryIO
    private let associationIO: any ReaderAssociationIO
    private var activeHost = "192.168.4.1"
    private var activeHTTPPort = 80
    private var heartbeatTask: Task<Void, Never>?
    private var connectionAttempt = 0
    private var nearbyLease: HotspotLease?
    private var readerWorkTask: Task<Void, Never>?
    private var readerWorkOwner: UUID?
    private enum ReaderWorkKind { case transfer, settings, preview, local, session, discovery, connection }
    private var readerWorkKind: ReaderWorkKind?
    private var isInBackground = false
    private var expectedDeviceID: String?
    @Published private(set) var directConnectionRequested = false
    @Published private(set) var preparedTransfers: [PreparedTransfer] = []
    var hasDirectSession: Bool { directConnectionRequested || nearbyLease != nil }
    var canPrepareFiles: Bool { !isDemoMode && !isWorking && !hasReaderWork && !isInBackground }
    var isTransferring: Bool { readerWorkTask != nil && readerWorkKind == .transfer }
    private var hasReaderWork: Bool { readerWorkTask != nil }
    private var canRequestConnection: Bool {
        !isInBackground && ((!isWorking && !hasReaderWork) || readerWorkKind == .connection)
    }

    func expectDirectReader(_ id: String) { expectedDeviceID = id }

    private var firmwareKey: String? {
        (readerStatus?.deviceID ?? expectedDeviceID).map { Self.stagedFirmwareVersionKey + "." + $0 }
    }


    init(discoveryIO: (any ReaderDiscoveryIO)? = nil, client: CrossPointClient = CrossPointClient(),
         activationJournal: ContentActivationJournal? = nil,
         contentTransportFactory: ContentTransportFactory? = nil,
         localFiles: LocalFileOperations = .init(),
         associationIO: (any ReaderAssociationIO)? = nil) {
        self.client = client
        self.localFiles = localFiles
        self.contentTransportFactory = contentTransportFactory ?? { revision, identity, host, port in
            ReaderContentTransport(target: revision, deviceID: identity, host: host, port: port, client: client)
        }
        self.associationIO = associationIO ?? SystemReaderAssociationIO()
        self.activationJournal = activationJournal
        var selectedDiscovery = discoveryIO
        #if DEBUG
        if selectedDiscovery == nil, ProcessInfo.processInfo.arguments.contains("--ui-test-empty-discovery") {
            selectedDiscovery = EmptyReaderDiscoveryIO()
        }
        #endif
        self.discoveryIO = selectedDiscovery ?? LiveReaderDiscoveryIO(client: client,
                                                                       rememberedHostKey: Self.lastReaderHostKey)
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
        guard !hasReaderWork, !isInBackground else { return }
        exitDemoMode()
        startVerification(host: "192.168.4.1", port: 80)
    }

    func startConnectionSearch() {
        guard !isWorking, !hasReaderWork, !hasDirectSession else { return }
        readerStatus = nil
        expectedDeviceID = nil
        nearbyLease = nil
        manualHotspotFallback = false
        locationPermissionRequired = false
        mirror.apply(.connection(.searching))
        findOnLocalNetwork()
    }

    func findOnLocalNetwork(retryIfMissing: Bool = true) {
        guard !isWorking, !hasReaderWork, !isInBackground else { return }
        exitDemoMode()
        if let nearbyLease {
            if manualHotspotFallback {
                useNearbyLease(nearbyLease)
            } else {
                startLeaseVerification(nearbyLease)
            }
            return
        }
        connectionAttempt += 1
        heartbeatTask?.cancel()
        let attempt = connectionAttempt
        startReaderWork(attempt: attempt, kind: .discovery) { [self] _ in
            await discoverReader(attempt: attempt, retryIfMissing: retryIfMissing)
        }
    }

    /// Both bounded passes belong to one operation, including Bonjour cleanup
    /// and retry delay. Never release admission between passes or on cancellation
    /// before the discovery provider has actually returned.
    private func discoverReader(attempt: Int, retryIfMissing: Bool) async {
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        let bonjourTask = Task { await discoveryIO.firstBonjour(timeout: .seconds(5)) }
        await withTaskCancellationHandler {
            await discoverReaderPass(attempt: attempt, retryIfMissing: retryIfMissing, bonjourTask: bonjourTask)
        } onCancel: { bonjourTask.cancel() }
        bonjourTask.cancel()
        discoveryIO.stop()
        _ = await bonjourTask.value
    }

    private func discoverReaderPass(attempt: Int, retryIfMissing: Bool,
                                    bonjourTask: Task<(host: String, port: Int)?, Never>) async {
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        post("Checking your current Wi-Fi without changing networks…")
        let lastHost = discoveryIO.rememberedHost
        if let lastHost, !lastHost.isEmpty,
           let status = try? await discoveryIO.status(host: lastHost, port: 80, timeout: 3) {
            guard !Task.isCancelled, attempt == connectionAttempt else { return }
            discoveryIO.stop()
            bonjourTask.cancel()
            await accept(status: status, host: lastHost, httpPort: 80)
            return
        }

        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        // Bonjour handles crosspoint.local separately. Keeping hostname DNS
        // resolution in this task group can delay cancellation even after a
        // nearby IP has already answered.
        var candidates = discoveryIO.candidates()
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
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
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
        var foundPort = 80
        if found == nil, let endpoint = await bonjourTask.value {
            guard !Task.isCancelled, attempt == connectionAttempt else { return }
            if let status = try? await discoveryIO.status(host: endpoint.host, port: endpoint.port, timeout: 3) {
                found = (endpoint.host, status)
                foundPort = endpoint.port
            }
        }
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        if let (host, status) = found {
            discoveryIO.stop()
            bonjourTask.cancel()
            await accept(status: status, host: host, httpPort: foundPort)
        } else if readerStatus == nil {
            guard !Task.isCancelled, attempt == connectionAttempt else { return }
            if retryIfMissing {
                // Sweep once more, and only once: a reader that finished joining
                // the network mid-scan is invisible to the first pass but answers
                // the second. Each pass is bounded by discoveryBudget, so the two
                // together still resolve in well under a minute.
                post("Reader not ready yet. Scanning once more…")
                // The retry delay belongs to this discovery operation.
                // Keep the same busy state and cancellation handle across
                // both passes; do not launch an orphan timer.
                do { try await Task.sleep(for: .milliseconds(800)) }
                catch { return }
                guard !Task.isCancelled, readerStatus == nil,
                      attempt == connectionAttempt else { return }
                bonjourTask.cancel()
                discoveryIO.stop()
                _ = await bonjourTask.value
                await discoverReader(attempt: attempt, retryIfMissing: false)
            } else {
                post("No Pocket reader was visible. Open Pocket Daily → Sync → Same Wi-Fi on the reader (Join a Network on older firmware). Without a router, choose Direct connection on the reader and Connect directly here.", tone: .failure)
            }
        }
    }

    func enterDemoMode() {
        guard !isWorking, !hasReaderWork, !hasDirectSession else { return }
        connectionAttempt += 1
        heartbeatTask?.cancel()
        discoveryIO.stop()
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
        let discoveryIO = self.discoveryIO
        return await withTaskGroup(of: (String, CrossPointStatus)?.self) { group in
            var next = 0
            while next < hosts.count, next < concurrency {
                let host = hosts[next]
                group.addTask {
                    guard let status = try? await discoveryIO.status(host: host, port: 80, timeout: timeout) else {
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
                    guard let status = try? await discoveryIO.status(host: host, port: 80, timeout: timeout) else {
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
        guard canRequestConnection, directConnectionRequested else { return }
        connectionAttempt += 1
        heartbeatTask?.cancel()
        discoveryIO.stop()
        nearbyLease = lease
        manualHotspotFallback = false
        locationPermissionRequired = false
        readerStatus = nil
        preferences = nil
        let attempt = connectionAttempt
        startReaderWork(attempt: attempt, kind: .connection) { [self] _ in
            do {
                try await associationIO.join(lease)
                guard !Task.isCancelled, attempt == connectionAttempt else {
                    // A replacement cannot start until this cleanup returns,
                    // even when both requests name the same SSID.
                    await associationIO.leave(ssid: lease.ssid)
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
        guard let task = startLeaseVerification(lease) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    @discardableResult
    private func startLeaseVerification(_ lease: HotspotLease) -> Task<Void, Never>? {
        guard canRequestConnection, directConnectionRequested else { return nil }
        connectionAttempt += 1
        heartbeatTask?.cancel()
        nearbyLease = lease
        let attempt = connectionAttempt
        return startReaderWork(attempt: attempt, kind: .connection) { [self] _ in
            await waitForReader(lease)
        }
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
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        readerStatus = nil
        preferences = nil
        nearbyLease = lease
        manualHotspotFallback = true
        stopLiveSync()
        mirror.apply(.connection(.disconnected))
        post("Private link not ready. Join \(lease.ssid), then tap Verify connection.", tone: .failure)
    }

    func verify(host: String, port: Int) async {
        guard let task = startVerification(host: host, port: port) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    @discardableResult
    private func startVerification(host: String, port: Int) -> Task<Void, Never>? {
        guard canRequestConnection else { return nil }
        connectionAttempt += 1
        let attempt = connectionAttempt
        return startReaderWork(attempt: attempt, kind: .connection) { [self] _ in
            do {
                let status = try await client.status(host: host, port: port)
                guard !Task.isCancelled, attempt == connectionAttempt else { return }
                await accept(status: status, host: host, httpPort: port)
            } catch {
                guard !Task.isCancelled, attempt == connectionAttempt else { return }
                readerStatus = nil
                preferences = nil
                readerScreenImageData = nil
                stopLiveSync()
                mirror.apply(.connection(.disconnected))
                post("Reader not found. Open Create Hotspot on the reader and try again.", tone: .failure)
            }
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
        // Accepting a session is not a heartbeat refresh. Clear both view
        // surfaces before awaiting the new reader's optional data, including
        // for legacy readers whose nil identities cannot distinguish devices.
        preferences = nil
        preferencesDirty = false
        readerScreenImageData = nil
        crashDiagnostic = nil
        readerStatus = status
        mirror.apply(.sessionStarted(status))
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
        let loadedDisplay = await loadReaderDisplay(status, host: host, port: httpPort)
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        readerDisplay = loadedDisplay
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
            post("Connected to \(status.device). This session does not provide screen capture; content and theme controls use the reader's advertised capabilities.")
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
                      !self.isInBackground,
                      attempt == self.connectionAttempt,
                      self.readerStatus != nil else { return }
                if self.isWorking { continue }

                do {
                    let status = try await self.client.status(host: host, port: port, timeout: 6)
                    guard !Task.isCancelled, attempt == self.connectionAttempt else { return }
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
                    if case let .push(wsPort) = SyncModePolicy.syncMode(status: status, isDemoMode: false) {
                        self.startLiveSync(host: host, wsPort: wsPort)
                    } else {
                        self.stopLiveSync()
                    }
                } catch {
                    guard !Task.isCancelled, attempt == self.connectionAttempt else { return }
                    guard heartbeat.recordFailure() else { continue }
                    self.readerStatus = nil
                    self.preferences = nil
                    self.readerScreenImageData = nil
                    self.preferencesDirty = false
                    self.stopLiveSync()
                    self.mirror.apply(.connection(.disconnected))
                    self.post("Pocket connection ended. Check the reader’s Sync screen, then reconnect using the same connection method.", tone: .failure)
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
        guard !isDemoMode, !isWorking, !hasReaderWork, !isInBackground, readerStatus != nil else { return }
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        startReaderWork(attempt: attempt, kind: .preview) { [self] owner in
            do {
                let status = try await client.status(host: host, port: port)
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                guard status.deviceID == readerStatus?.deviceID,
                      status.screenPreviewAvailable == true,
                      ReaderDiagnosticsPolicy.canFetchDiagnostics(freeHeap: status.freeHeap,
                                                                 readerSaysAffordable: status.diagnosticsAffordable),
                      let bytes = status.screenPreviewBytes else {
                    post("A preview is unavailable in this reader profile or memory state.")
                    return
                }
                let data = try await client.screenPreview(host: host, port: port, expectedBytes: bytes)
                guard ownsReaderWork(owner, attempt: attempt) else { return }
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
        guard !isWorking, !hasReaderWork, !isInBackground, readerStatus != nil, let preferences else { return }
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        startReaderWork(attempt: attempt, kind: .settings) { [self] owner in
            do {
                try await client.save(preferences: preferences, host: host, port: port)
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                preferencesDirty = self.preferences != preferences
                post("Settings were applied to \(hardware.rawValue).", tone: .success)
            } catch {
                guard !Task.isCancelled, attempt == connectionAttempt else { return }
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
        post("Preparing an offline copy before transfer…")
        startReaderWork(attempt: connectionAttempt, kind: .local) { [self] _ in
            do {
                let item = try await localFiles.prepare(url)
                // A completed file receipt must survive background cancellation:
                // the detached file-provider operation may already have committed.
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
        guard !isDemoMode, !isWorking, !hasReaderWork, !isInBackground,
              let expectedStatus = readerStatus, !preparedTransfers.isEmpty else { return }
        let host = activeHost
        let port = activeHTTPPort
        let key = firmwareKey
        let attempt = connectionAttempt
        startReaderWork(attempt: attempt) { [self] owner in
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
                        uploadStreamWindow: status.uploadStreamWindow,
                        expectedDeviceID: status.deviceID,
                        transferID: status.deviceID == nil ? UUID() : item.id,
                        note: { [weak self] text in Task { @MainActor in
                            guard let self, self.ownsReaderWork(owner, attempt: attempt) else { return }
                            self.post(text)
                        } },
                        reconnect: { [weak self] in await self?.reconnectForTransfer(owner: owner, attempt: attempt) ?? false }
                    ) { [weak self] sent, total in
                        Task { @MainActor in
                            guard let self, self.ownsReaderWork(owner, attempt: attempt) else { return }
                            let progress = total > 0 ? Double(sent) / Double(total) : 0
                            self.uploadProgress = progress
                            self.mirror.apply(.transferProgress(progress))
                        }
                    }
                    guard ownsReaderWork(owner, attempt: attempt) else { return }
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
                guard attempt == connectionAttempt else { return }
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
        guard !isWorking, !hasReaderWork, !isDemoMode, readerStatus == nil else { return }
        connectionAttempt += 1
        heartbeatTask?.cancel()
        discoveryIO.stop()
        directConnectionRequested = true
        mirror.apply(.connection(.waitingForReader))
        post("On the reader, open Pocket Daily → Sync → Direct connection (Nearby Sync on older firmware). Keep this app open during direct transfer.")
    }

    /// BLE failed before handing over a lease. There is no Wi-Fi association
    /// to tear down; revoke only this pending request so LAN discovery and a
    /// new explicit direct attempt are available again. Late BLE events must
    /// never disturb a handed-off or connected session.
    func directDiscoveryFailed(_ message: String) {
        guard directConnectionRequested, nearbyLease == nil, readerStatus == nil,
              !isWorking, !hasReaderWork else { return }
        directConnectionRequested = false
        expectedDeviceID = nil
        mirror.apply(.connection(.disconnected))
        post(message, tone: .failure)
    }

    func endConnection() {
        guard !isWorking, !hasReaderWork else { return }
        startReaderWork(attempt: connectionAttempt, kind: .session) { [self] _ in
            await finishConnection(preserveMessage: false)
        }
    }

    func pauseTransfer() { if isTransferring { readerWorkTask?.cancel() } }

    /// One exclusive lane for device work and local file/session operations.
    /// Cancellation retains ownership until the underlying I/O has drained.
    /// A connection generation alone cannot identify two operations in the
    /// same session, so delayed callbacks also carry an operation token.
    @discardableResult
    private func startReaderWork(attempt: Int, kind: ReaderWorkKind = .transfer,
                                 operation: @escaping @MainActor (UUID) async -> Void) -> Task<Void, Never>? {
        let previous = readerWorkTask
        if previous != nil {
            // Only an explicit connection request can supersede another one.
            // Transfers, discovery and local file work cannot be displaced.
            guard kind == .connection, readerWorkKind == .connection else { return nil }
            previous?.cancel()
        }
        let owner = UUID()
        readerWorkOwner = owner
        readerWorkKind = kind
        isWorking = true
        readerWorkTask = Task {
            defer { finishReaderWork(owner: owner, attempt: attempt) }
            // Replacement reserves the lane immediately, but must drain every
            // predecessor (including non-cancellable OS association/cleanup).
            await previous?.value
            guard ownsReaderWork(owner, attempt: attempt) else { return }
            if kind != .local { await quiesceReaderTraffic() }
            guard ownsReaderWork(owner, attempt: attempt) else { return }
            await operation(owner)
        }
        return readerWorkTask
    }

    private func ownsReaderWork(_ owner: UUID, attempt: Int) -> Bool {
        readerWorkOwner == owner && connectionAttempt == attempt && !isInBackground
            && readerWorkTask?.isCancelled == false
    }

    private func finishReaderWork(owner: UUID, attempt: Int) {
        guard readerWorkOwner == owner else { return }
        let resumeTraffic = readerWorkKind != .local
        readerWorkOwner = nil
        readerWorkKind = nil
        readerWorkTask = nil
        isWorking = false
        if resumeTraffic { resumeReaderTraffic(attempt: attempt) }
    }

    private func performLocalWork(_ operation: @escaping @MainActor () async -> Void) async {
        guard let task = startReaderWork(attempt: connectionAttempt, kind: .local, operation: { _ in
            await operation()
        }) else { return }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Restore monitoring only for the already-selected LAN reader. This does
    /// not discover devices, join Wi-Fi, resend files, or resume a direct lease.
    func resumeForForeground() {
        guard isInBackground else { return }
        isInBackground = false
        guard !isDemoMode, !hasDirectSession, readerStatus != nil else { return }
        startHeartbeat(host: activeHost, port: activeHTTPPort)
    }

    func pauseForBackground() {
        isInBackground = true
        readerWorkTask?.cancel()
        // joinOnce is released by iOS while in the background. Never rejoin there.
        connectionAttempt += 1
        heartbeatTask?.cancel()
        discoveryIO.stop()
        stopLiveSync()
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
        heartbeatTask?.cancel()
        discoveryIO.stop()
        let legacyDirectSession = nearbyLease != nil && readerStatus?.sessionEnd != true
        var readerEnded = true
        if nearbyLease != nil, readerStatus?.sessionEnd == true {
            do { try await client.endDirectSession(host: activeHost, port: activeHTTPPort) }
            catch { readerEnded = false }
        }
        if let lease = nearbyLease { await associationIO.leave(ssid: lease.ssid) }
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
    private func reconnectForTransfer(owner: UUID, attempt: Int) async -> Bool {
        guard !Task.isCancelled, ownsReaderWork(owner, attempt: attempt), let lease = nearbyLease else { return false }
        post("Private link dropped. Rejoining \(lease.ssid)…")
        do {
            try await associationIO.join(lease)
        } catch {
            return false
        }
        let deadline = ContinuousClock.now + .seconds(18)
        while ContinuousClock.now < deadline {
            guard !Task.isCancelled, ownsReaderWork(owner, attempt: attempt) else { return false }
            if let status = try? await client.status(host: lease.host, port: lease.httpPort, timeout: 3) {
                guard !Task.isCancelled, ownsReaderWork(owner, attempt: attempt) else { return false }
                if let expectedDeviceID, let actual = status.deviceID, actual != expectedDeviceID { return false }
                return true
            }
            try? await Task.sleep(for: .milliseconds(500))
        }
        return false
    }

    func copyToSD(_ source: URL, root: URL) {
        guard canPrepareFiles else { return }
        startReaderWork(attempt: connectionAttempt, kind: .local) { [self] _ in
            do {
                let result = try await localFiles.copy(source, root)
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
        case "uipack": "/pocket-daily/ui-packs"
        default: "/"
        }
    }

    /// Explicit content apply uses the app's existing exclusive transfer lane.
    /// Saving/editing a draft never calls this method automatically.
    struct ContentEditingSession: Equatable {
        let generation: Int
        let deviceID: String
    }

    var contentEditingSession: ContentEditingSession? {
        guard !isDemoMode, !isInBackground, readerStatus?.contentPresentation == true,
              let identity = readerStatus?.deviceID, identity.utf8.count == 8,
              identity.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else { return nil }
        return .init(generation: connectionAttempt, deviceID: identity)
    }

    /// One explicitly authorized editing session. Never reconnects or flashes.
    func applyLiveContent(_ revision: ContentRevision, session: ContentEditingSession) async -> Bool {
        guard !Task.isCancelled, contentEditingSession == session,
              let operation = applyContent(revision) else { return false }
        await withTaskCancellationHandler {
            await operation.value
        } onCancel: { operation.cancel() }
        guard !Task.isCancelled, contentEditingSession == session,
              case let .complete(active) = contentDeployment?.phase,
              active.revision == revision.revision, contentRedrawReceipt == active else { return false }
        return true
    }

    @discardableResult
    func applyContent(_ revision: ContentRevision) -> Task<Void, Never>? {
        guard !isWorking, !hasReaderWork else { return nil }
        guard !isDemoMode, !isInBackground, let status = readerStatus else {
            post(isDemoMode ? "Demo mode does not change a reader." : "Connect to a reader before applying content.")
            return nil
        }
        guard let identity = status.deviceID, identity.utf8.count == 8,
              identity.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              PocketHardware(deviceName: status.device) != nil,
              let streamPort = status.uploadStreamPort, (1...65535).contains(streamPort) else {
            post("This reader must report its identity and support verified content transfer.")
            return nil
        }
        let attempt = connectionAttempt
        let host = activeHost
        let port = activeHTTPPort
        let transport = contentTransportFactory(revision, identity, host, port)
        let journal: ContentActivationJournal
        do { journal = try contentJournal() }
        catch { post(error); return nil }
        let deployment = ContentDeployment(deviceID: identity, transport: transport, journal: journal)
        contentDeployment = deployment
        contentRedrawReceipt = nil
        contentDeploymentReaderID = identity
        uploadProgress = 0
        post("Verifying the reader before applying content…")
        return startReaderWork(attempt: attempt) { [self] owner in
            do {
                try Task.checkCancellation()
                guard attempt == connectionAttempt else { return }
                if let pending = try await loadContentIntent(journal) {
                    guard attempt == connectionAttempt else { return }
                    contentDeployment = ContentDeployment(restoring: pending, journal: journal)
                    contentDeploymentReaderID = pending.deviceID
                    post("A previous content activation needs confirmation. Check its outcome; nothing was resent.")
                    return
                }
                try Task.checkCancellation()
                let active = try await deployment.deploy(revision)
                guard attempt == connectionAttempt else { return }
                if status.contentPresentation == true {
                    do {
                        try await ContentPresenter.present(deviceID: identity, active: active, using: .init(
                            request: { try await self.client.presentContent(active, deviceID: identity, host: host, port: port) },
                            state: { try await self.client.contentPresentation(active, deviceID: identity, host: host, port: port) }
                        ))
                        guard attempt == connectionAttempt else { return }
                        contentRedrawReceipt = active
                        post("Content activated. The reader reported a completed redraw.", tone: .success)
                    } catch {
                        guard attempt == connectionAttempt else { return }
                        post("Content storage activation is confirmed, but the redraw is not. Nothing was resent. \(error.localizedDescription)", tone: .pending)
                    }
                } else {
                    post("Content storage activation confirmed. The reader loads it when Pocket opens; screen display is not yet confirmed.",
                         tone: .success)
                }
            } catch {
                guard attempt == connectionAttempt else { return }
                if deployment.failurePhase == .checking,
                   let networkError = error as? URLError,
                   [.timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost,
                    .notConnectedToInternet].contains(networkError.code) {
                    // The first read failed, before any staging or activation.
                    // Do not leave an old status authorizing another Apply.
                    readerStatus = nil
                    preferences = nil
                    preferencesDirty = false
                    readerScreenImageData = nil
                    stopLiveSync()
                    mirror.apply(.connection(.disconnected))
                    post("The reader did not respond. No content was sent; your draft is unchanged. Check the reader, then reconnect using the same connection method.", tone: .failure)
                    return
                }
                if deployment.phase == .needsConfirmation {
                    post("Content activation could not be confirmed. It may have completed; check the reader state before applying again.")
                } else if error is CancellationError {
                    post("Content transfer cancelled before activation.")
                } else {
                    post(error)
                }
            }
        }
    }

    /// Read-only resolution on the currently selected address of the original
    /// reader. No rediscovery, network switch, upload or activation retry.
    func confirmContentActivation() {
        guard !isWorking, !hasReaderWork, !isDemoMode, !isInBackground,
              let deployment = contentDeployment, deployment.phase == .needsConfirmation else { return }
        guard let identity = contentDeploymentReaderID, readerStatus?.deviceID == identity else {
            post("Select the same reader before checking its content activation.")
            return
        }
        let attempt = connectionAttempt
        let host = activeHost
        let port = activeHTTPPort
        startReaderWork(attempt: attempt) { [self] owner in
            do {
                try Task.checkCancellation()
                guard attempt == connectionAttempt else { return }
                _ = try await deployment.confirmPendingActivation {
                    try await self.client.contentState(deviceID: identity, host: host, port: port)
                }
                guard attempt == connectionAttempt else { return }
                post("Content storage activation confirmed. Screen display is not yet confirmed.", tone: .success)
            } catch {
                guard attempt == connectionAttempt else { return }
                post("Content activation remains unconfirmed. No content was resent. \(error.localizedDescription)")
            }
        }
    }

    /// Explicitly confirmed local-only action. Does not undo reader activation.
    func archivePendingContentActivation() async {
        guard canPrepareFiles,
              let deployment = contentDeployment, deployment.phase == .needsConfirmation else { return }
        await performLocalWork { [self] in
            do {
                try await deployment.archivePendingActivation()
                post("Pending check archived locally. The reader may still have applied the content; no reader changes were requested.")
            } catch { post(error) }
        }
    }

    /// Confirmed local recovery only; it cannot discard a valid pending intent.
    func recoverContentActivationRecord() async {
        guard canPrepareFiles, activationRecordError != nil else { return }
        await performLocalWork { [self] in
            do {
                activationRecordBackup = try await contentJournal().recoverUnreadableRecord()
                activationRecordError = nil
                contentDeployment = nil
                contentDeploymentReaderID = nil
                post("Unreadable activation record preserved and local tracking reset. No reader changes were requested.")
            } catch { post(error) }
        }
    }

    /// Live Studio M3: encode a theme pack, ship it, and apply it live. The
    /// reader reports the exact activated version before success is shown.
    /// A lost response leaves the outcome unknown, not necessarily reverted.
    func applyThemePack(_ theme: [String: Int]) {
        guard !isDemoMode, !isWorking, !hasReaderWork, !isInBackground,
              readerStatus?.liveStudio?.uiPacks == true, let status = readerStatus else {
            post(readerStatus == nil ? "Connect to a reader to apply theme packs." :
                  isDemoMode ? "Demo preview does not change a reader." :
                  "This reader's firmware does not support UI packs yet.")
            return
        }
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        startReaderWork(attempt: attempt) { [self] owner in
            do {
                let identity = try UiPackVerification.identity(status.deviceID)
                let version = Self.packTimestamp()
                // Preserve the active pack file until the new revision is verified.
                let name = "studio-" + version
                let pack = try UiPackEncoder.encode(name: name, version: version, theme: theme)
                let folder = FileManager.default.temporaryDirectory
                    .appendingPathComponent("pocket-packs", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(name + ".uipack")
                try pack.write(to: url, options: .atomic)
                try Task.checkCancellation()
                guard attempt == connectionAttempt else { return }
                _ = try await client.uploadAtomically(
                    fileURL: url, publishedFilename: nil, destination: "/pocket-daily/ui-packs",
                    host: host, port: port,
                    uploadChunkBytes: status.uploadChunkBytes, uploadStreamPort: status.uploadStreamPort,
                    uploadStreamResume: status.uploadStreamResume ?? false,
                    uploadStreamWindow: status.uploadStreamWindow,
                    expectedDeviceID: status.deviceID,
                    transferID: status.deviceID.flatMap { UUID(uuidString: $0) } ?? UUID(),
                    note: { [weak self] text in Task { @MainActor in
                        guard let self, self.ownsReaderWork(owner, attempt: attempt) else { return }
                        self.post(text)
                    } },
                    reconnect: { [weak self] in await self?.reconnectForTransfer(owner: owner, attempt: attempt) ?? false }
                ) { _, _ in }
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                try await client.applyUiPack(name: name, host: host, port: port)
                guard attempt == connectionAttempt else { return }
                let refreshed = try await confirmedPackStatus(host: host, port: port, identity: identity,
                                                              name: name, version: version)
                guard attempt == connectionAttempt else { return }
                readerStatus = refreshed
                mirror.apply(.status(refreshed))
                mirror.apply(.packStateChanged(activePack: refreshed.liveStudio?.activePack,
                                               version: refreshed.liveStudio?.activePackVersion))
                // Pack metrics change the content page; re-read resolved inputs.
                let display = await loadReaderDisplay(refreshed, host: host, port: port)
                guard attempt == connectionAttempt else { return }
                readerDisplay = display
                post("Theme pack activation confirmed by the reader.", tone: .success)
            } catch {
                guard attempt == connectionAttempt else { return }
                post(error)
            }
        }
    }

    func revertThemePack() {
        guard !isDemoMode, !isWorking, !hasReaderWork, !isInBackground,
              readerStatus?.liveStudio?.uiPacks == true, let status = readerStatus else {
            post("Connect to a pack-capable reader to revert.")
            return
        }
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        startReaderWork(attempt: attempt) { [self] owner in
            do {
                let identity = try UiPackVerification.identity(status.deviceID)
                try Task.checkCancellation()
                try await client.applyUiPack(name: "", host: host, port: port)
                guard attempt == connectionAttempt else { return }
                let refreshed = try await confirmedPackStatus(host: host, port: port, identity: identity,
                                                              name: nil, version: nil)
                guard attempt == connectionAttempt else { return }
                readerStatus = refreshed
                mirror.apply(.status(refreshed))
                mirror.apply(.packStateChanged(activePack: nil, version: nil))
                let display = await loadReaderDisplay(refreshed, host: host, port: port)
                guard attempt == connectionAttempt else { return }
                readerDisplay = display
                post("Reader reverted to its theme's own metrics.", tone: .success)
            } catch {
                guard attempt == connectionAttempt else { return }
                post(error)
            }
        }
    }

    private static func packTimestamp() -> String {
        // Fixed-width ASCII; two deployments within one second must differ.
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)).lowercased()
    }

    private func confirmedPackStatus(host: String, port: Int, identity: String,
                                     name: String?, version: String?) async throws -> CrossPointStatus {
        let refreshed: CrossPointStatus
        do {
            refreshed = try await client.status(host: host, port: port)
        } catch {
            try Task.checkCancellation()
            throw UiPackVerification.Failure.notConfirmed
        }
        try Task.checkCancellation()
        try UiPackVerification.validate(refreshed, expectedDeviceID: identity, name: name, version: version)
        return refreshed
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
