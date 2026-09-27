import Foundation

/// Shared by the app and its share extension. Saving never connects to a reader.
struct ArticleRecord: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    var source: String
    var text: String
    var savedAt: Date = Date()

    static let group = "group.bound.serendipity.pocket.daily"
    static let maximumTextBytes = 4 * 1024 * 1024

    static func sourceURL(_ text: String) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.absoluteString.utf8.count <= 2048 else {
            throw ArticleError.invalidURL
        }
        return url
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
    init(_ record: ArticleRecord) {
        id = record.id; title = record.title; source = record.source
        preview = String(record.text.prefix(240)); hasText = !record.text.isEmpty; savedAt = record.savedAt
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
    func remove(_ id: UUID) throws {
        guard let root else { throw ArticleError.unavailable }
        try FileManager.default.removeItem(at: root.appendingPathComponent(id.uuidString + ".json"))
    }
}
