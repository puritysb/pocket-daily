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

    /// Library books go to the SD root and articles to `/Articles` (`PocketModel.destination`).
    static let folders = ["/", "/Articles"]
    /// Book files a reader shelf shows; XTC is the reader's own pre-rendered format.
    static let bookExtensions: Set<String> = ["epub", "txt", "md", "xtc"]
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
            let name = (file.path as NSString).lastPathComponent
            guard ReaderInventory.bookExtensions.contains((name as NSString).pathExtension.lowercased()) else { continue }
            let book = books.first { $0.fileName == name && $0.byteCount == file.size }
            items[file.path] = Item(path: file.path, size: file.size, percentage: nil, bookID: book?.id)
        }
        for entry in inventory.reading {
            let book = byDigest[entry.document.lowercased()]
            guard let key = entry.path ?? book.map({ "#" + $0.documentDigest }) else { continue }
            var item = items[key] ?? Item(path: key, size: nil, percentage: nil, bookID: nil)
            item.percentage = entry.percentage
            item.document = entry.document.lowercased()
            if let book { item.bookID = book.id }
            items[key] = item
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
