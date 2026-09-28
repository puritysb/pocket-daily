import CryptoKit
import Foundation
import libxml2

struct ArticleFeed: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var url: String
    var title: String
    var lastRefreshedAt: Date?
    var lastError: String?
}

struct FeedEntry: Sendable {
    let id: UUID
    let title: String
    let source: String
    let text: String
    let summary: String
    let publishedAt: Date?
}

struct ParsedArticleFeed: Sendable {
    let title: String
    let entries: [FeedEntry]
}

enum ArticleFeedError: LocalizedError {
    case invalidFeed, duplicate, limit, busy, networkDisabled
    var errorDescription: String? {
        switch self {
        case .invalidFeed: "This is not a supported RSS 2.0 or Atom feed. Copy the publisher’s HTTPS feed URL and try again."
        case .duplicate: "You already subscribe to this feed."
        case .limit: "You can follow up to 50 feeds. Remove a subscription before adding another."
        case .busy: "This feed is already refreshing. Please wait for it to finish."
        case .networkDisabled: "Leave demo mode and keep the app open to add or refresh subscriptions."
        }
    }
}

/// RSS 2.0 and Atom 1.0, with namespace-aware fields and no external entities/resources.
/// DTDs are rejected before any node content is expanded. Payload, depth and node limits
/// also apply to well-formed but hostile feeds.
enum ArticleFeedParser {
    private static let atom = "http://www.w3.org/2005/Atom"
    private static let content = "http://purl.org/rss/1.0/modules/content/"

    static func parse(_ data: Data, source: URL) throws -> ParsedArticleFeed {
        guard data.count <= ArticleExtraction.maximumBytes else { throw ArticleError.tooLarge }
        let options = XML_PARSE_NONET.rawValue | XML_PARSE_NOERROR.rawValue | XML_PARSE_NOWARNING.rawValue
        let document = data.withUnsafeBytes {
            xmlReadMemory($0.bindMemory(to: CChar.self).baseAddress, Int32(data.count), source.absoluteString, nil, Int32(options))
        }
        guard let document else { throw ArticleFeedError.invalidFeed }
        defer { xmlFreeDoc(document) }
        guard document.pointee.intSubset == nil, document.pointee.extSubset == nil,
              let root = xmlDocGetRootElement(document) else { throw ArticleFeedError.invalidFeed }
        var nodes = 0
        func check(_ first: xmlNodePtr?, depth: Int) throws {
            guard depth < 64 else { throw ArticleError.tooLarge }
            var next = first
            while let node = next {
                try Task.checkCancellation()
                nodes += 1
                guard nodes <= 50_000 else { throw ArticleError.tooLarge }
                try check(node.pointee.children, depth: depth + 1)
                next = node.pointee.next
            }
        }
        try check(root, depth: 0)
        let isAtom = name(root) == "feed" && namespace(root) == atom
        let container: xmlNodePtr
        if isAtom { container = root }
        else if name(root) == "rss", namespace(root).isEmpty,
                let channel = children(root, "channel", ns: "").first { container = channel }
        else { throw ArticleFeedError.invalidFeed }
        let ns = isAtom ? atom : ""
        let titleNode = children(container, "title", ns: ns).first
        let feedTitle = cleanTitle(isAtom ? atomText(titleNode) : htmlText(value(titleNode)))
        let items = children(container, isAtom ? "entry" : "item", ns: ns)
        var entries: [FeedEntry] = []
        var identities = Set<UUID>()
        for node in items {
            try Task.checkCancellation()
            let titleNode = children(node, "title", ns: ns).first
            let title = cleanTitle(isAtom ? atomText(titleNode) : htmlText(value(titleNode)))
            var link = ""
            if isAtom {
                let candidates = children(node, "link", ns: atom)
                if let alternate = candidates.first(where: {
                    let rel = attribute($0, "rel"), type = attribute($0, "type")
                    return (rel.isEmpty || rel == "alternate") && (type.isEmpty || type == "text/html" || type == "application/xhtml+xml")
                }) { link = resolved(attribute(alternate, "href"), node: alternate, document: document, source: source) }
            } else {
                let linkNode = children(node, "link", ns: "").first
                link = resolved(value(linkNode), node: linkNode ?? node, document: document, source: source)
                if link.isEmpty, let guid = children(node, "guid", ns: "").first,
                   attribute(guid, "isPermaLink") != "false" {
                    link = resolved(value(guid), node: guid, document: document, source: source)
                }
            }
            var body: String
            let summary: String
            if isAtom {
                let contentNode = children(node, "content", ns: atom).first
                body = contentNode.map { attribute($0, "src").isEmpty ? atomText($0) : "" } ?? ""
                summary = atomText(children(node, "summary", ns: atom).first)
            } else {
                body = htmlText(value(children(node, "encoded", ns: content).first))
                // RSS description may be only an excerpt. Fetch the original before calling it offline text.
                summary = htmlText(value(children(node, "description", ns: "").first))
            }
            if !isAtom, body.isEmpty, link.isEmpty, value(children(node, "link", ns: "").first).isEmpty {
                // RSS permits self-contained stories with only a title and description.
                body = summary
            }
            guard !body.isEmpty || !link.isEmpty else { continue }
            let dateText = value(children(node, isAtom ? "published" : "pubDate", ns: ns).first)
            let publishedAt = date(dateText.isEmpty && isAtom ? value(children(node, "updated", ns: atom).first) : dateText)
            let opaqueID = value(children(node, isAtom ? "id" : "guid", ns: ns).first)
            let key = !opaqueID.isEmpty ? canonical(source).absoluteString + "\n" + opaqueID :
                (!link.isEmpty ? link : canonical(source).absoluteString + "\n" + title + "\n" + dateText)
            let id = identity(key)
            guard identities.insert(id).inserted else { continue }
            entries.append(FeedEntry(id: id, title: title.isEmpty ? "Untitled article" : title,
                                     source: link, text: body, summary: String(summary.prefix(1000)), publishedAt: publishedAt))
        }
        // Publishers without dates retain their original feed order; dated feeds use newest first.
        entries = entries.enumerated().sorted {
            let a = $0.element.publishedAt ?? .distantPast, b = $1.element.publishedAt ?? .distantPast
            return a == b ? $0.offset < $1.offset : a > b
        }.map(\.element)
        return ParsedArticleFeed(title: feedTitle.isEmpty ? (source.host ?? "Subscription") : feedTitle,
                                 entries: Array(entries.prefix(20)))
    }

    static func canonical(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url }
        parts.fragment = nil; parts.host = parts.host?.lowercased(); parts.scheme = parts.scheme?.lowercased()
        if parts.port == 443 { parts.port = nil }
        if parts.path.isEmpty { parts.path = "/" }
        return parts.url ?? url
    }

    static func identity(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func name(_ node: xmlNodePtr) -> String { node.pointee.name.map { String(cString: $0) } ?? "" }
    private static func namespace(_ node: xmlNodePtr) -> String { node.pointee.ns?.pointee.href.map { String(cString: $0) } ?? "" }
    private static func children(_ node: xmlNodePtr, _ tag: String, ns: String) -> [xmlNodePtr] {
        var result: [xmlNodePtr] = [], next = node.pointee.children
        while let child = next {
            if child.pointee.type == XML_ELEMENT_NODE, name(child) == tag, namespace(child) == ns { result.append(child) }
            next = child.pointee.next
        }
        return result
    }
    private static func value(_ node: xmlNodePtr?) -> String {
        guard let node, let raw = xmlNodeGetContent(node) else { return "" }
        defer { xmlFree(raw) }
        return String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private static func attribute(_ node: xmlNodePtr, _ key: String) -> String {
        guard let raw = xmlGetProp(node, key) else { return "" }
        defer { xmlFree(raw) }
        return String(cString: raw)
    }
    private static func resolved(_ text: String, node: xmlNodePtr, document: xmlDocPtr, source: URL) -> String {
        guard !text.isEmpty else { return "" }
        var base = source
        if let raw = xmlNodeGetBase(document, node) {
            base = URL(string: String(cString: raw), relativeTo: source)?.absoluteURL ?? source
            xmlFree(raw)
        }
        guard let url = URL(string: text, relativeTo: base)?.absoluteURL,
              (try? ArticleRecord.sourceURL(url.absoluteString)) != nil else { return "" }
        return canonical(url).absoluteString
    }
    private static func atomText(_ node: xmlNodePtr?) -> String {
        guard let node else { return "" }
        switch attribute(node, "type") {
        case "", "text", "text/plain": return value(node)
        case "html", "text/html": return htmlText(value(node))
        case "xhtml":
            guard let buffer = xmlBufferCreate() else { return "" }
            defer { xmlBufferFree(buffer) }
            var next = node.pointee.children
            while let child = next {
                xmlNodeDump(buffer, node.pointee.doc, child, 0, 0)
                next = child.pointee.next
            }
            return xmlBufferContent(buffer).map { htmlText(String(cString: $0)) } ?? ""
        default: return ""
        }
    }
    private static func htmlText(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return (try? ArticleExtraction.parse(Data(("<html><body><article>" + text + "</article></body></html>").utf8), source: "").text) ?? ""
    }
    private static func cleanTitle(_ title: String) -> String {
        var result = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }.map(String.init).joined()
        while result.utf8.count > 256 { result.removeLast() }
        return result
    }
    private static func date(_ text: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: text) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z", "d MMM yyyy HH:mm:ss Z"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
