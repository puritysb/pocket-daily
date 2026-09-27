import Foundation

/// Article identity and list metadata travel atomically inside the EPUB, never as a sidecar.
enum ArticleEPUB {
    static func write(_ article: ArticleRecord) async throws -> URL {
        try article.validate()
        let source = article.source.isEmpty ? nil : try ArticleRecord.sourceURL(article.source)
        let metadata = try metadata(article)
        let document = EPUBDocument(title: article.title, chapters: [
            .init(title: article.title, paragraphs: article.text.components(separatedBy: "\n\n"), sourceURL: source)
        ], identifier: article.id, modified: article.savedAt, articleMetadata: metadata)
        return try await EPUBExporter.write(document, to: TextDocument.directory)
    }

    static func metadata(_ article: ArticleRecord) throws -> Data {
        try article.validate()
        let host = URL(string: article.source)?.host ?? "Saved text"
        guard host.utf8.count <= 253, article.savedAt.timeIntervalSince1970 >= 0,
              article.savedAt.timeIntervalSince1970 < 253_402_300_800 else { throw ArticleError.invalidContent }
        var bytes = Data("PDA1".utf8)
        let epoch = UInt64(article.savedAt.timeIntervalSince1970)
        for shift in stride(from: 0, to: 64, by: 8) { bytes.append(UInt8(truncatingIfNeeded: epoch >> shift)) }
        for (text, capacity) in [(article.title, 257), (host, 254)] {
            guard !text.utf8.contains(0) else { throw ArticleError.invalidContent }
            bytes.append(contentsOf: text.utf8)
            bytes.append(Data(repeating: 0, count: capacity - text.utf8.count))
        }
        return bytes
    }

    static func isFilename(_ name: String) -> Bool {
        guard name.hasPrefix("pd-article-"), name.hasSuffix(".epub"), name.count == 52 else { return false }
        return UUID(uuidString: String(name.dropFirst(11).dropLast(5))) != nil
    }
}
