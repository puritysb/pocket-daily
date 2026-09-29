import Combine
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
    /// Stopped or unconfirmed partway; the message says what to check.
    case pending
    /// Nothing is wrong: the next step happens on the reader (for example,
    /// installing a firmware update that was just sent).
    case onReader
    case failure
}

struct SDCopyResult: Equatable, Sendable {
    let path: String
    let firmwareVersion: String?
}

enum TransferKind: String, CaseIterable, Sendable {
    case content, firmware
    var title: String { self == .content ? "Content · SD card" : "Firmware update" }
}

struct PreparedTransfer: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let filename: String
    let firmwareVersion: String?
    var readerID: String?
    /// Persisted before opening the stream, including readers without resume support.
    var remoteStagingID: UUID? = nil
    /// Write-ahead marker: a missing commit response must not cause blind republication.
    var publicationPending: Bool? = nil
    var stagingID: UUID? { remoteStagingID ?? (readerID == nil ? nil : id) }
    var kind: TransferKind { filename.lowercased().hasSuffix(".bin") ? .firmware : .content }
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
    /// Official firmware release lookup and download (tests substitute both).
    struct ReleaseOperations: Sendable {
        var latest: @Sendable () async throws -> FirmwareRelease = { try await FirmwareReleaseSource.latest() }
        var download: @Sendable (FirmwareRelease, URL) async throws -> URL = { release, directory in
            try await FirmwareReleaseSource.download(release, into: directory)
        }
        /// Must match what `latest` looks up.
        var channel: FirmwareReleaseSource.Channel = .current
    }
    static let initialMessage = "Prepare files, then find the reader on your Wi-Fi or connect directly when away."

    /// Studio-facing snapshot fed from this session's transitions. Views read
    /// the legacy published fields until they migrate onto the mirror.
    let mirror = DeviceMirror()
    var syncMode: DeviceSyncMode { SyncModePolicy.syncMode(status: readerStatus, isDemoMode: isDemoMode) }

    private var liveSync: LiveSyncClient?
    private var preferencesTask: Task<Void, Never>?
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
        preferencesTask?.cancel()
        preferencesTask = nil
        liveSync?.stop()
        liveSync = nil
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
        case .prefsChanged:
            reloadPreferencesFromReader()
        case .frame, .hello, .bye:
            // Frames are not fetched: no view shows them, and each fetch costs
            // the reader a 50+ KB transfer.
            break
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
            preferencesBaseline = loaded
            preferencesDirty = false
            mirror.apply(.preferences(loaded))
        }
    }

    /// A transfer owns the reader connection until commit/apply finishes.
    /// Cancel AND drain existing requests before opening the upload socket.
    private func quiesceReaderTraffic() async {
        let prefs = preferencesTask
        let heartbeat = heartbeatTask
        heartbeatTask?.cancel()
        heartbeatTask = nil
        stopLiveSync()
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
    private static let lastReaderDeviceIDKey = "Pocket.lastReaderDeviceID"
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
            if readerProfile != nil, readerProfile?.deviceID != readerStatus?.deviceID || isDemoMode {
                readerProfile = nil
                profileSend = .idle
                screenShow = .idle
            }
            if oldValue?.deviceID != readerStatus?.deviceID || readerStatus == nil { loadedContentRevision = nil }
        }
    }
    /// Resolved content-page inputs of the connected reader; nil means previews
    /// use the labelled reference style (demo, offline or older firmware).
    @Published private(set) var readerDisplay: ReaderDisplayState?
    /// The connected reader's stored Pocket Daily profile (nil: not loaded,
    /// unsupported firmware, demo or offline).
    @Published private(set) var readerProfile: ReaderProfileState?
    /// The reader's active card revision as last read or sent ("" = no cards,
    /// nil = unknown), so Home & Sleep knows whether My cards need sending.
    @Published private(set) var loadedContentRevision: String?
    var readerContentRevision: String? {
        if case let .complete(active)? = contentDeployment?.phase { return active.revision }
        return loadedContentRevision
    }
    enum ProfileSendState: Equatable { case idle, sending, saved(UInt32), failed(String), conflict }
    /// Drawing a saved Home or Daily Brief on the reader inside Sync.
    enum ScreenShowState: Equatable {
        case idle
        case showing(ReaderScreen)
        case shown(ReaderScreen, generation: UInt32)
        case failed(ReaderScreen, String)
    }
    @Published private(set) var screenShow: ScreenShowState = .idle

    /// The reader can draw its saved Home and Daily Brief without leaving Sync.
    var canShowScreens: Bool { canEditReaderProfile && readerStatus?.screenPresentation == 1 }
    @Published private(set) var profileSend: ProfileSendState = .idle
    @Published private(set) var message = PocketModel.initialMessage
    @Published private(set) var messageTone: StatusTone = .neutral
    @Published var isWorking = false
    @Published var uploadProgress: Double = 0
    @Published var preferences: ReaderPreferences? {
        didSet { if preferences == nil { preferencesBaseline = nil } }
    }
    /// The reader's settings as last loaded or saved; Revert returns to them.
    private var preferencesBaseline: ReaderPreferences?
    @Published var crashDiagnostic: CrashDiagnostic?
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

    /// Profile-capable, identified, foreground, non-demo session.
    var canEditReaderProfile: Bool {
        !isDemoMode && !isInBackground && readerStatus?.pocketProfile == 1 && readerStatus?.deviceID != nil
    }

    /// Sends the whole profile once in the exclusive reader lane. A 409 means
    /// the reader changed it meanwhile: reload, never retry blindly.
    func sendProfile(_ profile: PocketProfile) {
        guard canEditReaderProfile, !isWorking, !hasReaderWork, profile.validationError == nil,
              let identity = readerStatus?.deviceID else { return }
        let generation = readerProfile?.generation ?? 0
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        profileSend = .sending
        let started = startReaderWork(attempt: attempt, kind: .settings) { [self] owner in
            do {
                let saved = try await client.saveReaderProfile(profile, generation: generation, deviceID: identity,
                                                               host: host, port: port)
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                readerProfile = saved
                profileSend = .saved(saved.generation)
                post("Home & Sleep saved on the reader. They show when you leave Sync.",
                     tone: .success)
            } catch CrossPointClient.ProfileRequestError.conflict {
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                readerProfile = try? await client.readerProfile(deviceID: identity, host: host, port: port)
                profileSend = .conflict
                post(CrossPointClient.ProfileRequestError.conflict)
            } catch {
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                profileSend = .failed(error.localizedDescription)
                post(error)
            }
        }
        if started == nil { profileSend = .idle }
    }

    /// Home & Sleep's single Apply: the profile and reader settings in one reader
    /// work item, then My cards through the content lane once those succeeded.
    /// Each part is sent only when it changed; nothing is retried. `show` is the
    /// screen being edited: when the reader can draw screens inside Sync, it
    /// draws that one afterwards (and cards are not drawn separately, since
    /// the screen shows them).
    private var lastQuietExchange = Date.distantPast

    /// Exchanges reading positions with the last connected reader when it already
    /// answers at its last address on the current Wi-Fi. No session is started,
    /// no network is joined or scanned, and nothing is shown unless the exchange
    /// itself fails. Only the same reader (device ID) qualifies, so a legacy or
    /// different reader at that address is left alone.
    func quietReadingExchange(minimumInterval: TimeInterval = 30,
                              prepare: @escaping @MainActor (ReaderReadingList, String) -> [PositionRecord],
                              finish: @escaping @MainActor (String, Int, Error?) -> Void) {
        guard !isDemoMode, !isInBackground, readerStatus == nil, !hasReaderWork, !isWorking,
              !hasDirectSession, readerWorkTask == nil,
              Date().timeIntervalSince(lastQuietExchange) >= minimumInterval,
              let host = discoveryIO.rememberedHost, !host.isEmpty,
              let identity = UserDefaults.standard.string(forKey: Self.lastReaderDeviceIDKey) else { return }
        lastQuietExchange = Date()
        let attempt = connectionAttempt
        startReaderWork(attempt: attempt, kind: .quietReading) { [self] owner in
            // A reader that is reading, asleep or elsewhere simply does not answer.
            guard let status = try? await discoveryIO.status(host: host, port: 80, timeout: 1.5),
                  status.readingProgress == 1, status.deviceID == identity,
                  ownsReaderWork(owner, attempt: attempt), !isDemoMode else { return }
            var sent = 0
            do {
                let list = try await client.readingProgress(identity: identity, host: host, port: 80)
                guard ownsReaderWork(owner, attempt: attempt), !isDemoMode else { return }
                for record in prepare(list, status.device).prefix(10) {
                    guard ownsReaderWork(owner, attempt: attempt), !isDemoMode else { return }
                    try await client.offerReadingProgress(record, identity: identity, host: host, port: 80)
                    guard ownsReaderWork(owner, attempt: attempt), !isDemoMode else { return }
                    sent += 1
                }
                finish(status.device, sent, nil)
            } catch {
                if ownsReaderWork(owner, attempt: attempt), !isDemoMode, !(error is CancellationError) {
                    finish(status.device, sent, error)
                }
            }
        }
    }

    var canExchangeReadingPositions: Bool {
        !isDemoMode && readerStatus?.readingProgress == 1 && readerStatus?.deviceID != nil
    }

    /// Exchanges reading positions with a reader that offers reading-progress v1:
    /// once per connection after it succeeds, retried a few times with a delay
    /// after a failure, or again whenever `force` is set by the user. Never
    /// blocks the session; the outcome goes to `finish`.
    func exchangeReadingPositions(force: Bool = false,
                                  prepare: @escaping @MainActor (ReaderReadingList, String) -> [PositionRecord],
                                  finish: @escaping @MainActor (String, Int, Error?) -> Void) {
        guard !isDemoMode, !isWorking, !hasReaderWork, !isInBackground, let status = readerStatus,
              status.readingProgress == 1, let identity = status.deviceID else { return }
        if readingExchange.attempt != connectionAttempt { readingExchange = .init(attempt: connectionAttempt) }
        guard force || (!readingExchange.done && readingExchange.failures < 3 && Date() >= readingExchange.retryAfter) else {
            return
        }
        let attempt = connectionAttempt, host = activeHost, port = activeHTTPPort
        startReaderWork(attempt: attempt, kind: .settings) { [self] owner in
            var sent = 0
            do {
                let list = try await client.readingProgress(identity: identity, host: host, port: port)
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                for record in prepare(list, status.device).prefix(10) {
                    try await client.offerReadingProgress(record, identity: identity, host: host, port: port)
                    sent += 1
                    guard ownsReaderWork(owner, attempt: attempt) else { return }
                }
                readingExchange.done = true
                finish(status.device, sent, nil)
            } catch {
                guard readingExchange.attempt == attempt, !(error is CancellationError) else { return }
                readingExchange.failures += 1
                let delay = 10.0 * Double(readingExchange.failures)
                readingExchange.retryAfter = Date().addingTimeInterval(delay)
                finish(status.device, sent, error)
                if readingExchange.failures < 3 {
                    Task { [weak self] in
                        try? await Task.sleep(for: .seconds(delay))
                        self?.exchangeReadingPositions(prepare: prepare, finish: finish)
                    }
                }
            }
        }
    }

    func sendReaderLayout(profile: PocketProfile?, cards: ContentRevision?, show: ReaderScreen? = nil) {
        guard !isDemoMode, !isWorking, !hasReaderWork, !isInBackground, readerStatus != nil else { return }
        let settings = preferencesDirty ? preferences : nil
        let profile = canEditReaderProfile ? profile : nil
        guard profile != nil || settings != nil || cards != nil else { return }
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        let identity = readerStatus?.deviceID
        let generation = readerProfile?.generation ?? 0
        final class Outcome { var succeeded = false }
        let outcome = Outcome()
        let show = canShowScreens ? show : nil
        screenShow = .idle
        if profile != nil { profileSend = .sending }
        let settingsWork = profile == nil && settings == nil ? nil :
            startReaderWork(attempt: attempt, kind: .settings) { [self] owner in
                do {
                    if let profile, let identity {
                        do {
                            let saved = try await client.saveReaderProfile(profile, generation: generation,
                                                                           deviceID: identity, host: host, port: port)
                            guard ownsReaderWork(owner, attempt: attempt) else { return }
                            readerProfile = saved
                            profileSend = .saved(saved.generation)
                        } catch CrossPointClient.ProfileRequestError.conflict {
                            guard ownsReaderWork(owner, attempt: attempt) else { return }
                            readerProfile = try? await client.readerProfile(deviceID: identity, host: host, port: port)
                            profileSend = .conflict
                            throw CrossPointClient.ProfileRequestError.conflict
                        }
                    }
                    if let settings {
                        try await client.save(preferences: settings, host: host, port: port, expectedDeviceID: identity)
                        guard ownsReaderWork(owner, attempt: attempt) else { return }
                        preferencesBaseline = settings
                        preferencesDirty = preferences != settings
                    }
                    if canSendGlance, glanceSettings.isConfigured, let identity {
                        await saveGlance(deviceID: identity, host: host, port: port)
                    }
                    outcome.succeeded = true
                    if cards == nil {
                        if let show, profile != nil, let identity, let generation = readerProfile?.generation {
                            await showScreen(show, generation: generation, deviceID: identity, host: host, port: port,
                                             attempt: attempt)
                        } else {
                            post("Applied on \(hardware.rawValue). Settings take effect now; Home and Sleep changes show when you leave Sync.",
                                 tone: .success)
                        }
                    }
                } catch {
                    guard attempt == connectionAttempt else { return }
                    if profileSend == .sending { profileSend = .failed(error.localizedDescription) }
                    post(error)
                }
            }
        if settingsWork == nil, profile != nil || settings != nil {
            if profileSend == .sending { profileSend = .idle }
            return
        }
        guard let cards else { return }
        Task { @MainActor [self] in
            if let settingsWork {
                await settingsWork.value
                guard outcome.succeeded, attempt == connectionAttempt else { return }
            }
            guard let content = applyContent(cards, drawCards: show == nil) else { return }
            await content.value
            guard let show, attempt == connectionAttempt, case .complete? = contentDeployment?.phase,
                  let identity, let generation = readerProfile?.generation else { return }
            startReaderWork(attempt: attempt, kind: .settings) { [self] owner in
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                await showScreen(show, generation: generation, deviceID: identity, host: host, port: port,
                                 attempt: attempt)
            }
        }
    }

    /// Inside a reader work item: asks the reader to draw `screen` for this
    /// profile generation and follows its receipt with reads only.
    private func showScreen(_ screen: ReaderScreen, generation: UInt32, deviceID: String, host: String, port: Int,
                            attempt: Int) async {
        let name = screen == .home ? "Home" : "the sleep screen"
        screenShow = .showing(screen)
        post("Showing \(name) on the reader…")
        do {
            try await ScreenPresenter.present(deviceID: deviceID, screen: screen, generation: generation, using: .init(
                request: { try await self.client.presentScreen(screen, generation: generation, deviceID: deviceID,
                                                               host: host, port: port) },
                state: { try await self.client.screenPresentation(screen, generation: generation, deviceID: deviceID,
                                                                  host: host, port: port) }))
            guard attempt == connectionAttempt else { return }
            screenShow = .shown(screen, generation: generation)
            post("Applied. The reader shows \(name). Book covers use placeholders in Sync. Press Back on the reader to return to Sync.", tone: .success)
        } catch {
            guard attempt == connectionAttempt, !(error is CancellationError) else { return }
            screenShow = .failed(screen, error.localizedDescription)
            post("Applied, but not shown on the reader yet. \(error.localizedDescription)", tone: .pending)
        }
    }

    // MARK: Weather and events

    /// A reader that stores weather and events from the app.
    var canSendGlance: Bool {
        !isDemoMode && !isInBackground && readerStatus?.pocketGlance == 1 && readerStatus?.deviceID != nil
    }

    /// Composes from the cached weather and today's calendar and stores it on
    /// the reader. Called inside a reader lane.
    private func saveGlance(deviceID: String, host: String, port: Int) async {
        let glance = glanceSettings.glance(events: glanceSettings.includeEvents ? CalendarSource.today() : [])
        do {
            try await client.saveGlance(glance, deviceID: deviceID, host: host, port: port)
            glanceSentAt = Date()
            glanceError = nil
        } catch {
            glanceError = error.localizedDescription
        }
    }

    /// Sends weather and events now, in the reader lane, when nothing else
    /// holds it. Data sync, not an edit: it changes nothing the user authored.
    func pushGlance() {
        guard canSendGlance, glanceSettings.isConfigured, !isWorking, !hasReaderWork,
              let identity = readerStatus?.deviceID else { return }
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        startReaderWork(attempt: attempt, kind: .settings) { [self] owner in
            guard ownsReaderWork(owner, attempt: attempt) else { return }
            await saveGlance(deviceID: identity, host: host, port: port)
        }
    }

    /// Refreshes Apple Weather when stale (never inside a reader lane: it
    /// needs the internet), then sends the result to a connected reader.
    func refreshGlance(force: Bool = false) {
        Task { @MainActor [self] in
            await glanceSettings.refreshWeatherIfNeeded(force: force)
            pushGlance()
        }
    }

    /// Identified reader whose firmware serves its published card files.
    var canLoadReaderCards: Bool { contentEditingSession != nil && readerStatus?.contentRead == 1 }

    /// Reads the reader's active card set in the exclusive reader lane and hands
    /// the verified draft back (nil when the reader has no app cards). Read-only:
    /// nothing on the reader or in the local draft changes here.
    @discardableResult
    func loadReaderCards(_ deliver: @escaping @MainActor (Result<ContentDraft?, Error>) -> Void) -> Bool {
        guard canLoadReaderCards, !isWorking, !hasReaderWork, let identity = readerStatus?.deviceID else { return false }
        let host = activeHost
        let port = activeHTTPPort
        let attempt = connectionAttempt
        let started = startReaderWork(attempt: attempt, kind: .preview) { [self] owner in
            do {
                let state = try await client.contentState(deviceID: identity, host: host, port: port)
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                loadedContentRevision = state.active?.revision ?? ""
                guard let active = state.active else {
                    deliver(.success(nil))
                    return
                }
                let draft = try await ReaderContentPull.draft(revision: active.revision) { [client] name, offset in
                    try await client.contentFileChunk(revision: active.revision, name: name, offset: offset,
                                                      deviceID: identity, host: host, port: port)
                }
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                deliver(.success(draft))
            } catch {
                guard attempt == connectionAttempt else { return }
                deliver(.failure(error))
            }
        }
        return started != nil
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
    /// Weather city, calendar choice and cached Apple Weather (this device only).
    let glanceSettings: GlanceSettings
    /// When the reader last accepted weather and events from this app.
    @Published private(set) var glanceSentAt: Date?
    @Published private(set) var glanceError: String?
    private let localFiles: LocalFileOperations
    private let releaseSource: ReleaseOperations
    // Bind each immutable revision to the selected session. Keeping this seam
    // at the I/O boundary lets the real Apply lifecycle run without a reader.
    typealias ContentTransportFactory = @MainActor (ContentRevision, String, String, Int) -> any ContentDeploymentTransport
    private let contentTransportFactory: ContentTransportFactory
    private let discoveryIO: any ReaderDiscoveryIO
    private let associationIO: any ReaderAssociationIO
    private struct ReadingExchangeState {
        var attempt: Int?
        var done = false
        var failures = 0
        var retryAfter = Date.distantPast
    }
    private var readingExchange = ReadingExchangeState()
    private var activeHost = "192.168.4.1"
    private var activeHTTPPort = 80
    private var heartbeatTask: Task<Void, Never>?
    private var connectionAttempt = 0
    private var nearbyLease: HotspotLease?
    private var readerWorkTask: Task<Void, Never>?
    @Published private var readerWorkOwner: UUID?
    /// Includes quiet HTTP exchanges and cancellation draining. BLE yields to this lane.
    var readerWorkActive: AnyPublisher<Bool, Never> {
        $readerWorkOwner.map { $0 != nil }.removeDuplicates().eraseToAnyPublisher()
    }
    private enum ReaderWorkKind { case transfer, settings, preview, local, session, discovery, connection, storage, quietReading }
    private var readerWorkKind: ReaderWorkKind?
    private var isInBackground = false
    private var expectedDeviceID: String?
    @Published private(set) var directConnectionRequested = false
    @Published private(set) var preparedTransfers: [PreparedTransfer] = []
    @Published private(set) var isCancellingConnection = false
    var isSearchingForReader: Bool { readerWorkKind == .discovery }
    var canCancelConnection: Bool {
        !isCancellingConnection && (readerWorkKind == .discovery || readerWorkKind == .connection
            || (directConnectionRequested && readerStatus == nil && !hasReaderWork))
    }
    var hasDirectSession: Bool { directConnectionRequested || nearbyLease != nil }
    var canPrepareFiles: Bool { !isDemoMode && !isWorking && !hasReaderWork && !isInBackground }
    var isTransferring: Bool { readerWorkTask != nil && readerWorkKind == .transfer }
    // Quiet exchange owns I/O but remains preemptible by an explicit user action.
    private var hasReaderWork: Bool { readerWorkTask != nil && readerWorkKind != .quietReading }
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
         associationIO: (any ReaderAssociationIO)? = nil,
         glanceSettings: GlanceSettings? = nil,
         releaseSource: ReleaseOperations = .init()) {
        self.client = client
        self.releaseSource = releaseSource
        self.glanceSettings = glanceSettings ?? GlanceSettings()
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
        if selectedDiscovery == nil, ProcessInfo.processInfo.arguments.contains("--ui-test-slow-discovery") {
            selectedDiscovery = EmptyReaderDiscoveryIO(delay: .seconds(30))
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
        if let error = error as? CrossPointClient.ClientError, case .publicationUnconfirmed = error {
            post(error.localizedDescription, tone: .pending)
        } else {
            post(error.localizedDescription, tone: .failure)
        }
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
        if readerWorkKind == .quietReading { readerWorkTask?.cancel() }
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
            diagnosticsAffordable: nil,
            totalHeap: 262_144
        )
        // Demo shows every control a current reader offers.
        preferences = ReaderPreferences(sideButtons: .previousNext, frontButtonsFollowOrientation: false)
        preferencesBaseline = preferences
        crashDiagnostic = nil
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
                    // Explicit cancellation owns cleanup after this task drains.
                    if !isCancellingConnection { await associationIO.leave(ssid: lease.ssid) }
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
        crashDiagnostic = nil
        readerStatus = status
        mirror.apply(.sessionStarted(status))
        UserDefaults.standard.set(host, forKey: Self.lastReaderHostKey)
        if let deviceID = status.deviceID {
            UserDefaults.standard.set(deviceID, forKey: Self.lastReaderDeviceIDKey)
        }
        selectHardware(named: status.device)
        activeHost = host
        activeHTTPPort = httpPort
        manualHotspotFallback = false
        locationPermissionRequired = false
        let attempt = connectionAttempt
        let loadedPreferences = try? await client.preferences(host: host, port: httpPort)
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        preferences = loadedPreferences
        preferencesBaseline = loadedPreferences
        mirror.apply(.preferences(preferences))
        let loadedDisplay = await loadReaderDisplay(status, host: host, port: httpPort)
        guard !Task.isCancelled, attempt == connectionAttempt else { return }
        readerDisplay = loadedDisplay
        if status.pocketProfile == 1, let identity = status.deviceID {
            let loadedProfile = try? await client.readerProfile(deviceID: identity, host: host, port: httpPort)
            guard !Task.isCancelled, attempt == connectionAttempt else { return }
            readerProfile = loadedProfile
        }
        if status.contentPresentation == true, let identity = status.deviceID,
           let state = try? await client.contentState(deviceID: identity, host: host, port: httpPort) {
            guard !Task.isCancelled, attempt == connectionAttempt else { return }
            loadedContentRevision = state.active?.revision ?? ""
        }
        // Weather (cached, no internet needed here) and today's events.
        if !isDemoMode, status.pocketGlance == 1, let identity = status.deviceID, glanceSettings.isConfigured {
            await saveGlance(deviceID: identity, host: host, port: httpPort)
            guard !Task.isCancelled, attempt == connectionAttempt else { return }
        }
        let diagnosticsAffordable = nearbyLease == nil && ReaderDiagnosticsPolicy.canFetchDiagnostics(
            freeHeap: status.freeHeap,
            readerSaysAffordable: status.diagnosticsAffordable
        )
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
            post("""
                 Firmware \(stagedVersion) is still waiting on the reader, which runs \(running).
                 1. Press Back on the reader to leave Sync.
                 2. Choose Install, or open Settings → System → SD Card Firmware Update.
                 """, tone: .onReader)
            startHeartbeat(host: host, port: httpPort)
            return
        case .nothingStaged:
            break
        }
        post(nearbyLease != nil ? "Connected directly. Keep Sync open on the reader." : "Connected to \(status.device). Ready to apply settings or send content.")
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
                    self.preferencesDirty = false
                    self.stopLiveSync()
                    self.mirror.apply(.connection(.disconnected))
                    self.post("Pocket connection ended. Check the reader’s Sync screen, then reconnect using the same connection method.", tone: .failure)
                    return
                }
            }
        }
    }

    @Published private(set) var readerFilePage: ReaderFilePage?
    @Published private(set) var readerSpace: ReaderSpaceUsage?
    @Published private(set) var readerFilesError: String?
    var isReadingStorage: Bool { readerWorkKind == .storage && isWorking }
    func cancelStorageRead() { if readerWorkKind == .storage { readerWorkTask?.cancel() } }

    func refreshReaderSpace() { readerStorageOperation(folder: nil, cursor: 0, deletion: nil) }
    func loadReaderFiles(_ folder: String, cursor: Int = 0) { readerStorageOperation(folder: folder, cursor: cursor, deletion: nil) }
    func deleteReaderFile(_ path: String, size: Int64, folder: String, identity: String?) {
        guard let identity, identity == readerStatus?.deviceID else { return }
        readerStorageOperation(folder: folder, cursor: 0, deletion: (path, size))
    }
    private func readerStorageOperation(folder: String?, cursor: Int, deletion: (String, Int64)?) {
        guard !isDemoMode, !isWorking, !hasReaderWork, !isInBackground,
              readerStatus?.readerFiles == 1, let identity = readerStatus?.deviceID else { return }
        let attempt = connectionAttempt, host = activeHost, port = activeHTTPPort
        readerFilesError = nil
        if folder != nil { readerFilePage = nil }
        startReaderWork(attempt: attempt, kind: .storage) { [self] owner in
            do {
                if let deletion {
                    let data = try await client.readerStorageRequest(endpoint: "files", identity: identity, host: host, port: port,
                        query: ["path": deletion.0, "size": String(deletion.1), "cursor": "0"], delete: true)
                    struct Deleted: Decodable { let deviceID: String; let deleted: Bool }
                    let receipt = try JSONDecoder().decode(Deleted.self, from: data)
                    guard receipt.deviceID == identity, receipt.deleted else {
                        throw CrossPointClient.ClientError.unexpectedMessage("Deletion was not confirmed. Refresh the folder.")
                    }
                    guard ownsReaderWork(owner, attempt: attempt) else { return }
                    readerSpace = nil
                }
                if let folder {
                    let data = try await client.readerStorageRequest(endpoint: "files", identity: identity, host: host, port: port,
                        query: ["path": folder, "cursor": String(cursor)])
                    let page = try JSONDecoder().decode(ReaderFilePage.self, from: data)
                    try page.validate(identity: identity, folder: folder, cursor: cursor)
                    guard ownsReaderWork(owner, attempt: attempt) else { return }
                    readerFilePage = page
                } else {
                    var next = 0
                    var free: Int64 = 0
                    var expectedTotal: Int64?
                    repeat {
                        let data = try await client.readerStorageRequest(endpoint: "storage", identity: identity, host: host, port: port,
                            query: ["cursor": String(next)])
                        let chunk = try JSONDecoder().decode(ReaderSpaceChunk.self, from: data)
                        guard chunk.deviceID == identity, chunk.totalBytes >= 0, chunk.freeBytes >= 0,
                              chunk.freeBytes <= chunk.totalBytes, free <= chunk.totalBytes - chunk.freeBytes,
                              expectedTotal == nil || expectedTotal == chunk.totalBytes,
                              chunk.nextCursor == 0 || (chunk.nextCursor == (next == 0 ? 4098 : next + 4096) && chunk.nextCursor <= 0x0FFFFFF7) else {
                            throw CrossPointClient.ClientError.unexpectedMessage("SD card changed. Refresh usage again.")
                        }
                        guard ownsReaderWork(owner, attempt: attempt) else { return }
                        expectedTotal = chunk.totalBytes
                        free += chunk.freeBytes
                        next = chunk.supported ? chunk.nextCursor : 0
                        if next == 0 { readerSpace = ReaderSpaceUsage(deviceID: identity, total: chunk.totalBytes, free: chunk.supported ? free : nil) }
                        try Task.checkCancellation()
                    } while next != 0
                }
            } catch {
                guard ownsReaderWork(owner, attempt: attempt), !Task.isCancelled else { return }
                readerFilesError = error.localizedDescription
            }
        }
    }

    func destinationLabel(for item: PreparedTransfer) -> String {
        let folder = destination(for: TransferPreparation.file(item))
        return "SD card " + (folder == "/" ? "/" : folder + "/") + item.filename
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
        preferences?.sleepTimeoutMinutes = min(max(minutes, 1), ReaderPreferences.neverSleepMinutes)
        preferencesDirty = true
    }

    /// Back to the settings last loaded from or saved on the reader.
    func revertPreferences() {
        guard let preferencesBaseline else { return }
        preferences = preferencesBaseline
        preferencesDirty = false
    }

    /// Stage an explicit offline draft only after connection; unsupported keys stay absent.
    func stageReadingPreferences(_ draft: ReaderPreferences) {
        guard let loaded = preferences else { return }
        var supported = draft
        if loaded.sideButtons == nil { supported.sideButtons = nil }
        if loaded.frontButtonsFollowOrientation == nil { supported.frontButtonsFollowOrientation = nil }
        preferencesDirty = supported != loaded
        preferences = supported
    }

    func setFontSize(_ size: Int) {
        preferences?.fontSize = size
        preferencesDirty = true
    }

    func setSideButtons(_ layout: ReaderPreferences.SideButtons) {
        guard preferences?.sideButtons != nil else { return }
        preferences?.sideButtons = layout
        preferencesDirty = true
    }

    func setFrontButtonsFollowOrientation(_ enabled: Bool) {
        guard preferences?.frontButtonsFollowOrientation != nil else { return }
        preferences?.frontButtonsFollowOrientation = enabled
        preferencesDirty = true
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
        let identity = readerStatus?.deviceID
        startReaderWork(attempt: attempt, kind: .settings) { [self] owner in
            do {
                try await client.save(preferences: preferences, host: host, port: port, expectedDeviceID: identity)
                guard ownsReaderWork(owner, attempt: attempt) else { return }
                preferencesBaseline = preferences
                preferencesDirty = self.preferences != preferences
                post("Settings were applied to \(hardware.rawValue).", tone: .success)
            } catch {
                guard !Task.isCancelled, attempt == connectionAttempt else { return }
                post(error)
            }
        }
    }

    enum ReaderUpdateState: Equatable {
        case idle
        case checking
        case downloading(String)
    }

    @Published private(set) var readerUpdateState: ReaderUpdateState = .idle

    @Published private(set) var latestFirmwareRelease: FirmwareRelease?
    @Published private(set) var isCheckingFirmware = false
    @Published private(set) var firmwareCheckError: String?
    private var didCheckFirmwareAtLaunch = false
    private var firmwareCheckTask: Task<FirmwareRelease, Error>?

    var firmwareAwaitingInstallation: String? {
        firmwareKey.flatMap { UserDefaults.standard.string(forKey: $0) }
    }

    var firmwareUpdateAvailable: Bool {
        guard let release = latestFirmwareRelease, let running = readerStatus?.version else { return false }
        return FirmwareReleaseSource.shouldOffer(release.version, to: running, channel: releaseSource.channel)
    }

    /// Metadata only, once per app model lifetime. Failed checks offer an explicit retry.
    func checkFirmwareAtLaunch() async {
        guard !didCheckFirmwareAtLaunch, !isDemoMode, !hasDirectSession else { return }
        didCheckFirmwareAtLaunch = true
        await checkFirmwareRelease()
    }

    func checkFirmwareRelease() async {
        guard !isDemoMode, !hasDirectSession, !isCheckingFirmware, readerUpdateState == .idle else { return }
        isCheckingFirmware = true
        firmwareCheckError = nil
        let work = Task {
            let release = try await releaseSource.latest()
            try Task.checkCancellation()
            return release
        }
        firmwareCheckTask = work
        defer { isCheckingFirmware = false; firmwareCheckTask = nil }
        do {
            let release = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            try Task.checkCancellation()
            if work.isCancelled { throw CancellationError() }
            latestFirmwareRelease = release
        } catch {
            firmwareCheckError = work.isCancelled || Task.isCancelled
                ? "Update check cancelled. Try again when ready."
                : "Couldn't check for updates. Try again with an internet connection."
        }
    }

    func cancelFirmwareCheck() { firmwareCheckTask?.cancel() }

    /// "Update reader" is offered only for a connected, real reader with no
    /// firmware already waiting, and never in demo mode.
    var canUpdateReader: Bool {
        canPrepareFiles && !hasDirectSession && !isCheckingFirmware && readerStatus != nil && readerUpdateState == .idle
            && !preparedTransfers.contains { $0.filename.lowercased().hasSuffix(".bin") }
    }

    /// Runs after an explicit update acknowledgement. Uses launch metadata (or
    /// looks it up if absent), then downloads and validates an offered release.
    /// Returns the local image for preparation and transfer,
    /// or nil after posting why nothing is needed or what failed.
    func downloadLatestFirmware() async -> (file: URL, version: String)? {
        guard canUpdateReader, let running = readerStatus?.version else { return nil }
        readerUpdateState = .checking
        defer { readerUpdateState = .idle }
        post("Checking the latest Pocket Daily firmware…")
        do {
            let release: FirmwareRelease
            if let cached = latestFirmwareRelease { release = cached }
            else { release = try await releaseSource.latest() }
            latestFirmwareRelease = release
            try Task.checkCancellation()
            guard FirmwareReleaseSource.shouldOffer(release.version, to: running, channel: releaseSource.channel) else {
                post("The reader is up to date: it runs \(running) and the latest release is \(release.version).", tone: .success)
                return nil
            }
            readerUpdateState = .downloading(release.version)
            post("Downloading Pocket Daily firmware \(release.version)\(release.isPrerelease ? " (pre-release)" : "")…")
            let file = try await releaseSource.download(release, Self.firmwareDownloads)
            if Task.isCancelled {
                try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                throw CancellationError()
            }
            post("Firmware \(release.version) was downloaded and verified.")
            return (file, release.version)
        } catch {
            if Task.isCancelled { post("Firmware download cancelled. Nothing was sent to the reader.", tone: .pending) }
            else { post(error) }
            return nil
        }
    }

    static var firmwareDownloads: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PocketFirmware", isDirectory: true)
    }

    /// The caller owns cancellation across download, preparation and transfer.
    func updateFirmware() async {
        let attempt = connectionAttempt
        let readerID = readerStatus?.deviceID
        guard let download = await downloadLatestFirmware() else { return }
        defer { try? FileManager.default.removeItem(at: download.file.deletingLastPathComponent()) }
        guard !Task.isCancelled else { return }
        guard attempt == connectionAttempt, readerStatus?.deviceID == readerID else {
            post("The reader connection changed. Choose Update again for the connected reader.", tone: .pending)
            return
        }
        let previous = Set(preparedTransfers.map(\.id))
        guard let preparation = upload(download.file) else { return }
        await preparation.value
        guard preparedTransfers.contains(where: { !previous.contains($0.id) && $0.kind == .firmware }) else { return }
        if Task.isCancelled {
            removePreparedFiles(kind: .firmware)
            return
        }
        guard attempt == connectionAttempt, readerStatus?.deviceID == readerID else {
            post("The reader connection changed. The update is kept for an explicit retry.", tone: .pending)
            return
        }
        sendPreparedFiles(kind: .firmware)
        if let transfer = readerWorkTask {
            await withTaskCancellationHandler {
                await transfer.value
            } onCancel: {
                transfer.cancel()
            }
        }
        if Task.isCancelled { removePreparedFiles(kind: .firmware) }
    }

    /// Retained for callers that already validated and acknowledged an image.
    func stageDownloadedFirmware(_ file: URL) {
        let previous = Set(preparedTransfers.map(\.id))
        guard let task = upload(file) else {
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            return
        }
        Task { [weak self] in
            await task.value
            try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
            guard let self, self.readerStatus != nil,
                  self.preparedTransfers.contains(where: {
                      !previous.contains($0.id) && $0.kind == .firmware && $0.filename == file.lastPathComponent
                  }) else { return }
            self.sendPreparedFiles(kind: .firmware)
        }
    }

    @discardableResult
    func upload(_ url: URL) -> Task<Void, Never>? {
        guard canPrepareFiles else { return nil }
        if url.pathExtension.lowercased() == "bin",
           preparedTransfers.contains(where: { $0.filename.lowercased().hasSuffix(".bin") }) {
            post("An update is already prepared. Resume or cancel it in Firmware before starting another.", tone: .failure)
            return nil
        }
        post("Preparing an offline copy before transfer…")
        return startReaderWork(attempt: connectionAttempt, kind: .local) { [self] _ in
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
                if item.kind == .firmware {
                    post("Firmware is ready to send.")
                } else {
                    post(readerStatus != nil
                        ? "\(item.filename) is ready. Choose Send content."
                        : "\(item.filename) is ready offline. Connect, then choose Send content.")
                }
            } catch { post(error) }
        }
    }

    func sendPreparedFiles(kind: TransferKind = .content) {
        guard !isDemoMode, !isWorking, !hasReaderWork, !isInBackground,
              let expectedStatus = readerStatus, preparedTransfers.contains(where: { $0.kind == kind }) else { return }
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
                guard status.supportsAtomicUpload else {
                    throw CrossPointClient.ClientError.unexpectedMessage("This reader does not advertise verified Pocket transfers. Update its firmware or copy the file to SD on Mac. Nothing was uploaded.")
                }
                while let index = preparedTransfers.firstIndex(where: { $0.kind == kind }) {
                    var item = preparedTransfers[index]
                    guard item.publicationPending != true else {
                        throw CrossPointClient.ClientError.publicationUnconfirmed
                    }
                    try Task.checkCancellation()
                    if let bound = item.readerID, bound != status.deviceID {
                        throw CrossPointClient.ClientError.unexpectedMessage("This pending file belongs to another reader. Remove it and prepare it again to change readers.")
                    }
                    let url = TransferPreparation.file(item)
                    if ArticleEPUB.isFilename(url.lastPathComponent), status.articleLibrary != 1 || status.uploadStreamPort == nil {
                        throw CrossPointClient.ClientError.unexpectedMessage("Update the reader firmware to use the Articles library. Your prepared article is kept.")
                    }
                    let isFirmware = url.pathExtension.lowercased() == "bin"
                    if isFirmware {
                        guard PocketHardware(deviceName: status.device) != nil else {
                            throw FirmwareValidationError.unsupportedReader(status.device)
                        }
                    }
                    item.readerID = status.deviceID
                    item.remoteStagingID = item.remoteStagingID ?? item.id
                    try JSONEncoder().encode(item).write(to: TransferPreparation.directory
                        .appendingPathComponent(item.id.uuidString).appendingPathComponent("transfer.json"), options: .atomic)
                    preparedTransfers[index] = item
                    activeTransferKind = kind
                    uploadProgress = 0
                    post(kind == .content ? "Sending content to SD card: \(item.filename)…"
                         : "Sending firmware to SD card for installation later…")
                    let transferID = item.id
                    let path = try await client.uploadAtomically(
                        fileURL: url, publishedFilename: isFirmware ? "update.bin" : nil,
                        destination: destination(for: url), host: host, port: port,
                        uploadChunkBytes: status.uploadChunkBytes, uploadStreamPort: status.uploadStreamPort,
                        uploadStreamResume: status.uploadStreamResume ?? false,
                        uploadStreamWindow: status.uploadStreamWindow,
                        expectedDeviceID: status.deviceID,
                        transferID: item.remoteStagingID ?? item.id,
                        transferControl: status.transferControl == 1,
                        transferKind: kind,
                        note: { [weak self] text in Task { @MainActor in
                            guard let self, self.ownsReaderWork(owner, attempt: attempt) else { return }
                            self.post(text)
                        } },
                        reconnect: { [weak self] in await self?.reconnectForTransfer(owner: owner, attempt: attempt) ?? false },
                        beforeCommit: { [self] in
                            try await markPublicationPending(transferID, owner: owner, attempt: attempt)
                        }
                    ) { [weak self] sent, total in
                        Task { @MainActor in
                            guard let self, self.ownsReaderWork(owner, attempt: attempt) else { return }
                            let progress = total > 0 ? Double(sent) / Double(total) : 0
                            self.uploadProgress = progress
                            self.mirror.apply(.transferProgress(progress))
                        }
                    }
                    guard readerWorkOwner == owner, attempt == connectionAttempt else { return }
                    uploadProgress = 1
                    mirror.apply(.transferProgress(1))
                    if isFirmware {
                        if let key, let version = item.firmwareVersion { UserDefaults.standard.set(version, forKey: key) }
                        post(Self.stagedFirmwareMessage(version: item.firmwareVersion ?? "unknown version"), tone: .onReader)
                    } else {
                        post("Content saved on the reader’s SD card: \(path). Open it from the reader’s library.", tone: .success)
                    }
                    try FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    preparedTransfers.removeAll { $0.id == item.id }
                }
                if hasDirectSession { await finishConnection(preserveMessage: true) }
            } catch {
                guard attempt == connectionAttempt else { return }
                if Task.isCancelled, preparedTransfers.contains(where: { $0.kind == kind }) { post("Transfer paused. The prepared copy is kept. Resume this category, or remove it to clean up the reader’s temporary file. If saving had already started, check the reader for the completed file.", tone: .pending) }
                else if !Task.isCancelled { post(error) }
            }
        }
    }

    private func markPublicationPending(_ id: UUID, owner: UUID, attempt: Int) async throws {
        guard ownsReaderWork(owner, attempt: attempt),
              let index = preparedTransfers.firstIndex(where: { $0.id == id }) else { throw CancellationError() }
        var item = preparedTransfers[index]
        item.publicationPending = true
        let data = try JSONEncoder().encode(item)
        let record = TransferPreparation.directory.appendingPathComponent(id.uuidString)
            .appendingPathComponent("transfer.json")
        // Keep the in-memory queue conservative even if persistence fails.
        preparedTransfers[index] = item
        try await Task.detached(priority: .utility) { try data.write(to: record, options: .atomic) }.value
        guard ownsReaderWork(owner, attempt: attempt) else { throw CancellationError() }
    }

    @Published private(set) var activeTransferKind: TransferKind?

    /// A cancelled network task must finish before cleanup opens a new request.
    func stopAndRemoveTransfer() {
        guard let kind = activeTransferKind, let task = readerWorkTask, isTransferring else { return }
        task.cancel()
        post("Stopping transfer…", tone: .pending)
        Task { [weak self] in
            await task.value
            self?.removePreparedFiles(kind: kind)
        }
    }

    func removePreparedFiles(kind: TransferKind = .content, localOnly: Bool = false) {
        guard !isWorking, !hasReaderWork, !isDemoMode, !isInBackground else { return }
        let items = preparedTransfers.filter { $0.kind == kind }
        guard !items.isEmpty else { return }
        post(localOnly ? "Removing local prepared copies…" : "Cleaning up \(kind.rawValue) transfers…")
        let host = activeHost
        let port = activeHTTPPort
        startReaderWork(attempt: connectionAttempt, kind: .session) { [self] _ in
            do {
                for item in items {
                    if let stagingID = item.stagingID, !localOnly {
                        guard let bound = item.readerID, let status = readerStatus,
                              status.deviceID == bound, status.transferControl == 1 else {
                            throw CrossPointClient.ClientError.unexpectedMessage(
                                "Reconnect to the same reader to clean up its temporary file. Older firmware cannot confirm cleanup; you can explicitly remove only the local copy.")
                        }
                        let current = try await client.status(host: host, port: port)
                        guard current.deviceID == bound, current.transferControl == 1 else {
                            throw CrossPointClient.ClientError.unexpectedMessage("The reader changed. Cleanup was not performed.")
                        }
                        try await client.controlTransfer(action: "discard", transferID: stagingID,
                            destination: destination(for: TransferPreparation.file(item)), kind: item.kind,
                            host: host, port: port)
                    }
                    let folder = TransferPreparation.file(item).deletingLastPathComponent()
                    if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                    preparedTransfers.removeAll { $0.id == item.id }
                }
                uploadProgress = 0
                if kind == .firmware {
                    post(localOnly ? "Update forgotten on this device. Reader files were not changed."
                         : "Update cancelled. Temporary files removed; already saved firmware is unchanged.", tone: .success)
                } else {
                    post(localOnly
                         ? "Local prepared copies removed. Reader files were not changed; temporary data may remain until Sync closes or another transfer cleans it up."
                         : "Prepared copies and any tracked temporary reader files removed. Original sources and already saved reader files are unchanged.", tone: .success)
                }
            } catch { post(error) }
        }
    }

    func resumeDirectConnection() -> Bool {
        guard let lease = nearbyLease else { return false }
        useNearbyLease(lease)
        return true
    }

    func beginDirectConnection() {
        guard !isWorking, !hasReaderWork, !isDemoMode, readerStatus == nil else { return }
        if readerWorkKind == .quietReading { readerWorkTask?.cancel() }
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

    /// Stop discovery, BLE handoff, or Wi-Fi verification. Reserve the work
    /// lane while non-cooperative OS requests drain and the lease is released.
    /// Rotating both tokens prevents late replies and the old defer from
    /// reconnecting or admitting new work during cleanup.
    func cancelConnectionAttempt() {
        guard canCancelConnection else { return }
        let previous = readerWorkTask
        previous?.cancel()
        connectionAttempt += 1
        heartbeatTask?.cancel()
        discoveryIO.stop()
        directConnectionRequested = false
        let owner = UUID()
        readerWorkOwner = owner
        readerWorkKind = .session
        isCancellingConnection = true
        isWorking = true
        post("Stopping connection…", tone: .pending)
        readerWorkTask = Task {
            defer {
                isCancellingConnection = false
                finishReaderWork(owner: owner, attempt: connectionAttempt)
            }
            await previous?.value
            await finishConnection(preserveMessage: true)
            post("Connection cancelled. You can try again when ready.", tone: .pending)
        }
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
            // User work preempts quiet exchange; otherwise only a new connection
            // can replace a connection. Always drain predecessor I/O below.
            guard readerWorkKind == .quietReading || (kind == .connection && readerWorkKind == .connection) else { return nil }
            previous?.cancel()
        }
        let owner = UUID()
        readerWorkOwner = owner
        readerWorkKind = kind
        isWorking = kind != .quietReading
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
        let resumeTraffic = readerWorkKind != .local && readerWorkKind != .quietReading
        readerWorkOwner = nil
        readerWorkKind = nil
        readerWorkTask = nil
        isWorking = false
        activeTransferKind = nil
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
        refreshGlance()
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
        stopLiveSync()
        mirror.apply(.connection(.disconnected))
        if !preserveMessage { post("Session ended. Check Wi-Fi settings if your usual connection has not returned.") }
        if legacyDirectSession { post(message + " Close Sync on the reader when finished.", tone: messageTone) }
        if !readerEnded { post(message + " Close Sync on the reader; its session-end response was not received.", tone: .pending) }
    }

    /// Sent is not installed: the reader installs only after its own confirmation.
    static func stagedFirmwareMessage(version: String) -> String {
        """
        Firmware \(version) is on the reader, not installed yet.
        1. Press Back on the reader to leave Sync.
        2. Choose Install and wait for the reader to restart.
        Then reconnect and the app confirms the new version. You can also install it later from Settings → System → SD Card Firmware Update.
        """
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
                    post("""
                         Firmware \(version) was copied to the SD card as update.bin, not installed yet.
                         1. Put the card in the reader.
                         2. Open Settings → System → SD Card Firmware Update and install it.
                         Then check the version on the reader.
                         """, tone: .onReader)
                } else {
                    post("Copied to SD card: \(result.path)", tone: .success)
                }
            } catch {
                post(error)
            }
        }
    }

    func destination(for url: URL) -> String {
        if ArticleEPUB.isFilename(url.lastPathComponent) { return "/Articles" }
        return switch url.pathExtension.lowercased() {
        case "pdl": "/pocket-daily/learning"
        // The same family folder the mounted-SD copy uses; the reader finds fonts there at boot.
        case "cpfont": "/.fonts/" + Self.fontFamily(from: url.deletingPathExtension().lastPathComponent)
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

    /// Applies within one reader session and reports whether the redraw of this
    /// exact revision was confirmed. Never reconnects or flashes.
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

    /// `drawCards` false stores and activates the cards without drawing the
    /// card page (a screen that shows them is drawn next instead).
    @discardableResult
    func applyContent(_ revision: ContentRevision, drawCards: Bool = true) -> Task<Void, Never>? {
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
                if !drawCards {
                    post("Cards applied on the reader.", tone: .success)
                } else if status.contentPresentation == true {
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
