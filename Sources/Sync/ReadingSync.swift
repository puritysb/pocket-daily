import Foundation

/// Keeps reading positions in step through an optional KOReader sync server.
/// Reading never waits for it; failures only change the status line.
@MainActor
final class ReadingSync: ObservableObject {
    static let shared = ReadingSync()

    struct Suggestion: Identifiable, Equatable {
        let id = UUID()
        let document: String
        let device: String
        let position: ReadingPosition
        let remoteMarker: String
    }

    enum DocumentMatching: String, CaseIterable, Identifiable {
        case binary, fileName
        var id: String { rawValue }
        var title: String { self == .binary ? "File contents" : "File name" }
    }

    @Published private(set) var account: KOSyncAccount?
    @Published private(set) var statusLine: String?
    @Published private(set) var lastSynced: Date?
    @Published var hasDismissedRecommendation: Bool {
        didSet { defaults.set(hasDismissedRecommendation, forKey: Keys.dismissedRecommendation) }
    }
    @Published var matching: DocumentMatching {
        didSet { defaults.set(matching.rawValue, forKey: Keys.matching) }
    }

    var isConnected: Bool { account != nil }
    var deviceName: String { store.deviceName }

    private enum Keys {
        static let dismissedRecommendation = "kosync.recommendation.dismissed"
        static let matching = "kosync.matching"
        static let dismissedMarkers = "kosync.dismissedMarkers"
    }

    private let store: KOSyncAccountStore
    private let defaults: UserDefaults
    private let transport: any KOSyncTransport
    private var pending: [String: KOSyncProgress] = [:]
    private var lastPushed: [String: String] = [:]
    private var pushTask: Task<Void, Never>?

    init(store: KOSyncAccountStore? = nil, defaults: UserDefaults = .standard,
         transport: any KOSyncTransport = URLSession.shared) {
        let store = store ?? KOSyncAccountStore()
        self.store = store
        self.defaults = defaults
        self.transport = transport
        hasDismissedRecommendation = defaults.bool(forKey: Keys.dismissedRecommendation)
        matching = DocumentMatching(rawValue: defaults.string(forKey: Keys.matching) ?? "") ?? .binary
        account = try? store.loadAccount()
    }

    var serverAddress: String { (account?.server ?? store.server).baseURL.absoluteString }
    var username: String? { account?.credentials.username }

    // MARK: Account

    /// Signs in, or creates the account first. Only a server-accepted account is saved.
    func connect(server address: String, username: String, password: String, create: Bool) async throws {
        let server = try KOSyncServer(validating: address)
        let credentials = KOSyncCredentials(username: username.trimmingCharacters(in: .whitespaces), password: password)
        let client = KOSyncClient(server: server, transport: transport)
        if create { try await client.register(credentials) }
        try await client.authorize(credentials)
        let account = KOSyncAccount(server: server, credentials: credentials)
        try store.save(account)
        self.account = account
        statusLine = nil
    }

    func disconnect() throws {
        try store.signOut()
        account = nil
        pending = [:]
        lastPushed = [:]
        statusLine = nil
    }

    // MARK: Positions

    func document(for book: LibraryBook) -> String {
        matching == .binary ? book.documentDigest : KOReaderDocumentDigest.filenameMD5(book.fileName)
    }

    /// A newer position from another device, if any. Never moves the page itself.
    func suggestion(for book: LibraryBook, current: ReadingPosition?) async -> Suggestion? {
        guard let account else { return nil }
        let document = document(for: book)
        let client = KOSyncClient(server: account.server, transport: transport)
        do {
            guard let remote = try await client.fetchProgress(document: document, credentials: account.credentials) else {
                markSynced()
                return nil
            }
            markSynced()
            let ownRecord = remote.deviceID.isEmpty ? remote.device == store.deviceName : remote.deviceID == store.deviceID
            guard !ownRecord else { return nil }
            let marker = "\(remote.timestamp ?? 0)|\(remote.progress)"
            guard !dismissedMarkers[document, default: []].contains(marker) else { return nil }
            let local = current?.fraction ?? 0
            guard remote.percentage > local + 0.004 else { return nil }
            let xpointer = remote.progress.hasPrefix("/body/DocFragment[") ? remote.progress : nil
            let position = ReadingPosition(fraction: remote.percentage, xpointer: xpointer, cfi: nil, chapter: nil,
                                           updatedAt: remote.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date())
            return Suggestion(document: document, device: remote.device.isEmpty ? "Another device" : remote.device,
                              position: position, remoteMarker: marker)
        } catch {
            report(error)
            return nil
        }
    }

    func dismiss(_ suggestion: Suggestion) {
        var markers = dismissedMarkers
        markers[suggestion.document, default: []].append(suggestion.remoteMarker)
        markers[suggestion.document] = Array(markers[suggestion.document, default: []].suffix(5))
        defaults.set(markers, forKey: Keys.dismissedMarkers)
    }

    /// Page turns settle for a few seconds before a position is uploaded.
    func positionChanged(_ position: ReadingPosition, for book: LibraryBook) {
        guard account != nil, let progress = progress(for: position, book: book) else { return }
        pending[progress.document] = progress
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            await self?.flush()
        }
    }

    func pushNow(_ position: ReadingPosition, for book: LibraryBook) async {
        guard account != nil else { return }
        if let progress = progress(for: position, book: book) { pending[progress.document] = progress }
        pushTask?.cancel()
        pushTask = nil
        await flush()
    }

    private func progress(for position: ReadingPosition, book: LibraryBook) -> KOSyncProgress? {
        // KOReader resolves EPUB positions by XPointer; a percentage alone would
        // send other devices to the wrong place.
        guard let xpointer = position.xpointer, xpointer.hasPrefix("/body/DocFragment[") else { return nil }
        return store.progress(document: document(for: book), position: xpointer, percentage: position.fraction)
    }

    private func flush() async {
        guard let account else { return }
        let client = KOSyncClient(server: account.server, transport: transport)
        for (document, progress) in pending {
            let marker = "\(progress.progress)|\(progress.percentage)"
            if lastPushed[document] == marker {
                pending[document] = nil
                continue
            }
            do {
                try await client.updateProgress(progress, credentials: account.credentials)
                if pending[document] == progress { pending[document] = nil }
                lastPushed[document] = marker
                markSynced()
            } catch {
                report(error)
                return
            }
        }
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
        case .offline?: statusLine = "Sync paused while offline"
        case .unauthorized?: statusLine = "Sync needs you to sign in again"
        default: statusLine = "Sync unavailable right now"
        }
    }
}
