import SwiftUI

/// Last observed book inventory stays usable after disconnecting. All mutations
/// still go through PocketModel's existing identity and capability checks.
struct ReaderInventoryView: View {
    @ObservedObject var model: PocketModel
    @ObservedObject var library: LibraryModel
    let open: (LibraryBook) -> Void
    let connect: () -> Void
    let manage: () -> Void
    private var shelf: ReaderShelf? {
        guard let inventory = model.readerInventory, !model.isDemoMode else { return nil }
        return ReaderShelf(inventory: inventory, books: library.books)
    }

    private var canObserveInventory: Bool {
        guard let identity = model.readerStatus?.deviceID, !identity.isEmpty else { return false }
        return model.device.capabilities.contains(.files) || model.device.capabilities.contains(.readingPositions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            InspectorCard(title: "Books and articles", symbol: "books.vertical") {
                if let shelf {
                    HStack {
                        Text("\(shelf.readerModel ?? "Reader") · checked \(shelf.readAt.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if model.device.isConnected {
                            Button("Refresh") { model.requestReaderInventoryRefresh() }
                                .disabled(model.isWorking).accessibilityIdentifier("inventory-refresh")
                        }
                    }
                    if !model.device.isConnected {
                        HStack {
                            Text("Last seen files").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Connect to Refresh", action: connect).buttonStyle(.bordered)
                        }
                    }
                    if shelf.items.isEmpty { Text("No books or articles were found in this reader’s inventory.").foregroundStyle(.secondary) }
                    ForEach(shelf.items) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.isArticle ? "doc.text" : "book.closed").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.headline)
                                Text(item.path.hasPrefix("#") ? "Recent book" : item.path).font(.caption).foregroundStyle(.secondary)
                                if let size = item.size { Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).font(.caption).foregroundStyle(.secondary) }
                                if let percentage = item.percentage {
                                    Text("\(Int((percentage * 100).rounded()))% read").font(.caption).foregroundStyle(.secondary)
                                }
                                if item.bookID != nil {
                                    Text(isVerifiedMatch(item) ? "Same content in Library" : "Library match by name and size")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                else if item.canAddToLibrary, !model.device.isConnected {
                                    // One connect action sits in the header above, not on every row.
                                    Text("Connect to copy into the Library.")
                                        .font(.caption).foregroundStyle(.secondary)
                                } else if item.canAddToLibrary, !model.device.capabilities.contains(.fileDownload) {
                                    Text("Reader firmware does not support copying into the Library.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                            if let id = item.bookID, let book = library.books.first(where: { $0.id == id }) {
                                Button("Read in App") { open(book) }.buttonStyle(.bordered)
                            } else if model.readerDownload?.path == item.path {
                                Button("Cancel") { model.cancelReaderDownload() }
                            } else if item.canAddToLibrary, model.device.isConnected,
                                      model.device.capabilities.contains(.fileDownload) {
                                Button("Add to Library") { add(item) }.buttonStyle(.bordered)
                                    .disabled(!model.canDownloadFromReader)
                            }
                        }
                        .accessibilityIdentifier("inventory-book-\(item.name)")
                        if let download = model.readerDownload, download.path == item.path, download.size > 0 {
                            ProgressView(value: Double(download.received), total: Double(download.size)).progressViewStyle(.pocketBar)
                        }
                    }
                } else if model.device.isConnected {
                    if canObserveInventory {
                        Text("The reader’s inventory has not been checked yet.")
                            .font(.callout).foregroundStyle(.secondary)
                        if model.isWorking {
                            ProgressView("Reader task in progress").font(.caption)
                        }
                        Button("Refresh Inventory") { model.requestReaderInventoryRefresh() }
                            .buttonStyle(.bordered).disabled(model.isWorking)
                            .accessibilityIdentifier("inventory-refresh")
                    } else {
                        Text("Book inventory is not available with this firmware.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Manage Reader", action: manage).buttonStyle(.bordered)
                            .accessibilityIdentifier("inventory-open-device")
                    }
                } else if model.isDemoMode {
                    // Demo shows what the shelf looks like; nothing here is read from a device.
                    Text("Example files · a connected reader lists its own")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Self.demoItems, id: \.title) { item in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: item.article ? "doc.text" : "book.closed").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title).font(.headline)
                                Text(item.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .accessibilityIdentifier("inventory-demo")
                } else {
                    Text("Connect a reader to see its books and articles.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let error = library.error {
                    PocketStatusLabel(error, tone: .failure).font(.caption)
                }
                if let error = model.readerInventoryError {
                    PocketStatusLabel(error, tone: .failure).font(.caption)
                }
            }
            if model.readerStatus != nil && (model.isDemoMode || canObserveInventory) {
                InspectorCard(title: "Storage and all files", symbol: "sdcard") { ReaderStoragePanel(model: model) }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("reader-inventory")
    }

    private static let demoItems: [(title: String, detail: String, article: Bool)] = [
        ("Pride and Prejudice", "/Books/pride-and-prejudice.epub · 42% read", false),
        ("Welcome to Pocket Daily", "/Books/welcome-to-pocket-daily.epub · 0% read", false),
        ("A little room for a slower morning", "/Articles/slower-morning.epub · saved article", true),
    ]

    private func isVerifiedMatch(_ item: ReaderShelf.Item) -> Bool {
        guard let id = item.bookID, let document = item.document, let book = library.book(id) else { return false }
        return document.lowercased() == book.documentDigest.lowercased()
    }

    private func add(_ item: ReaderShelf.Item) {
        guard let size = item.size else { return }
        model.downloadFromReader(path: item.path, size: size, document: item.document) { result in
            switch result {
            case .success(let file):
                Task {
                    let book = await library.importFiles([file])
                    try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
                    if let book { library.notice = "\(book.title) is now in your Library." }
                }
            case .failure(let error): library.error = error.localizedDescription
            }
        }
    }
}
