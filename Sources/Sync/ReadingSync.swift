import Foundation

/// Keeps reading positions in step through three channels that share the
/// KOSync v1 record: iCloud for the same Apple ID's devices, the connected
/// X3/X4 reader, and an optional KOReader sync server. Reading never waits
/// for any of them; failures only change the status line.
@MainActor
final class ReadingSync: ObservableObject {
    static let shared = ReadingSync()

    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let document: String
        let device: String
        let source: SyncSource
        let position: ReadingPosition
        let remoteMarker: String
    }

    enum DocumentMatching: String, CaseIterable, Identifiable {
        case binary, fileName
        var id: String { rawValue }
        var title: String { self == .binary ? "File contents" : "File name" }
    }

    enum ServerHealth: Equatable {
        case unknown, checking, available, unavailable(String)
    }

    @Published private(set) var account: KOSyncAccount?
    @Published private(set) var statusLine: String?
    @Published private(set) var lastSynced: Date?
    @Published private(set) var serverHealth: ServerHealth = .unknown
    @Published private(set) var lastReaderExchange: (device: String, date: Date, books: Int)?
    @Published var hasDismissedRecommendation: Bool {
        didSet { defaults.set(hasDismissedRecommendation, forKey: Keys.dismissedRecommendation) }
    }
    @Published var matching: DocumentMatching {
        didSet { defaults.set(matching.rawValue, forKey: Keys.matching) }
    }
    @Published var iCloudEnabled: Bool {
        didSet { defaults.set(iCloudEnabled, forKey: Keys.iCloud) }
    }
    @Published var readerExchangeEnabled: Bool {
        didSet { defaults.set(readerExchangeEnabled, forKey: Keys.readerExchange) }
    }

    /// A KOReader sync server account is set up.
    var isConnected: Bool { account != nil }
    var isICloudActive: Bool { iCloudEnabled && iCloudAvailable() }
    var hasAnyChannel: Bool { isConnected || isICloudActive }
    var deviceName: String { store.deviceName }
    var deviceID: String { store.deviceID }

    private enum Keys {
        static let dismissedRecommendation = "kosync.recommendation.dismissed"
        static let matching = "kosync.matching"
        static let dismissedMarkers = "kosync.dismissedMarkers"
        static let iCloud = "sync.icloud.enabled"
        static let readerExchange = "sync.reader.enabled"
    }

    private let store: KOSyncAccountStore
    private let defaults: UserDefaults
    private let transport: any KOSyncTransport
    private let iCloud: ICloudProgressStore
    private let iCloudAvailable: () -> Bool
    private let readerPositions: ReaderPositionStore
    private var pending: [String: KOSyncProgress] = [:]
    private var lastPushed: [String: String] = [:]
    private var pushTask: Task<Void, Never>?

    init(store: KOSyncAccountStore? = nil, defaults: UserDefaults = .standard,
         transport: any KOSyncTransport = URLSession.shared, iCloud: ICloudProgressStore? = nil,
         iCloudAvailable: (() -> Bool)? = nil, readerPositions: ReaderPositionStore? = nil) {
        let store = store ?? KOSyncAccountStore()
        self.store = store
        self.defaults = defaults
        self.transport = transport
        self.iCloud = iCloud ?? ICloudProgressStore()
        self.iCloudAvailable = iCloudAvailable ?? { FileManager.default.ubiquityIdentityToken != nil }
        self.readerPositions = readerPositions ?? ReaderPositionStore(defaults: defaults)
        hasDismissedRecommendation = defaults.bool(forKey: Keys.dismissedRecommendation)
        matching = DocumentMatching(rawValue: defaults.string(forKey: Keys.matching) ?? "") ?? .binary
        iCloudEnabled = defaults.object(forKey: Keys.iCloud) as? Bool ?? true
        readerExchangeEnabled = defaults.object(forKey: Keys.readerExchange) as? Bool ?? true
        account = try? store.loadAccount()
    }

    var serverAddress: String { (account?.server ?? store.server).baseURL.absoluteString }
    var username: String? { account?.credentials.username }

    // MARK: KOReader server account

    /// Signs in, or creates the account first. Only a server-accepted account is saved.
    func connect(server address: String, username: String, password: String, create: Bool) async throws {
        let server = try KOSyncServer(validating: address)
        let credentials = KOSyncCredentials(username: username.trimmingCharacters(in: .whitespaces), password: password)
        let client = KOSyncClient(server: server, transport: transport)
        do {
            if create { try await client.register(credentials) }
            try await client.authorize(credentials)
        } catch let error as KOSyncError {
            throw Self.explain(error, server: server)
        }
        let account = KOSyncAccount(server: server, credentials: credentials)
        try store.save(account)
        self.account = account
        statusLine = nil
        serverHealth = .available
    }

    func disconnect() throws {
        try store.signOut()
        account = nil
        pending = [:]
        lastPushed = [:]
        statusLine = nil
    }

    /// Checks a server before the user types an account, so an outage reads as
    /// an outage rather than a wrong password.
    func checkServer(_ address: String) async {
        guard let server = try? KOSyncServer(validating: address) else {
            serverHealth = .unavailable(KOSyncError.invalidServerURL.localizedDescription)
            return
        }
        serverHealth = .checking
        do {
            try await KOSyncClient(server: server, transport: transport).healthcheck()
            serverHealth = .available
        } catch {
            serverHealth = .unavailable(Self.explain(error as? KOSyncError ?? .network, server: server).localizedDescription)
        }
    }

    struct ServerOutage: LocalizedError {
        let isPublic: Bool
        var errorDescription: String? {
            isPublic
                ? "The public KOReader sync server is not responding right now. This happens from time to time; try again later. Your positions stay on this device, and iCloud and your reader keep syncing without it."
                : "This sync server is not responding. Check its address, or try again later."
        }
    }

    private static func explain(_ error: KOSyncError, server: KOSyncServer) -> Error {
        switch error {
        case .server(let status) where (500...599).contains(status):
            return ServerOutage(isPublic: server == .standard)
        case .timedOut, .cannotReachServer:
            return ServerOutage(isPublic: server == .standard)
        default:
            return error
        }
    }

    // MARK: Positions

    func document(for book: LibraryBook) -> String {
        matching == .binary ? book.documentDigest : KOReaderDocumentDigest.filenameMD5(book.fileName)
    }

    /// The furthest newer position from another device across all channels.
    /// Never moves the page itself.
    func suggestion(for book: LibraryBook, current: ReadingPosition?) async -> Suggestion? {
        let document = document(for: book)
        var candidates: [RemotePosition] = []
        if isICloudActive, let record = iCloud.record(for: document) {
            candidates.append(RemotePosition(source: .iCloud, record: record))
        }
        if readerExchangeEnabled, let record = readerPositions.record(for: book.documentDigest) {
            candidates.append(RemotePosition(source: .reader(record.device), record: record))
        }
        if let account {
            let client = KOSyncClient(server: account.server, transport: transport)
            do {
                if let record = try await client.fetchProgress(document: document, credentials: account.credentials) {
                    candidates.append(RemotePosition(source: .koreaderServer, record: record))
                }
                markSynced()
            } catch {
                report(error)
            }
        }
        let local = current?.fraction ?? 0
        let dismissed = dismissedMarkers[document, default: []]
        let best = candidates
            .filter { !isOwn($0.record) }
            .filter { $0.record.percentage > local + 0.004 }
            .filter { !dismissed.contains(Self.marker($0.record)) }
            .max { $0.record.percentage < $1.record.percentage }
        guard let best else { return nil }
        let record = best.record
        let xpointer = record.progress.hasPrefix("/body/DocFragment[") ? record.progress : nil
        let position = ReadingPosition(fraction: record.percentage, xpointer: xpointer, cfi: nil, chapter: nil,
                                       updatedAt: record.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date())
        return Suggestion(document: document, device: record.device.isEmpty ? "Another device" : record.device,
                          source: best.source, position: position, remoteMarker: Self.marker(record))
    }

    private func isOwn(_ record: KOSyncProgress) -> Bool {
        record.deviceID.isEmpty ? record.device == store.deviceName : record.deviceID == store.deviceID
    }

    private static func marker(_ record: KOSyncProgress) -> String {
        "\(record.timestamp ?? 0)|\(record.progress)"
    }

    func dismiss(_ suggestion: Suggestion) {
        var markers = dismissedMarkers
        markers[suggestion.document, default: []].append(suggestion.remoteMarker)
        markers[suggestion.document] = Array(markers[suggestion.document, default: []].suffix(5))
        defaults.set(markers, forKey: Keys.dismissedMarkers)
    }

    /// Page turns settle for a few seconds before a position is shared.
    func positionChanged(_ position: ReadingPosition, for book: LibraryBook) {
        guard hasAnyChannel, let progress = progress(for: position, book: book) else { return }
        pending[progress.document] = progress
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func pushNow(_ position: ReadingPosition, for book: LibraryBook) async {
        guard hasAnyChannel else { return }
        if let progress = progress(for: position, book: book) { pending[progress.document] = progress }
        pushTask?.cancel()
        pushTask = nil
        await flush()
    }

    private func progress(for position: ReadingPosition, book: LibraryBook) -> KOSyncProgress? {
        // KOReader resolves EPUB positions by XPointer; a percentage alone would
        // send other devices to the wrong place.
        guard let xpointer = position.xpointer, xpointer.hasPrefix("/body/DocFragment["), position.fraction.isFinite else {
            return nil
        }
        return store.progress(document: document(for: book), position: xpointer, percentage: position.fraction)
    }

    private func flush() async {
        let batch = pending
        for (document, progress) in batch {
            let marker = "\(progress.progress)|\(progress.percentage)"
            if lastPushed[document] == marker {
                pending[document] = nil
                continue
            }
            if isICloudActive { iCloud.save(progress) }
            if let account {
                do {
                    try await KOSyncClient(server: account.server, transport: transport)
                        .updateProgress(progress, credentials: account.credentials)
                    markSynced()
                } catch {
                    report(error)
                    return
                }
            }
            if pending[document] == progress { pending[document] = nil }
            lastPushed[document] = marker
        }
    }

    // MARK: Reader exchange (reading-progress v1)

    /// Keeps the reader's positions for matching library books, and returns the
    /// library positions that are further along, to be offered on the reader.
    func exchange(with list: ReaderReadingList, readerName: String, library: [LibraryBook], now: Date = Date())
        -> [KOSyncProgress] {
        guard readerExchangeEnabled else { return [] }
        let byDigest = Dictionary(list.books.map { ($0.document, $0) }, uniquingKeysWith: { first, _ in first })
        var received: [KOSyncProgress] = []
        var outgoing: [KOSyncProgress] = []
        for book in library {
            guard let entry = byDigest[book.documentDigest] else { continue }
            if let progress = entry.progress {
                received.append(KOSyncProgress(document: book.documentDigest, progress: progress, percentage: entry.percentage,
                                               device: readerName, deviceID: "reader:\(list.deviceID)",
                                               timestamp: entry.updated.flatMap { $0 > 0 ? $0 : nil }))
            }
            if let local = book.position, let xpointer = local.xpointer, local.fraction > entry.percentage + 0.004 {
                outgoing.append(store.progress(document: book.documentDigest, position: xpointer, percentage: local.fraction))
            }
        }
        readerPositions.save(received)
        lastReaderExchange = (readerName, now, received.count + outgoing.count)
        return outgoing
    }

    private var dismissedMarkers: [String: [String]] {
        defaults.dictionary(forKey: Keys.dismissedMarkers) as? [String: [String]] ?? [:]
    }

    private func markSynced() {
        lastSynced = Date()
        statusLine = nil
    }

    private func report(_ error: Error) {
        guard !(error is CancellationError) else { return }
        switch error as? KOSyncError {
        case .offline?: statusLine = "Server sync paused while offline"
        case .unauthorized?: statusLine = "Server sync needs you to sign in again"
        case .server(let status)? where (500...599).contains(status):
            statusLine = "The sync server is not responding; positions will sync later"
        case .timedOut?, .cannotReachServer?:
            statusLine = "The sync server is not responding; positions will sync later"
        default: statusLine = "Server sync unavailable right now"
        }
    }
}
