import ImageIO
import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    enum Shelf: String, CaseIterable, Identifiable {
        case books = "Books", articles = "Articles"
        var id: String { rawValue }
    }

    @ObservedObject var model: PocketModel
    @ObservedObject var library: LibraryModel
    @ObservedObject var sync: ReadingSync
    @ObservedObject var inbox: ArticleInboxModel
    @Binding var shelf: Shelf
    var showsShelfMenu = true
    let open: (LibraryBook) -> Void
    @State private var importing = false
    @State private var addingArticle = false
    @State private var managingFeeds = false
    @State private var showingSync = false
    @State private var removing: LibraryBook?
    @State private var targeted = false
    @State private var sharing: SharedBook?

    struct SharedBook: Identifiable {
        let id = UUID()
        let title: String
        let url: URL
    }

    static let importTypes: [UTType] = [.epub, .plainText, UTType("net.daringfireball.markdown") ?? .plainText]

    var body: some View {
        NavigationStack {
            Group {
                switch shelf {
                case .books: books
                case .articles: ArticleShelf(model: model, library: library, read: open, inbox: inbox,
                                             adding: $addingArticle, managingFeeds: $managingFeeds)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) { header }
#if os(iOS)
            .toolbar(.hidden, for: .navigationBar)
#endif
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): library.error = error.localizedDescription
                }
            }
            .sheet(item: $sharing) { shared in
                VStack(alignment: .leading, spacing: 14) {
                    Text(shared.title).font(.headline)
                    Text("Send this exact file to your other devices and open it there with Pocket Daily. The same file is recognized as the same book, so you can continue where you left off.")
                        .font(.callout).foregroundStyle(.secondary)
                    ShareLink(item: shared.url) { Label("Share book file", systemImage: "square.and.arrow.up") }
                        .buttonStyle(.borderedProminent)
                    Button("Done") { sharing = nil }
                }
                .padding(24)
                .presentationDetents([.medium])
            }
            .sheet(isPresented: $showingSync) { SyncSettingsView(sync: sync, model: model, library: library) }
            .confirmationDialog("Remove this book from the library?", isPresented: Binding(
                get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
                    if let book = removing {
                        Button("Remove \(book.title)", role: .destructive) { Task { await library.remove(book) } }
                    }
            } message: {
                Text("Copies already on your reader are kept.")
            }
        }
        .task { await library.load() }
    }

    private var header: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                if showsShelfMenu {
                    Menu {
                        Picker("Shelf", selection: $shelf) {
                            ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Text(shelf.rawValue).font(.largeTitle.bold()).foregroundStyle(.primary)
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        }
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityIdentifier("library-shelf")
                } else {
                    Text(shelf.rawValue).font(.largeTitle.bold())
                }
                Text(shelf == .books ? "Your own quiet corner." : "Saved for a slower moment.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if shelf == .books {
                Button { importing = true } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44).contentShape(Rectangle())
                }
                    .accessibilityLabel("Add books")
                    .disabled(library.isWorking)
                    .accessibilityIdentifier("library-add")
            }
            if shelf == .articles {
                Menu {
                    Button("Add article", systemImage: "doc.badge.plus") { addingArticle = true }
                        .accessibilityIdentifier("article-add")
                    Button("Subscriptions", systemImage: "dot.radiowaves.left.and.right") { managingFeeds = true }
                        .accessibilityIdentifier("article-subscriptions")
                } label: { Image(systemName: "plus").frame(width: 44, height: 44) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Add to Articles").accessibilityIdentifier("article-add-menu")
            }
            Menu {
                Button { showingSync = true } label: {
                    Label("Continue Reading", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityIdentifier("library-sync")
                Divider()
                AppAppearancePicker()
            } label: {
                Image(systemName: "ellipsis.circle").foregroundStyle(.primary).frame(width: 44, height: 44)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel("Library options")
            .accessibilityIdentifier("library-options")
        }
        .buttonStyle(.plain)
        .tint(Color.primary)
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: 1100)
        .frame(maxWidth: .infinity)
    }

    // MARK: Books

    private var books: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                messages
                if let current = library.continueReading {
                    ContinueReadingCard(book: current, library: library) { open(current) }
                }
                Text("On your bookshelf")
                    .font(.headline)
                    .padding(.top, 4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 22) {
                    ForEach(library.books.filter { !$0.isArticle }) { book in
                        Button { open(book) } label: {
                            BookTile(book: book, library: library)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("book-\(book.title)")
                        .contextMenu { menu(for: book) }
                    }
                }
                if !library.books.contains(where: { !$0.isArticle && $0.origin != .welcome }) && !library.isWorking {
                    // Until the first own book arrives, say how books get here.
                    Label("Add your own books with +, or drop DRM-free EPUB, TXT or Markdown files here.",
                          systemImage: "arrow.down.doc")
                        .font(.callout).foregroundStyle(.secondary)
                        .padding(.top, 4)
                        .accessibilityIdentifier("library-add-hint")
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(targeted ? PocketPalette.selection : Color.clear)
        .dropDestination(for: URL.self) { urls, _ in
            Task { await library.importFiles(urls) }
            return true
        } isTargeted: { targeted = $0 }
        .overlay {
            if library.isWorking { ProgressView("Adding…").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12)) }
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = library.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.red)
                .onTapGesture { library.error = nil }
        } else if let notice = library.notice {
            Text(notice).font(.callout).foregroundStyle(.secondary)
                .task { try? await Task.sleep(for: .seconds(4)); library.notice = nil }
        }
    }

    @ViewBuilder private func menu(for book: LibraryBook) -> some View {
        Button("Read", systemImage: "book") { open(book) }
        Button("Share book file…", systemImage: "square.and.arrow.up") { share(book) }
        Button("Prepare for reader", systemImage: "arrow.up.doc") { prepare(book) }
            .disabled(!model.canPrepareFiles)
        Divider()
        Button("Remove from Library", systemImage: "trash", role: .destructive) { removing = book }
    }

    /// The exact library file, so another device opens the same book and can continue.
    private func share(_ book: LibraryBook) {
        Task {
            do { sharing = SharedBook(title: book.title, url: try await library.fileURL(for: book)) }
            catch { library.error = error.localizedDescription }
        }
    }

    /// Queues the exact library file for the reader; sending stays explicit.
    private func prepare(_ book: LibraryBook) {
        Task {
            do {
                let url = try await library.fileURL(for: book)
                guard let work = model.upload(url) else {
                    library.error = model.isDemoMode
                        ? "Leave demo mode and connect a reader to send books."
                        : "Finish the current reader task, then try again."
                    return
                }
                await work.value
                library.notice = "\(book.title) is ready in Device → Files. Connect and choose Send."
            } catch {
                library.error = error.localizedDescription
            }
        }
    }
}

private struct ContinueReadingCard: View {
    let book: LibraryBook
    @ObservedObject var library: LibraryModel
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                BookCover(book: book, library: library, compact: true).frame(width: 72, height: 104)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue reading").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(book.title).font(.headline).lineLimit(2)
                    if let chapter = book.position?.chapter {
                        Text(chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ProgressView(value: book.progress).progressViewStyle(.pocketBar)
                    Text(book.progress.formatted(.percent.precision(.fractionLength(0))))
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("continue-reading")
    }
}

private struct BookTile: View {
    let book: LibraryBook
    @ObservedObject var library: LibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BookCover(book: book, library: library)
                .aspectRatio(2 / 3, contentMode: .fit)
            Text(book.title).font(.subheadline.weight(.medium)).lineLimit(2)
            if !book.author.isEmpty {
                Text(book.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if book.progress > 0 {
                ProgressView(value: book.progress).progressViewStyle(.pocketBar)
            }
        }
        .contentShape(Rectangle())
    }
}

struct BookCover: View {
    let book: LibraryBook
    @ObservedObject var library: LibraryModel
    var compact = false
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [PocketPalette.coverTop, PocketPalette.coverBottom], startPoint: .top, endPoint: .bottom)
                // A spine along the left edge, like a bound book.
                HStack(spacing: 0) {
                    PocketPalette.ink.opacity(0.10).frame(width: compact ? 4 : 6)
                    PocketPalette.ink.opacity(0.04).frame(width: 1)
                    Spacer(minLength: 0)
                }
                VStack(spacing: 8) {
                    Text(book.title)
                        .font(.system(compact ? .caption2 : .footnote, design: .serif).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .minimumScaleFactor(0.7)
                    if !compact && !book.author.isEmpty {
                        Text(book.author).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .foregroundStyle(PocketPalette.ink)
                .padding(compact ? 6 : 10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(PocketPalette.line))
        .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        .task(id: book.id) {
            guard book.hasCover, let url = await library.cover(for: book) else { return }
            image = await Task.detached(priority: .utility) { Self.thumbnail(url) }.value
        }
    }

    nonisolated static func thumbnail(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 480,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
