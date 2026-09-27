import Foundation

/// Keeps reading positions in step without any server: iCloud key-value
/// storage for the same Apple ID's devices, and the connected X3/X4 reader.
/// Reading never waits for either; the page never moves without asking.
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

    @Published private(set) var lastReaderExchange: (device: String, date: Date, books: Int)?
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
    }

    // MARK: Positions

    /// The furthest newer position from another device. Never moves the page itself.
    func suggestion(for book: LibraryBook, current: ReadingPosition?) async -> Suggestion? {
        let document = book.documentDigest
        var candidates: [RemotePosition] = []
        if isICloudActive, let record = iCloud.record(for: document) {
            candidates.append(RemotePosition(source: .iCloud, record: record))
        }
        if readerExchangeEnabled, let record = readerPositions.record(for: document) {
            candidates.append(RemotePosition(source: .reader(record.device), record: record))
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
    func exchange(with list: ReaderReadingList, readerName: String, library: [LibraryBook], now: Date = Date())
        -> [PositionRecord] {
        guard readerExchangeEnabled else { return [] }
        let byDigest = Dictionary(list.books.map { ($0.document, $0) }, uniquingKeysWith: { first, _ in first })
        var received: [PositionRecord] = []
        var outgoing: [PositionRecord] = []
        for book in library {
            guard let entry = byDigest[book.documentDigest] else { continue }
            if let progress = entry.progress {
                received.append(PositionRecord(document: book.documentDigest, progress: progress, percentage: entry.percentage,
                                               device: readerName, deviceID: "reader:\(list.deviceID)",
                                               timestamp: entry.updated.flatMap { $0 > 0 ? $0 : nil }))
            }
            if let local = book.position, let xpointer = local.xpointer, local.fraction > entry.percentage + 0.004 {
                outgoing.append(PositionRecord(document: book.documentDigest, progress: xpointer, percentage: local.fraction,
                                               device: deviceName, deviceID: deviceID, timestamp: nil))
            }
        }
        readerPositions.save(received)
        lastReaderExchange = (readerName, now, received.count + outgoing.count)
        return outgoing
    }

    private var dismissedMarkers: [String: [String]] {
        defaults.dictionary(forKey: Keys.dismissedMarkers) as? [String: [String]] ?? [:]
    }
}
