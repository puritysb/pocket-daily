import Foundation
import zlib

/// Reads just enough of an EPUB for the library: title, author, language,
/// identifier and cover. Rendering stays in the reader engine.
struct EPUBPackageInfo: Equatable, Sendable {
    var title: String
    var author: String
    var language: String
    var identifier: String
    var spineCount: Int
    var cover: Data?
    var coverMediaType: String?
}

enum EPUBPackageError: LocalizedError, Equatable {
    case notAnArchive
    case unsupportedArchive
    case missingPackage
    case invalidPackage
    case encrypted

    var errorDescription: String? {
        switch self {
        case .notAnArchive: "This file is not a readable EPUB. Export it again as EPUB and try once more."
        case .unsupportedArchive: "This EPUB uses an archive feature Pocket Daily cannot read. Re-save it with another app and try again."
        case .missingPackage: "This EPUB has no package document. Check the file with its publisher or re-export it."
        case .invalidPackage: "This EPUB's package document is damaged. Re-export the book and try again."
        case .encrypted: "This book is protected with DRM. Pocket Daily opens only DRM-free books."
        }
    }
}

enum EPUBPackageReader {
    static let maximumEntries = 20_000
    static let maximumDocumentBytes = 8 * 1024 * 1024
    static let maximumCoverBytes = 12 * 1024 * 1024

    static func inspect(_ url: URL) throws -> EPUBPackageInfo {
        let archive = try ZIPArchive(url: url)
        guard let containerEntry = archive.entry("META-INF/container.xml") else { throw EPUBPackageError.missingPackage }
        let container = try archive.data(for: containerEntry, limit: maximumDocumentBytes)
        guard let packagePath = ContainerParser.rootFile(container), let packageEntry = archive.entry(packagePath) else {
            throw EPUBPackageError.missingPackage
        }
        if let rights = archive.entry("META-INF/encryption.xml"),
           let data = try? archive.data(for: rights, limit: maximumDocumentBytes),
           EncryptionScanner.protectsContent(data) {
            throw EPUBPackageError.encrypted
        }
        let package = try PackageParser.parse(try archive.data(for: packageEntry, limit: maximumDocumentBytes))
        var cover: Data?
        var coverType: String?
        if let item = package.coverItem {
            let path = resolve(item.href, relativeTo: packagePath)
            if let entry = archive.entry(path), entry.uncompressedSize <= maximumCoverBytes {
                cover = try? archive.data(for: entry, limit: maximumCoverBytes)
                coverType = item.mediaType
            }
        }
        return EPUBPackageInfo(title: package.title, author: package.creators.joined(separator: ", "),
                               language: package.language, identifier: package.identifier,
                               spineCount: package.spineCount, cover: cover, coverMediaType: coverType)
    }

    static func resolve(_ href: String, relativeTo packagePath: String) -> String {
        let decoded = href.split(separator: "#", maxSplits: 1).first.map(String.init)?.removingPercentEncoding ?? href
        var parts = packagePath.split(separator: "/").dropLast().map(String.init)
        for part in decoded.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(part))
            }
        }
        return parts.joined(separator: "/")
    }
}

// MARK: ZIP

struct ZIPArchive {
    struct Entry: Equatable {
        var path: String
        var method: UInt16
        var flags: UInt16
        var compressedSize: UInt64
        var uncompressedSize: UInt64
        var localHeaderOffset: UInt64
    }

    private let handle: FileHandle
    private let size: UInt64
    private(set) var entries: [String: Entry] = [:]

    init(url: URL) throws {
        handle = try FileHandle(forReadingFrom: url)
        size = try handle.seekToEnd()
        try readCentralDirectory()
    }

    func entry(_ path: String) -> Entry? { entries[path] }

    func data(for entry: Entry, limit: Int) throws -> Data {
        guard entry.flags & 0x1 == 0 else { throw EPUBPackageError.unsupportedArchive }
        guard entry.uncompressedSize <= UInt64(limit), entry.compressedSize <= size else { throw EPUBPackageError.invalidPackage }
        let header = try read(at: entry.localHeaderOffset, count: 30)
        guard header.uint32(at: 0) == 0x0403_4b50 else { throw EPUBPackageError.notAnArchive }
        let start = entry.localHeaderOffset + 30 + UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))
        let stored = try read(at: start, count: Int(entry.compressedSize))
        switch entry.method {
        case 0:
            guard stored.count == Int(entry.uncompressedSize) else { throw EPUBPackageError.invalidPackage }
            return stored
        case 8:
            return try Self.inflate(stored, expected: Int(entry.uncompressedSize))
        default:
            throw EPUBPackageError.unsupportedArchive
        }
    }

    private func read(at offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, offset <= size, UInt64(count) <= size - offset else { throw EPUBPackageError.notAnArchive }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw EPUBPackageError.notAnArchive }
        return data
    }

    private mutating func readCentralDirectory() throws {
        guard size >= 22 else { throw EPUBPackageError.notAnArchive }
        let tailLength = Int(min(size, 22 + 65_535))
        let tail = try read(at: size - UInt64(tailLength), count: tailLength)
        var end: Int?
        var index = tail.count - 22
        while index >= 0 {
            if tail.uint32(at: index) == 0x0605_4b50 { end = index; break }
            index -= 1
        }
        guard let end else { throw EPUBPackageError.notAnArchive }
        let count = Int(tail.uint16(at: end + 10))
        let directorySize = UInt64(tail.uint32(at: end + 12))
        let directoryOffset = UInt64(tail.uint32(at: end + 16))
        guard count != 0xffff, directoryOffset != 0xffff_ffff else { throw EPUBPackageError.unsupportedArchive }
        guard count <= EPUBPackageReader.maximumEntries, directorySize <= 64 * 1024 * 1024 else {
            throw EPUBPackageError.unsupportedArchive
        }
        let directory = try read(at: directoryOffset, count: Int(directorySize))
        var cursor = 0
        for _ in 0..<count {
            guard cursor + 46 <= directory.count, directory.uint32(at: cursor) == 0x0201_4b50 else {
                throw EPUBPackageError.notAnArchive
            }
            let nameLength = Int(directory.uint16(at: cursor + 28))
            let extraLength = Int(directory.uint16(at: cursor + 30))
            let commentLength = Int(directory.uint16(at: cursor + 32))
            guard cursor + 46 + nameLength <= directory.count else { throw EPUBPackageError.notAnArchive }
            let nameData = directory.subdata(in: cursor + 46..<cursor + 46 + nameLength)
            let path = String(decoding: nameData, as: UTF8.self)
            entries[path] = Entry(path: path,
                                  method: directory.uint16(at: cursor + 10),
                                  flags: directory.uint16(at: cursor + 8),
                                  compressedSize: UInt64(directory.uint32(at: cursor + 20)),
                                  uncompressedSize: UInt64(directory.uint32(at: cursor + 24)),
                                  localHeaderOffset: UInt64(directory.uint32(at: cursor + 42)))
            cursor += 46 + nameLength + extraLength + commentLength
        }
    }

    static func inflate(_ input: Data, expected: Int) throws -> Data {
        guard expected > 0 else { return Data() }
        var output = Data(count: expected)
        var stream = z_stream()
        guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw EPUBPackageError.unsupportedArchive
        }
        defer { inflateEnd(&stream) }
        let status: Int32 = input.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress)
                stream.avail_in = uInt(source.count)
                stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(destination.count)
                return zlib.inflate(&stream, Z_FINISH)
            }
        }
        guard status == Z_STREAM_END, Int(stream.total_out) == expected else { throw EPUBPackageError.invalidPackage }
        return output
    }
}

private extension Data {
    func uint16(at offset: Int) -> UInt16 {
        UInt16(self[startIndex + offset]) | UInt16(self[startIndex + offset + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + offset + $1]) << (8 * UInt32($1)) }
    }
}

// MARK: XML

private final class ContainerParser: NSObject, XMLParserDelegate {
    private var path: String?

    static func rootFile(_ data: Data) -> String? {
        let delegate = ContainerParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.path
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard path == nil, elementName.localXMLName == "rootfile",
              attributes["media-type"].map({ $0 == "application/oebps-package+xml" }) ?? true,
              let fullPath = attributes["full-path"], !fullPath.isEmpty else { return }
        path = fullPath
    }
}

private final class EncryptionScanner: NSObject, XMLParserDelegate {
    private static let fontObfuscation: Set<String> = [
        "http://www.idpf.org/2008/embedding", "http://ns.adobe.com/pdf/enc#RC",
    ]
    private var protects = false

    /// Font obfuscation is not DRM; anything else encrypting content is.
    static func protectsContent(_ data: Data) -> Bool {
        let delegate = EncryptionScanner()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        parser.parse()
        return delegate.protects
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if elementName.localXMLName == "EncryptionMethod",
           let algorithm = attributes["Algorithm"], !Self.fontObfuscation.contains(algorithm) {
            protects = true
        }
    }
}

private final class PackageParser: NSObject, XMLParserDelegate {
    struct Item { var href: String; var mediaType: String; var properties: String }
    struct Package {
        var title = ""
        var creators: [String] = []
        var language = ""
        var identifier = ""
        var spineCount = 0
        var coverItem: Item?
    }

    private var uniqueIdentifier: String?
    private var identifiers: [(id: String?, value: String)] = []
    private var titles: [String] = []
    private var creators: [String] = []
    private var languages: [String] = []
    private var items: [String: Item] = [:]
    private var itemOrder: [Item] = []
    private var coverID: String?
    private var spineCount = 0
    private var text = ""
    private var capturing: String?
    private var capturingID: String?
    private var inMetadata = false

    static func parse(_ data: Data) throws -> Package {
        let delegate = PackageParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw EPUBPackageError.invalidPackage }
        return delegate.package
    }

    private var package: Package {
        let identifier = identifiers.first(where: { $0.id != nil && $0.id == uniqueIdentifier })?.value
            ?? identifiers.first?.value ?? ""
        let cover = itemOrder.first(where: { $0.properties.split(separator: " ").contains("cover-image") })
            ?? coverID.flatMap { items[$0] }
            ?? itemOrder.first(where: { $0.mediaType.hasPrefix("image/") && $0.href.lowercased().contains("cover") })
        return Package(title: titles.first ?? "", creators: creators, language: languages.first ?? "",
                       identifier: identifier, spineCount: spineCount,
                       coverItem: cover.flatMap { $0.mediaType.hasPrefix("image/") ? $0 : nil })
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        switch elementName.localXMLName {
        case "package": uniqueIdentifier = attributes["unique-identifier"]
        case "metadata": inMetadata = true
        case let name where inMetadata && ["title", "creator", "language", "identifier"].contains(name):
            capturing = name
            capturingID = attributes["id"]
            text = ""
        case "meta" where inMetadata:
            if attributes["name"] == "cover", let content = attributes["content"] { coverID = content }
        case "item":
            guard let id = attributes["id"], let href = attributes["href"] else { return }
            let item = Item(href: href, mediaType: attributes["media-type"] ?? "", properties: attributes["properties"] ?? "")
            items[id] = item
            itemOrder.append(item)
        case "itemref": spineCount += 1
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturing != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.localXMLName
        if name == "metadata" { inMetadata = false }
        guard let field = capturing, field == name else { return }
        let value = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        capturing = nil
        guard !value.isEmpty else { return }
        switch field {
        case "title": titles.append(value)
        case "creator": creators.append(value)
        case "language": languages.append(value)
        case "identifier": identifiers.append((capturingID, value))
        default: break
        }
    }
}

private extension String {
    var localXMLName: String {
        split(separator: ":").last.map(String.init) ?? self
    }
}
