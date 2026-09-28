import Foundation

/// Shared by the app and its share extension. Saving never connects to a reader.
struct ArticleRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var source: String
    var text: String
    var savedAt: Date = Date()
    // Optional fields keep records written by earlier apps and the share extension readable.
    var feedID: UUID?
    var feedTitle: String?
    var publishedAt: Date?
    var summary: String?
    var readAt: Date?
    var archivedAt: Date?
    var downloadError: String?
    var sourceIdentity: UUID?

    static let group = "group.bound.serendipity.pocket.daily"
    static let maximumTextBytes = 4 * 1024 * 1024

    static func sourceURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 2048,
              isPublicHost(host) else {
            throw ArticleError.invalidURL
        }
        return url
    }

    /// Feed content is untrusted, so its links and redirects must not reach the local
    /// network. Names that resolve privately later are not caught; literals and local names are.
    static func isPublicHost(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]."))
        guard !name.isEmpty, name != "localhost" else { return false }
        for suffix in [".localhost", ".local", ".internal", ".home.arpa", ".lan"] where name.hasSuffix(suffix) {
            return false
        }
        if name.contains(":") { return false } // IPv6 literals are never needed for articles.
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        let octets = parts.compactMap { UInt8($0) }
        if octets.count == 4, parts.count == 4 {
            switch (octets[0], octets[1]) {
            case (0, _), (10, _), (127, _), (169, 254), (192, 168), (255, _): return false
            case (172, 16...31), (100, 64...127): return false
            default: return true
            }
        }
        // A bare number or single label (for example "router") only resolves locally.
        return parts.count > 1 && !parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 256, title.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }), (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !source.isEmpty),
              text.utf8.count <= Self.maximumTextBytes else { throw ArticleError.invalidContent }
        if !source.isEmpty { _ = try Self.sourceURL(source) }
    }
}

struct ArticleSummary: Identifiable, Sendable {
    let id: UUID
    let title: String
    let source: String
    let preview: String
    let hasText: Bool
    let savedAt: Date
    let feedID: UUID?
    let feedTitle: String?
    let publishedAt: Date?
    let isRead: Bool
    let isArchived: Bool
    let downloadError: String?
    init(_ record: ArticleRecord) {
        id = record.id; title = record.title; source = record.source
        preview = String((record.text.isEmpty ? (record.summary ?? "") : record.text).prefix(240))
        hasText = !record.text.isEmpty; savedAt = record.savedAt
        feedID = record.feedID; feedTitle = record.feedTitle; publishedAt = record.publishedAt
        isRead = record.readAt != nil; isArchived = record.archivedAt != nil
        downloadError = record.downloadError
    }
}

enum ArticleError: LocalizedError {
    case invalidURL, invalidContent, unavailable, unreadable, tooLarge
    var errorDescription: String? {
        switch self {
        case .invalidURL: "Use an HTTPS article link without a username or password."
        case .invalidContent: "Add a title (up to 256 UTF-8 bytes) and readable text (up to 4 MiB)."
        case .unavailable: "The shared article storage is unavailable. Open Pocket Daily after checking the app installation."
        case .unreadable: "The article text could not be extracted. Share selected text or paste the body below."
        case .tooLarge: "This page is too large. Share a shorter selection of text instead."
        }
    }
}

/// One atomic file per record avoids a read-modify-write index shared by two processes.
/// A failed save keeps the previous copy; only explicit deletion removes an article.
actor ArticleStore {
    static let shared = ArticleStore()
    private let root: URL?
    init(root: URL? = nil) {
#if os(macOS)
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pocket/Articles", isDirectory: true)
#else
        self.root = root ?? FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ArticleRecord.group)?
            .appendingPathComponent("Articles", isDirectory: true)
#endif
    }
    func summaries() throws -> [ArticleSummary] {
        guard let root else { throw ArticleError.unavailable }
        guard FileManager.default.fileExists(atPath: root.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "json" }.map { url in
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1024 * 1024 else {
                    throw ArticleError.tooLarge
                }
                let record = try JSONDecoder().decode(ArticleRecord.self, from: Data(contentsOf: url))
                guard url.deletingPathExtension().lastPathComponent == record.id.uuidString else { throw ArticleError.invalidContent }
                try record.validate()
                return ArticleSummary(record)
            }.sorted { $0.savedAt > $1.savedAt }
    }
    func load(_ id: UUID) throws -> ArticleRecord {
        guard let root else { throw ArticleError.unavailable }
        let url = root.appendingPathComponent(id.uuidString + ".json")
        guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 32 * 1024 * 1024 else {
            throw ArticleError.tooLarge
        }
        let record = try JSONDecoder().decode(ArticleRecord.self, from: Data(contentsOf: url))
        guard record.id == id else { throw ArticleError.invalidContent }
        try record.validate()
        return record
    }
    func save(_ record: ArticleRecord) throws {
        try record.validate()
        guard let root else { throw ArticleError.unavailable }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent(record.id.uuidString + ".json"), options: .atomic)
    }
    func setRead(_ id: UUID, _ read: Bool) throws {
        var record = try load(id)
        record.readAt = read ? Date() : nil
        try save(record)
    }

    func setArchived(_ id: UUID, _ archived: Bool) throws {
        var record = try load(id)
        record.archivedAt = archived ? Date() : nil
        try save(record)
    }

    /// Feed refreshes never overwrite an edited/read copy or resurrect a deleted item.
    func insertFromFeed(_ record: ArticleRecord) throws -> Bool {
        guard let root else { throw ArticleError.unavailable }
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("Deleted/" + record.id.uuidString).path) ||
            FileManager.default.fileExists(atPath: root.appendingPathComponent(record.id.uuidString + ".json").path) { return false }
        if let sourceIdentity = record.sourceIdentity,
           FileManager.default.fileExists(atPath: root.appendingPathComponent("Deleted/" + sourceIdentity.uuidString).path) { return false }
        try save(record)
        return true
    }

    func containsOrDeleted(_ id: UUID) throws -> Bool {
        guard let root else { throw ArticleError.unavailable }
        return FileManager.default.fileExists(atPath: root.appendingPathComponent("Deleted/" + id.uuidString).path) ||
            FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString + ".json").path)
    }

    func remove(_ id: UUID) throws {
        guard let root else { throw ArticleError.unavailable }
        let deleted = root.appendingPathComponent("Deleted", isDirectory: true)
        try FileManager.default.createDirectory(at: deleted, withIntermediateDirectories: true)
        // Write the tombstone first: a crash cannot make the next refresh restore a deletion.
        // A damaged record must still be deletable; only its source tombstone is lost.
        let record = try? load(id)
        try Data().write(to: deleted.appendingPathComponent(id.uuidString), options: .atomic)
        if let sourceIdentity = record?.sourceIdentity {
            try Data().write(to: deleted.appendingPathComponent(sourceIdentity.uuidString), options: .atomic)
        }
        let file = root.appendingPathComponent(id.uuidString + ".json")
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
}
