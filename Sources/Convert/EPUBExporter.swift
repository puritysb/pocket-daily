import Foundation

enum EPUBExporter {
    // App-side budgets, not measured hardware guarantees. Includes escaped XHTML wrappers.
    static let maximumSectionBytes = 64 * 1024
    static let maximumInputBytes = 4 * 1024 * 1024
    static let maximumSections = 128
    static let maximumParagraphs = 16_384

    /// Runs off the main actor. Returns a complete .epub in a new UUID subfolder of directory.
    /// Caller owns that folder: copy into the durable transfer queue, then remove the folder.
    /// Cancellation before publication removes partial output; a returned URL belongs to the caller.
    static func write(_ document: EPUBDocument, to directory: URL) async throws -> URL {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try build(document, to: directory)
        }
        return try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
    }

    /// Synchronous core for deterministic tests and command-line fixture generation.
    /// Do not call from the UI actor.
    static func build(_ document: EPUBDocument, to directory: URL) throws -> URL {
        try Task.checkCancellation()
        try validate(document)
        guard directory.isFileURL else { throw EPUBExportError.invalidDestination }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false)
        let partial = folder.appendingPathComponent("book.epub.part")
        let output = folder.appendingPathComponent(filename(document))
        do {
            guard manager.createFile(atPath: partial.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
            let handle = try FileHandle(forWritingTo: partial)
            do {
                let zip = EPUBStoredZIP(handle: handle)
                try zip.add(path: "mimetype", data: Data("application/epub+zip".utf8))
                if let metadata = document.articleMetadata {
                    guard metadata.count == 523 else { throw EPUBExportError.invalidMetadata }
                    try zip.add(path: "META-INF/pocket-article.bin", data: metadata)
                }
                try zip.add(path: "META-INF/container.xml", data: Data(container.utf8))
                var sections: [Section] = []
                for chapter in document.chapters {
                    try append(chapter, language: document.language, zip: zip, sections: &sections)
                }
                let nav = navigation(document, sections: sections)
                guard nav.utf8.count <= maximumSectionBytes else { throw EPUBExportError.navigationTooLarge }
                try zip.add(path: "EPUB/nav.xhtml", data: Data(nav.utf8))
                try zip.add(path: "EPUB/toc.ncx", data: Data(ncx(document, sections: sections).utf8))
                try zip.add(path: "EPUB/package.opf", data: Data(package(document, sections: sections).utf8))
                try zip.finish()
                try handle.synchronize()
                try handle.close()
            } catch {
                // close is best effort here; preserve the actual export failure.
                try? handle.close()
                throw error
            }
            try Task.checkCancellation()
            try manager.moveItem(at: partial, to: output)
            return output
        } catch {
            do { try manager.removeItem(at: folder) }
            catch { throw EPUBExportError.cleanupFailed }
            throw error
        }
    }

    private struct Section {
        let title: String
        let path: String
        var id: String { String(path.dropLast(6)) } // section-N.xhtml
    }

    private static func filename(_ document: EPUBDocument) -> String {
        if document.articleMetadata != nil { return "pd-article-\(document.identifier.uuidString.lowercased()).epub" }
        let safe = document.title.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" ? String($0) : " "
        }.joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        var stem = ""
        var bytes = 0
        for character in safe {
            // File URLs/filesystems may expose decomposed Hangul and accented letters.
            // Budget the decomposed form so the limit survives that normalization.
            let size = String(character).decomposedStringWithCanonicalMapping.utf8.count
            if bytes + size > 120 { break }
            stem.append(character)
            bytes += size
        }
        // Full publication identity prevents two books with the same title overwriting each
        // other after the caller copies them out of their private export folders.
        return "\(stem.isEmpty ? "Reading" : stem)-\(document.identifier.uuidString.lowercased()).epub"
    }

    private static func validate(_ book: EPUBDocument) throws {
        guard !book.chapters.isEmpty, !book.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw EPUBExportError.emptyContent
        }
        guard book.chapters.count <= maximumSections else { throw EPUBExportError.tooManySections }
        guard book.title.utf8.count <= 256, (book.author?.utf8.count ?? 0) <= 256,
              book.author == nil || book.author?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              book.language.utf8.count <= 63,
              // A conservative BCP 47 subset: language, optional script, optional region.
              book.language.range(of: "\\A[A-Za-z]{2,3}(-[A-Za-z]{4})?(-([A-Za-z]{2}|[0-9]{3}))?\\z",
                                  options: .regularExpression) != nil,
              book.modified.timeIntervalSince1970.isFinite,
              (0..<253_402_300_800).contains(book.modified.timeIntervalSince1970) else {
            throw EPUBExportError.invalidMetadata
        }
        try validXML(book.title)
        if let author = book.author { try validXML(author) }
        var bytes = 0
        var paragraphs = 0
        for chapter in book.chapters {
            try Task.checkCancellation()
            guard !chapter.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  chapter.paragraphs.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                throw EPUBExportError.emptyContent
            }
            guard chapter.title.utf8.count <= 256 else { throw EPUBExportError.invalidMetadata }
            try validXML(chapter.title)
            if let source = chapter.sourceURL {
                guard ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
                      let host = source.host, !host.isEmpty, source.user == nil, source.password == nil,
                      source.absoluteString.utf8.count <= 2048 else { throw EPUBExportError.invalidSourceURL }
                try validXML(source.absoluteString)
            }
            paragraphs += chapter.paragraphs.count
            guard paragraphs <= maximumParagraphs else { throw EPUBExportError.inputTooLarge }
            for text in chapter.paragraphs {
                bytes += text.utf8.count
                guard bytes <= maximumInputBytes else { throw EPUBExportError.inputTooLarge }
                try validXML(text)
            }
        }
    }

    private static func validXML(_ text: String) throws {
        for scalar in text.unicodeScalars {
            let value = scalar.value
            guard value == 9 || value == 10 || value == 13 || (0x20...0xD7FF).contains(value)
                    || (0xE000...0xFFFD).contains(value) || (0x10000...0x10FFFF).contains(value) else {
                throw EPUBExportError.invalidText
            }
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func xhtmlStart(title: String, language: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        + "<html xmlns=\"http://www.w3.org/1999/xhtml\" xmlns:epub=\"http://www.idpf.org/2007/ops\" "
        + "xml:lang=\"\(language)\" lang=\"\(language)\"><head><title>\(escape(title))</title></head><body>"
    }

    private static let xhtmlEnd = "</body></html>"

    private static func append(_ chapter: EPUBDocument.Chapter, language: String,
                               zip: EPUBStoredZIP, sections: inout [Section]) throws {
        var part = 1
        var body = ""
        var label: String { part == 1 ? chapter.title : "\(chapter.title) (\(part))" }
        func prefix() -> String {
            var result = xhtmlStart(title: label, language: language) + "<h1>\(escape(label))</h1>"
            if part == 1, let source = chapter.sourceURL {
                let link = escape(source.absoluteString)
                result += "<p><a href=\"\(link)\">\(link)</a></p>"
            }
            return result
        }
        var head = prefix()
        func flush() throws {
            try Task.checkCancellation()
            guard sections.count < maximumSections else { throw EPUBExportError.tooManySections }
            let path = "section-\(sections.count + 1).xhtml"
            try zip.add(path: "EPUB/" + path, data: Data((head + body + xhtmlEnd).utf8))
            sections.append(Section(title: label, path: path))
            part += 1
            body = ""
            head = prefix()
        }
        for original in chapter.paragraphs {
            try Task.checkCancellation()
            if original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            // Normalize line endings; a newline inside a paragraph is an explicit line break.
            let text = original.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let encoded = escape(text).replacingOccurrences(of: "\n", with: "<br />")
            let paragraph = "<p>\(encoded)</p>"
            let capacity = maximumSectionBytes - head.utf8.count - xhtmlEnd.utf8.count
            if body.utf8.count + paragraph.utf8.count <= capacity {
                body += paragraph
                continue
            }
            // Preserve paragraph boundaries when possible, then split oversized paragraphs at
            // extended grapheme boundaries. Never slice a UTF-8 sequence or an XML entity.
            if !body.isEmpty { try flush() }
            var fragment = ""
            var fragmentBytes = 0
            for character in text {
                let escaped = character == "\n" ? "<br />" : escape(String(character))
                let bytes = escaped.utf8.count
                let available = maximumSectionBytes - head.utf8.count - xhtmlEnd.utf8.count - 7 // <p></p>
                guard bytes <= available else { throw EPUBExportError.unsplittableCharacter }
                if fragmentBytes + bytes > available {
                    body = "<p>\(fragment)</p>"
                    try flush()
                    fragment = ""
                    fragmentBytes = 0
                }
                guard bytes <= maximumSectionBytes - head.utf8.count - xhtmlEnd.utf8.count - 7 else {
                    throw EPUBExportError.unsplittableCharacter
                }
                fragment += escaped
                fragmentBytes += bytes
            }
            body = "<p>\(fragment)</p>"
        }
        if !body.isEmpty { try flush() }
    }

    private static func navigation(_ book: EPUBDocument, sections: [Section]) -> String {
        let links = sections.map { "<li><a href=\"\($0.path)\">\(escape($0.title))</a></li>" }.joined()
        return xhtmlStart(title: book.title, language: book.language)
            + "<nav epub:type=\"toc\" id=\"toc\"><h1>\(escape(book.title))</h1><ol>\(links)</ol></nav>" + xhtmlEnd
    }

    private static func ncx(_ book: EPUBDocument, sections: [Section]) -> String {
        let points = sections.enumerated().map { index, section in
            "<navPoint id=\"\(section.id)\" playOrder=\"\(index + 1)\"><navLabel><text>\(escape(section.title))"
            + "</text></navLabel><content src=\"\(section.path)\"/></navPoint>"
        }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<ncx xmlns=\"http://www.daisy.org/z3986/2005/ncx/\" version=\"2005-1\" xml:lang=\"\(book.language)\">"
            + "<head><meta name=\"dtb:uid\" content=\"urn:uuid:\(book.identifier.uuidString)\"/>"
            + "<meta name=\"dtb:depth\" content=\"1\"/><meta name=\"dtb:totalPageCount\" content=\"0\"/>"
            + "<meta name=\"dtb:maxPageNumber\" content=\"0\"/></head>"
            + "<docTitle><text>\(escape(book.title))</text></docTitle><navMap>\(points)</navMap></ncx>"
    }

    private static func package(_ book: EPUBDocument, sections: [Section]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        let creator = book.author.map { "<dc:creator>\(escape($0))</dc:creator>" } ?? ""
        let items = sections.map {
            "<item id=\"\($0.id)\" href=\"\($0.path)\" media-type=\"application/xhtml+xml\"/>"
        }.joined()
        let spine = sections.map { "<itemref idref=\"\($0.id)\"/>" }.joined()
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            + "<package xmlns=\"http://www.idpf.org/2007/opf\" version=\"3.0\" unique-identifier=\"book-id\">"
            + "<metadata xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
            + "<dc:identifier id=\"book-id\">urn:uuid:\(book.identifier.uuidString)</dc:identifier>"
            + "<dc:title>\(escape(book.title))</dc:title><dc:language>\(book.language)</dc:language>\(creator)"
            + "<meta property=\"dcterms:modified\">\(formatter.string(from: book.modified))</meta></metadata>"
            + "<manifest><item id=\"nav\" href=\"nav.xhtml\" media-type=\"application/xhtml+xml\" properties=\"nav\"/>"
            + "<item id=\"ncx\" href=\"toc.ncx\" media-type=\"application/x-dtbncx+xml\"/>\(items)</manifest>"
            + "<spine toc=\"ncx\">\(spine)</spine></package>"
    }

    private static let container = """
    <?xml version="1.0" encoding="UTF-8"?>
    <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="EPUB/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
    """
}
