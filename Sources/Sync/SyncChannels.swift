import Foundation

/// Where a position from another device came from.
enum SyncSource: Codable, Equatable, Sendable {
    case iCloud
    case reader(String)
}

/// A position record from either channel.
struct RemotePosition: Equatable, Sendable {
    var source: SyncSource
    var record: PositionRecord
}

// MARK: iCloud

/// The key-value backing for iCloud records; `NSUbiquitousKeyValueStore` in the
/// app, a dictionary in tests.
protocol UbiquitousValues: AnyObject {
    func dictionary(forKey key: String) -> [String: Any]?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    var dictionaryRepresentation: [String: Any] { get }
    @discardableResult func synchronize() -> Bool
}

extension NSUbiquitousKeyValueStore: UbiquitousValues {}

/// Positions for the same Apple ID's devices through iCloud key-value storage.
/// Each device keeps its own record per book (`position.v2.<book>.<device>`),
/// so a device reading an earlier part never overwrites another's place.
/// Only the book fingerprint and position are stored; no title or file.
final class ICloudProgressStore {
    static let prefix = "position.v2."
    static let capacity = 800

    private let values: UbiquitousValues

    init(values: UbiquitousValues = NSUbiquitousKeyValueStore.default) {
        self.values = values
    }

    static func key(document: String, deviceID: String) -> String { prefix + document + "." + deviceID }

    /// Every device's record for a book, own included.
    func records(for document: String) -> [PositionRecord] {
        guard KOReaderDocumentDigest.isDigest(document) else { return [] }
        let bookPrefix = Self.prefix + document + "."
        return values.dictionaryRepresentation.compactMap { key, value in
            guard key.hasPrefix(bookPrefix), let raw = value as? [String: Any] else { return nil }
            return Self.decode(raw, document: document)
        }
    }

    private static func decode(_ raw: [String: Any], document: String) -> PositionRecord? {
        guard let progress = raw["progress"] as? String, progress.hasPrefix("/body/DocFragment["),
              let percentage = (raw["percentage"] as? NSNumber)?.doubleValue, percentage.isFinite,
              let device = raw["device"] as? String, !device.isEmpty,
              let deviceID = raw["device_id"] as? String, !deviceID.isEmpty else { return nil }
        return PositionRecord(document: document, progress: progress, percentage: min(max(percentage, 0), 1),
                              device: device, deviceID: deviceID,
                              timestamp: (raw["timestamp"] as? NSNumber)?.intValue)
    }

    func save(_ record: PositionRecord, now: Date = Date()) {
        guard KOReaderDocumentDigest.isDigest(record.document), !record.deviceID.isEmpty,
              !record.deviceID.contains(".") else { return }
        values.set([
            "progress": record.progress,
            "percentage": record.percentage,
            "device": record.device,
            "device_id": record.deviceID,
            "timestamp": Int(now.timeIntervalSince1970),
        ], forKey: Self.key(document: record.document, deviceID: record.deviceID))
        trim()
        values.synchronize()
    }

    /// Keeps the store under iCloud's key limit, dropping the oldest records.
    private func trim() {
        let records = values.dictionaryRepresentation.filter { $0.key.hasPrefix(Self.prefix) }
        guard records.count > Self.capacity else { return }
        let oldest = records.sorted {
            (($0.value as? [String: Any])?["timestamp"] as? NSNumber)?.intValue ?? 0
                < (($1.value as? [String: Any])?["timestamp"] as? NSNumber)?.intValue ?? 0
        }
        for (key, _) in oldest.prefix(records.count - Self.capacity) { values.removeObject(forKey: key) }
    }
}

// MARK: Reader exchange

/// One book in the reader's `GET /api/pocket/v1/reading` list (reading-progress v1).
struct ReaderReadingEntry: Decodable, Equatable, Sendable {
    var path: String
    var document: String
    var filenameDocument: String?
    var progress: String?
    var percentage: Double
    var updated: Int?
    var seq: Int?
}

struct ReaderReadingList: Decodable, Equatable, Sendable {
    var v: Int
    var deviceID: String
    var books: [ReaderReadingEntry]

    static let maximumBytes = 8 * 1024

    /// Rejects replies for another reader or with malformed entries instead of guessing.
    static func decode(_ data: Data, deviceID: String) throws -> ReaderReadingList {
        guard data.count <= maximumBytes else { throw CrossPointClient.ClientError.unexpectedMessage("Reader reply is too large.") }
        var list = try JSONDecoder().decode(ReaderReadingList.self, from: data)
        guard list.v == 1, list.deviceID == deviceID, list.books.count <= 32 else {
            throw CrossPointClient.ClientError.unexpectedMessage("The reader sent reading positions for another device.")
        }
        list.books = list.books.map { entry in
            var entry = entry
            entry.document = entry.document.lowercased()
            return entry
        }.filter {
            KOReaderDocumentDigest.isDigest($0.document) && $0.percentage.isFinite
                && (0...1).contains($0.percentage)
                && ($0.progress.map { $0.hasPrefix("/body/DocFragment[") && $0.utf8.count <= 512 } ?? true)
        }
        return list
    }
}

/// Positions last reported by connected readers, kept on this device so a book
/// can offer them when it opens, with no network.
final class ReaderPositionStore {
    private let defaults: UserDefaults
    private static let key = "readerPositions.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func record(for document: String) -> PositionRecord? {
        guard let raw = (defaults.dictionary(forKey: Self.key) as? [String: Data])?[document] else { return nil }
        return try? JSONDecoder().decode(PositionRecord.self, from: raw)
    }

    func save(_ records: [PositionRecord]) {
        var all = defaults.dictionary(forKey: Self.key) as? [String: Data] ?? [:]
        for record in records {
            if let data = try? JSONEncoder().encode(record) { all[record.document] = data }
        }
        if all.count > 400 {
            let sorted = all.compactMap { key, value in
                (try? JSONDecoder().decode(PositionRecord.self, from: value)).map { (key, $0.timestamp ?? 0) }
            }.sorted { $0.1 < $1.1 }
            for (key, _) in sorted.prefix(all.count - 400) { all[key] = nil }
        }
        defaults.set(all, forKey: Self.key)
    }
}
