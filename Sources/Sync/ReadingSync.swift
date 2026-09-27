import Foundation

/// Keeps reading positions in step without any server: iCloud key-value
/// storage for the same Apple ID's devices, and the connected X3/X4 reader.
/// Reading never waits for either; the page never moves without asking.
@MainActor
final class ReadingSync: ObservableObject {
    static let shared = ReadingSync()

    struct Suggestion: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Another device read here more recently than this one, ahead or behind.
            case lastRead
            /// Another device got further, though not more recently.
            case furthest
        }
        let id = UUID()
        let document: String
        let device: String
        let source: SyncSource
        let kind: Kind
        let position: ReadingPosition
        let remoteMarker: String
    }

    struct ReaderExchange: Equatable {
        let device: String
        let date: Date
        let received: Int
        let sent: Int
    }

    /// The last exchange with a reader that completed, in both directions.
    @Published private(set) var lastReaderExchange: ReaderExchange?
    /// Why the most recent exchange attempt failed; cleared by a success.
    @Published private(set) var readerExchangeError: String?
    /// Changes when another device's iCloud record arrives, so an open book can re-check.
    @Published private(set) var remoteRevision = 0
    @Published var iCloudEnabled: Bool {
        didSet { defaults.set(iCloudEnabled, forKey: Keys.iCloud) }
    }
    @Published var readerExchangeEnabled: Bool {
        didSet { defaults.set(readerExchangeEnabled, forKey: Keys.readerExchange) }
    }

    var isICloudActive: Bool { iCloudEnabled && iCloudAvailable() }

    private enum Keys {
        static let dismissedMarkers = "sync.dismissedMarkers"
        static let iCloud = "sync.icloud.enabled"
        static let readerExchange = "sync.reader.enabled"
    }

    let deviceName: String
    let deviceID: String
    private let defaults: UserDefaults
    private let iCloud: ICloudProgressStore
    private let iCloudAvailable: () -> Bool
    private let readerPositions: ReaderPositionStore
    private var pending: [String: PositionRecord] = [:]
    private var lastPushed: [String: String] = [:]
    private var pushTask: Task<Void, Never>?
    private var pendingReceived = 0

    init(defaults: UserDefaults = .standard, deviceName: String? = nil, deviceID: String? = nil,
         iCloud: ICloudProgressStore? = nil, iCloudAvailable: (() -> Bool)? = nil,
         readerPositions: ReaderPositionStore? = nil) {
        self.defaults = defaults
        self.deviceName = deviceName ?? SyncDevice.name
        self.deviceID = deviceID ?? SyncDevice.identifier(defaults)
        self.iCloud = iCloud ?? ICloudProgressStore()
        self.iCloudAvailable = iCloudAvailable ?? { FileManager.default.ubiquityIdentityToken != nil }
        self.readerPositions = readerPositions ?? ReaderPositionStore(defaults: defaults)
        iCloudEnabled = defaults.object(forKey: Keys.iCloud) as? Bool ?? true
        readerExchangeEnabled = defaults.object(forKey: Keys.readerExchange) as? Bool ?? true
        if iCloud == nil {
            NotificationCenter.default.addObserver(forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                                                   object: NSUbiquitousKeyValueStore.default, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.remoteRevision += 1 }
            }
            NSUbiquitousKeyValueStore.default.synchronize()
        }
    }

    // MARK: Positions

    /// Another device's place worth offering, never moving the page itself:
    /// the most recent place read elsewhere after this device last read here
    /// (ahead or behind, so re-reading carries over), else the furthest place.
    func suggestion(for book: LibraryBook, current: ReadingPosition?) async -> Suggestion? {
        let document = book.documentDigest
        var candidates: [RemotePosition] = []
        if isICloudActive {
            candidates += iCloud.records(for: document).map { RemotePosition(source: .iCloud, record: $0) }
        }
        if readerExchangeEnabled, let record = readerPositions.record(for: document) {
            candidates.append(RemotePosition(source: .reader(record.device), record: record))
        }
        let local = current?.fraction ?? 0
        let localTime = current.map { Int($0.updatedAt.timeIntervalSince1970) } ?? 0
        let dismissed = dismissedMarkers[document, default: []]
        let others = candidates
            .filter { !isOwn($0.record) }
            .filter { abs($0.record.percentage - local) > 0.004 }
            .filter { !dismissed.contains(Self.marker($0.record)) }
        let chosen: (RemotePosition, Suggestion.Kind)?
        if let recent = others.filter({ ($0.record.timestamp ?? 0) > localTime })
            .max(by: { ($0.record.timestamp ?? 0) < ($1.record.timestamp ?? 0) }) {
            chosen = (recent, .lastRead)
        } else if let furthest = others.filter({ $0.record.percentage > local })
            .max(by: { $0.record.percentage < $1.record.percentage }) {
            chosen = (furthest, .furthest)
        } else {
            chosen = nil
        }
        guard let (best, kind) = chosen else { return nil }
        let record = best.record
        let xpointer = record.progress.hasPrefix("/body/DocFragment[") ? record.progress : nil
        let position = ReadingPosition(fraction: record.percentage, xpointer: xpointer, cfi: nil, chapter: nil,
                                       updatedAt: record.timestamp.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? Date())
        return Suggestion(document: document, device: record.device.isEmpty ? "Another device" : record.device,
                          source: best.source, kind: kind, position: position, remoteMarker: Self.marker(record))
    }

    private func isOwn(_ record: PositionRecord) -> Bool {
        record.deviceID.isEmpty ? record.device == deviceName : record.deviceID == deviceID
    }

    private static func marker(_ record: PositionRecord) -> String {
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
        guard isICloudActive, let record = record(for: position, book: book) else { return }
        pending[record.document] = record
        pushTask?.cancel()
        pushTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    func pushNow(_ position: ReadingPosition, for book: LibraryBook) async {
        guard isICloudActive else { return }
        if let record = record(for: position, book: book) { pending[record.document] = record }
        pushTask?.cancel()
        pushTask = nil
        flush()
    }

    private func record(for position: ReadingPosition, book: LibraryBook) -> PositionRecord? {
        // Another device resolves the place by its XPointer; progress alone
        // would land on the wrong page.
        guard let xpointer = position.xpointer, xpointer.hasPrefix("/body/DocFragment["), position.fraction.isFinite else {
            return nil
        }
        return PositionRecord(document: book.documentDigest, progress: xpointer, percentage: position.fraction,
                              device: deviceName, deviceID: deviceID, timestamp: nil)
    }

    private func flush() {
        for (document, record) in pending {
            let marker = "\(record.progress)|\(record.percentage)"
            if lastPushed[document] != marker, isICloudActive {
                iCloud.save(record)
                lastPushed[document] = marker
            }
            pending[document] = nil
        }
    }

    // MARK: Reader exchange (reading-progress v1)

    /// Keeps the reader's positions for matching library books, and returns the
    /// library positions that are further along, to be offered on the reader.
    /// A reader has no trusted clock, so a place gets the time it was first
    /// seen changed; an unchanged place keeps its earlier time.
    func exchange(with list: ReaderReadingList, readerName: String, library: [LibraryBook], now: Date = Date())
        -> [PositionRecord] {
        guard readerExchangeEnabled else { return [] }
        let byDigest = Dictionary(list.books.map { ($0.document, $0) }, uniquingKeysWith: { first, _ in first })
        var received: [PositionRecord] = []
        var outgoing: [PositionRecord] = []
        for book in library {
            guard let entry = byDigest[book.documentDigest] else { continue }
            if let progress = entry.progress {
                let previous = readerPositions.record(for: book.documentDigest)
                let seen = previous?.progress == progress ? previous?.timestamp : nil
                received.append(PositionRecord(document: book.documentDigest, progress: progress, percentage: entry.percentage,
                                               device: readerName, deviceID: "reader:\(list.deviceID)",
                                               timestamp: entry.updated.flatMap { $0 > 0 ? $0 : nil }
                                                   ?? seen ?? Int(now.timeIntervalSince1970)))
            }
            if let local = book.position, let xpointer = local.xpointer, local.fraction > entry.percentage + 0.004 {
                outgoing.append(PositionRecord(document: book.documentDigest, progress: xpointer, percentage: local.fraction,
                                               device: deviceName, deviceID: deviceID, timestamp: nil))
            }
        }
        readerPositions.save(received)
        pendingReceived = received.count
        return outgoing
    }

    /// Called once the offers reached the reader, or the exchange failed.
    func exchangeFinished(readerName: String, sent: Int, error: Error?, now: Date = Date()) {
        if let error {
            readerExchangeError = error.localizedDescription
        } else {
            readerExchangeError = nil
            lastReaderExchange = ReaderExchange(device: readerName, date: now, received: pendingReceived, sent: sent)
        }
        pendingReceived = 0
    }

    private var dismissedMarkers: [String: [String]] {
        defaults.dictionary(forKey: Keys.dismissedMarkers) as? [String: [String]] ?? [:]
    }
}
