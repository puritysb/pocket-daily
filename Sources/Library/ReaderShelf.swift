import Foundation

/// What the connected reader holds, read over the local connection: the files
/// in the folders the app sends to, and the reader's recent books with their
/// fingerprints (docs/READER_EXPANSION.md, 기기 중심 구조, 2단계).
struct ReaderInventory: Equatable, Sendable {
    struct File: Equatable, Sendable {
        let path: String
        let size: Int64
    }

    let deviceID: String
    /// The model the reader reported, for "Seen on X4".
    let model: String?
    var files: [File]
    var reading: [ReaderReadingEntry]
    let readAt: Date

    /// Include the reader's usual Books folder as well as the app's destinations.
    static let folders = ["/", "/Books", "/Articles"]
    /// Book files a reader shelf shows; XTC is the reader's own pre-rendered format.
    static let bookExtensions: Set<String> = ["epub", "txt", "md", "xtc"]

    /// Firmware-owned root diagnostics remain available in Browse Files.
    /// Do not hide similarly named user books in other folders.
    static func isDiagnosticPath(_ path: String) -> Bool {
        ["/crash_report.txt", "/crash_report.1.txt", "/crash_report.2.txt",
         "/crash_report.3.txt", "/nearby_ap_log.txt"].contains(path.lowercased())
    }
}

/// The inventory matched against the Library. A reader book matches a Library
/// book by fingerprint when the reader reports one (its recent books), and
/// otherwise by file name and size: the app sends Library files unchanged
/// under their Library name, so both agree for every book it sent.
struct ReaderShelf: Equatable {
    struct Item: Equatable, Identifiable {
        let path: String
        let size: Int64?
        var percentage: Double?
        var bookID: UUID?
        /// The reader's fingerprint for this file, from its recent books; a copy must match it.
        var document: String?

        var id: String { path }
        var name: String { (path as NSString).lastPathComponent }
        var title: String { (name as NSString).deletingPathExtension }
        var isArticle: Bool { path.hasPrefix("/Articles/") }
        /// The Library keeps EPUB bytes unchanged, so a copy matches this file again;
        /// TXT and Markdown are converted on import and would not.
        var canAddToLibrary: Bool { size != nil && (name as NSString).pathExtension.lowercased() == "epub" }
    }

    let readerModel: String?
    let readAt: Date
    let items: [Item]

    init(inventory: ReaderInventory, books: [LibraryBook]) {
        readerModel = inventory.model
        readAt = inventory.readAt
        var byDigest: [String: LibraryBook] = [:]
        for book in books where byDigest[book.documentDigest.lowercased()] == nil {
            byDigest[book.documentDigest.lowercased()] = book
        }
        var items: [String: Item] = [:]
        for file in inventory.files {
            guard !ReaderInventory.isDiagnosticPath(file.path) else { continue }
            let name = (file.path as NSString).lastPathComponent
            guard ReaderInventory.bookExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let book = books.first { $0.fileName == name && $0.byteCount == file.size }
            items[file.path.lowercased()] = Item(path: file.path, size: file.size, percentage: nil, bookID: book?.id)
        }
        for entry in inventory.reading {
            if let path = entry.path, ReaderInventory.isDiagnosticPath(path) { continue }
            let book = byDigest[entry.document.lowercased()]
            guard let key = entry.path ?? book.map({ "#" + $0.documentDigest }) else { continue }
            // FAT paths are case-insensitive. Recent-reading paths may use
            // `/books` while file enumeration uses `/Books`; merge their data.
            let lookup = key.lowercased()
            var item = items[lookup] ?? Item(path: key, size: nil, percentage: nil, bookID: nil)
            item.percentage = entry.percentage
            item.document = entry.document.lowercased()
            if let book { item.bookID = book.id }
            items[lookup] = item
        }
        self.items = items.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func item(for book: LibraryBook) -> Item? {
        items.first { $0.bookID == book.id }
    }

    /// Books on the reader that the Library does not have.
    var onlyOnReader: [Item] {
        items.filter { $0.bookID == nil && !$0.path.hasPrefix("#") }
    }
}
