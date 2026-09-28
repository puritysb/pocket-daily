import Foundation
import libxml2

/// Memory-only HTML parsing. No browser, scripts, CSS, image requests or page subresources.
enum ArticleExtraction {
    static let maximumBytes = 4 * 1024 * 1024

    static func fetch(_ source: String, configuration: URLSessionConfiguration = .ephemeral) async throws -> ArticleRecord {
        let result = try await download(source, accept: "text/html, application/xhtml+xml",
                                        allowedTypes: ["text/html", "application/xhtml+xml"], configuration: configuration)
        let worker = Task.detached(priority: .userInitiated) {
            try parse(result.data, source: result.url.absoluteString)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    /// Bounded, cookie-free transport shared by article and feed retrieval.
    static func download(_ source: String, accept: String, allowedTypes: Set<String>? = nil,
                         configuration: URLSessionConfiguration = .ephemeral) async throws -> (data: Data, url: URL) {
        let url = try ArticleRecord.sourceURL(source)
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
              allowedTypes == nil || allowedTypes?.contains(response.mimeType?.lowercased() ?? "") == true else {
            throw ArticleError.unreadable
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw ArticleError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw ArticleError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return (data, response.url ?? url)
    }

    private final class HTTPSRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            guard let url = request.url, (try? ArticleRecord.sourceURL(url.absoluteString)) != nil else {
                completionHandler(nil); return
            }
            completionHandler(request)
        }
    }

    static func parse(_ data: Data, source: String) throws -> ArticleRecord {
        guard data.count <= maximumBytes else { throw ArticleError.tooLarge }
        // First version accepts UTF-8 only. Never silently decode broken text as replacement characters.
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ArticleError.unreadable }
        guard let context = htmlNewParserCtxt() else { throw ArticleError.unreadable }
        defer { htmlFreeParserCtxt(context) }
        let options = HTML_PARSE_NONET.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
        let doc = data.withUnsafeBytes {
            htmlCtxtReadMemory(context, $0.bindMemory(to: CChar.self).baseAddress, Int32(data.count), nil,
                               "UTF-8", Int32(options))
        }
        guard let doc else { throw ArticleError.unreadable }
        defer { xmlFreeDoc(doc) }
        guard context.pointee.lastError.level != XML_ERR_FATAL else { throw ArticleError.unreadable }
        let root = xmlDocGetRootElement(doc)
        var title = ""
        var article: xmlNodePtr?
        var main: xmlNodePtr?
        var body: xmlNodePtr?
        var count = 0
        func locate(_ first: xmlNodePtr?, depth: Int = 0) throws {
            guard depth < 128 else { throw ArticleError.tooLarge }
            var next = first
            while let node = next {
                try Task.checkCancellation()
                next = node.pointee.next
                count += 1
                guard count <= 100_000 else { throw ArticleError.tooLarge }
                guard node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name else { continue }
                let tag = String(cString: name)
                if ["script", "style", "template", "noscript", "nav", "footer"].contains(tag) || xmlHasProp(node, "hidden") != nil { continue }
                if tag == "title", title.isEmpty, let value = xmlNodeGetContent(node) {
                    title = String(cString: value).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                    xmlFree(value)
                }
                if tag == "article", article == nil { article = node }
                if tag == "main", main == nil { main = node }
                if tag == "body" { body = node }
                try locate(node.pointee.children, depth: depth + 1)
            }
        }
        try locate(root)
        guard let content = article ?? main ?? body else { throw ArticleError.unreadable }
        var output = ""
        var space = false
        let excluded: Set<String> = ["script", "style", "noscript", "template", "nav", "header", "footer", "form",
                                     "iframe", "object", "svg", "math", "button", "select"]
        let blocks: Set<String> = ["p", "div", "section", "article", "li", "blockquote", "pre", "h1", "h2", "h3",
                                   "h4", "h5", "h6", "tr", "figcaption", "dt", "dd", "hr"]
        func boundary() { if !output.isEmpty, !output.hasSuffix("\n\n") { output += output.hasSuffix("\n") ? "\n" : "\n\n" }; space = false }
        func extract(_ first: xmlNodePtr?, depth: Int = 0, pre: Bool = false) throws {
            guard depth < 128 else { throw ArticleError.tooLarge }
            var next = first
            while let node = next {
                try Task.checkCancellation()
                next = node.pointee.next
                if node.pointee.type == XML_TEXT_NODE, let value = node.pointee.content {
                    for ch in String(cString: value) {
                        if !pre && (ch == " " || ch == "\n" || ch == "\t" || ch == "\r") { space = !output.isEmpty }
                        else {
                            if space, !output.hasSuffix("\n") { output += " " }
                            output.append(ch); space = false
                        }
                    }
                    continue
                }
                guard node.pointee.type == XML_ELEMENT_NODE, let name = node.pointee.name else { continue }
                let tag = String(cString: name)
                if excluded.contains(tag) || xmlHasProp(node, "hidden") != nil { continue }
                if tag == "br" { output += "\n"; space = false; continue }
                if blocks.contains(tag) { boundary() }
                if tag == "td" || tag == "th" { space = !output.isEmpty }
                try extract(node.pointee.children, depth: depth + 1, pre: pre || tag == "pre")
                if blocks.contains(tag) { boundary() }
            }
        }
        try extract(content.pointee.children)
        output = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.utf8.count <= maximumBytes else { throw ArticleError.tooLarge }
        guard !output.isEmpty else { throw ArticleError.unreadable }
        return ArticleRecord(title: title.isEmpty ? "Article" : title, source: source, text: output)
    }
}
