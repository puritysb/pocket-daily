import CryptoKit
import Foundation

/// A position that survives different screens, fonts and devices: an XPointer
/// in the format the X3/X4 firmware shares (crengine-style) plus overall
/// progress. The CFI is this app's own precise restore point.
struct ReadingPosition: Codable, Hashable, Sendable {
    var fraction: Double
    var xpointer: String?
    var cfi: String?
    var chapter: String?
    var updatedAt: Date
}

struct LibraryBook: Codable, Identifiable, Hashable, Sendable {
    enum Origin: Codable, Hashable, Sendable {
        case imported
        case article(UUID)
        case written
        case welcome
    }

    var id: UUID
    var title: String
    var author: String
    var language: String
    var fileName: String
    var byteCount: Int64
    /// Partial MD5 of the file bytes (the reader computes the same); the book's identity for sync.
    var documentDigest: String
    var origin: Origin
    var addedAt: Date
    var lastOpenedAt: Date?
    var hasCover: Bool
    var position: ReadingPosition?

    var progress: Double { min(max(position?.fraction ?? 0, 0), 1) }
    var isArticle: Bool { if case .article = origin { true } else { false } }
}

enum LibraryError: LocalizedError, Equatable {
    case unavailable
    case unsupportedFormat(String)
    case unreadableText
    case emptyText
    case missing

    var errorDescription: String? {
        switch self {
        case .unavailable: "The library folder is unavailable. Check free storage, then open Pocket Daily again."
        case .unsupportedFormat(let ext):
            ext == "xtc" || ext == "xtch"
                ? "XTC books are pre-rendered for the reader. Send them from Reader → Files instead."
                : "Pocket Daily reads EPUB, TXT and Markdown files. Convert this file to EPUB and import it again."
        case .unreadableText: "This text file's encoding is not supported. Save it as UTF-8 and import it again."
        case .emptyText: "This text file is empty."
        case .missing: "This book's file is missing. Remove it from the library and import it again."
        }
    }
}

/// Books live in Application Support as `<id>/record.json` plus the untouched
/// book file, so the bytes sent to a reader match the bytes read here.
actor BookLibrary {
    static let shared = BookLibrary()

    private let root: URL?
    private let manager = FileManager.default

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pocket/Library", isDirectory: true)
    }

    func books() throws -> [LibraryBook] {
        guard let root else { throw LibraryError.unavailable }
        guard manager.fileExists(atPath: root.path) else { return [] }
        var books: [LibraryBook] = []
        for folder in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            guard let id = UUID(uuidString: folder.lastPathComponent) else { continue }
            let recordURL = folder.appendingPathComponent("record.json")
            guard let data = try? Data(contentsOf: recordURL),
                  let book = try? JSONDecoder.library.decode(LibraryBook.self, from: data), book.id == id else { continue }
            books.append(book)
        }
        return books.sorted { ($0.lastOpenedAt ?? $0.addedAt) > ($1.lastOpenedAt ?? $1.addedAt) }
    }

    func fileURL(for book: LibraryBook) throws -> URL {
        let url = try folder(book.id).appendingPathComponent(book.fileName)
        guard manager.fileExists(atPath: url.path) else { throw LibraryError.missing }
        return url
    }

    func coverURL(for book: LibraryBook) -> URL? {
        guard book.hasCover, let folder = try? folder(book.id) else { return nil }
        return folder.appendingPathComponent("cover")
    }

    /// Imports a user-selected file. EPUBs are kept byte-for-byte; text and
    /// Markdown become EPUBs so the phone and the reader open the same book.
    func importFile(at source: URL) async throws -> LibraryBook {
        let accessing = source.startAccessingSecurityScopedResource()
        defer { if accessing { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        switch ext {
        case "epub":
            return try add(copying: source, origin: .imported)
        case "txt", "text", "md", "markdown":
            let text = try Self.decodeText(Data(contentsOf: source))
            let title = source.deletingPathExtension().lastPathComponent
            let document = Self.document(title: title, text: text, markdown: ext == "md" || ext == "markdown")
            return try await addGenerated(document, origin: .written)
        default:
            throw LibraryError.unsupportedFormat(ext)
        }
    }

    func importArticle(_ article: ArticleRecord) async throws -> LibraryBook {
        let url = try await ArticleEPUB.write(article)
        defer { try? manager.removeItem(at: url.deletingLastPathComponent()) }
        let existing = try books().first { $0.origin == .article(article.id) }
        let digest = try KOReaderDocumentDigest.partialMD5(of: url)
        if let existing, existing.documentDigest == digest { return existing }
        var book = try add(copying: url, origin: .article(article.id), allowDuplicate: existing != nil)
        if let existing {
            book.position = existing.position
            try save(book)
            try remove(existing.id)
        }
        return book
    }

    func importDocument(_ document: EPUBDocument, origin: LibraryBook.Origin) async throws -> LibraryBook {
        try await addGenerated(document, origin: origin)
    }

    func remove(_ id: UUID) throws {
        let folder = try folder(id)
        guard manager.fileExists(atPath: folder.path) else { return }
        try manager.removeItem(at: folder)
    }

    @discardableResult
    func update(_ id: UUID, _ change: (inout LibraryBook) -> Void) throws -> LibraryBook {
        let url = try folder(id).appendingPathComponent("record.json")
        var book = try JSONDecoder.library.decode(LibraryBook.self, from: Data(contentsOf: url))
        change(&book)
        try save(book)
        return book
    }

    // MARK: Private

    private func folder(_ id: UUID) throws -> URL {
        guard let root else { throw LibraryError.unavailable }
        return root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func addGenerated(_ document: EPUBDocument, origin: LibraryBook.Origin) async throws -> LibraryBook {
        guard let root else { throw LibraryError.unavailable }
        let scratch = root.appendingPathComponent(".import", isDirectory: true)
        let url = try await EPUBExporter.write(document, to: scratch)
        defer { try? manager.removeItem(at: url.deletingLastPathComponent()) }
        return try add(copying: url, origin: origin)
    }

    private func add(copying source: URL, origin: LibraryBook.Origin, allowDuplicate: Bool = false) throws -> LibraryBook {
        let info = try EPUBPackageReader.inspect(source)
        let digest = try KOReaderDocumentDigest.partialMD5(of: source)
        if !allowDuplicate, let existing = try books().first(where: { $0.documentDigest == digest }) {
            return existing
        }
        let id = UUID()
        let folder = try folder(id)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let fileName = Self.safeFileName(source.lastPathComponent)
            try manager.copyItem(at: source, to: folder.appendingPathComponent(fileName))
            if let cover = info.cover {
                try cover.write(to: folder.appendingPathComponent("cover"), options: .atomic)
            }
            let size = (try? manager.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.int64Value ?? 0
            let fallbackTitle = source.deletingPathExtension().lastPathComponent
            let book = LibraryBook(id: id, title: info.title.isEmpty ? fallbackTitle : info.title,
                                   author: info.author, language: info.language, fileName: fileName,
                                   byteCount: size, documentDigest: digest, origin: origin, addedAt: Date(),
                                   lastOpenedAt: nil, hasCover: info.cover != nil, position: nil)
            try save(book)
            return book
        } catch {
            try? manager.removeItem(at: folder)
            throw error
        }
    }

    private func save(_ book: LibraryBook) throws {
        let data = try JSONEncoder.library.encode(book)
        try data.write(to: try folder(book.id).appendingPathComponent("record.json"), options: .atomic)
    }

    static func safeFileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.isEmpty || cleaned.hasPrefix(".") ? "book.epub" : cleaned
    }

    static func decodeText(_ data: Data) throws -> String {
        var bytes = data
        if bytes.starts(with: [0xef, 0xbb, 0xbf]) { bytes.removeFirst(3) }
        let text: String
        if let utf8 = String(data: bytes, encoding: .utf8) {
            text = utf8
        } else if data.starts(with: [0xff, 0xfe]) || data.starts(with: [0xfe, 0xff]),
                  let utf16 = String(data: data, encoding: .utf16) {
            text = utf16
        } else if let korean = String(data: bytes, encoding: String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.dosKorean.rawValue)))) {
            text = korean
        } else {
            throw LibraryError.unreadableText
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LibraryError.emptyText }
        return text
    }

    /// Fixed publication time for converted text: with the identifier derived
    /// from the content, the same file converts to the same EPUB bytes on every
    /// device, so its sync fingerprint matches everywhere.
    static let convertedModified = Date(timeIntervalSince1970: 946_684_800)

    static func stableIdentifier(title: String, text: String, markdown: Bool) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("pocket-daily-text-v1\n\(markdown)\n\(title)\n\(text)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Markdown `#`/`##` headings start chapters; other text keeps its paragraphs.
    static func document(title: String, text: String, markdown: Bool) -> EPUBDocument {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Reading" : title
        let identifier = stableIdentifier(title: name, text: normalized, markdown: markdown)
        guard markdown else {
            return EPUBDocument(title: name, chapters: [.init(title: name, paragraphs: paragraphs(normalized))],
                                identifier: identifier, modified: convertedModified)
        }
        var chapters: [EPUBDocument.Chapter] = []
        var heading = name
        var body: [String] = []
        func flush() {
            let paragraphs = paragraphs(body.joined(separator: "\n"))
            if !paragraphs.isEmpty { chapters.append(.init(title: heading, paragraphs: paragraphs)) }
            body = []
        }
        for line in normalized.components(separatedBy: "\n") {
            if let match = line.firstMatch(of: /^#{1,2}\s+(.+?)\s*#*\s*$/) {
                flush()
                heading = String(match.1)
            } else {
                body.append(line)
            }
        }
        flush()
        if chapters.isEmpty { chapters = [.init(title: name, paragraphs: [name])] }
        return EPUBDocument(title: name, chapters: chapters, identifier: identifier, modified: convertedModified)
    }

    private static func paragraphs(_ text: String) -> [String] {
        text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

extension JSONEncoder {
    static let library: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}

extension JSONDecoder {
    static let library: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
