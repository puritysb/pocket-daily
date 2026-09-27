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
    let open: (LibraryBook) -> Void

    @State private var shelf: Shelf = .books
    @State private var importing = false
    @State private var showingSync = false
    @State private var removing: LibraryBook?
    @State private var targeted = false

    static let importTypes: [UTType] = [.epub, .plainText, UTType("net.daringfireball.markdown") ?? .plainText]

    var body: some View {
        NavigationStack {
            Group {
                switch shelf {
                case .books: books
                case .articles: ArticleShelf(model: model, library: library, read: open)
                }
            }
#if os(macOS)
            .safeAreaInset(edge: .top, spacing: 0) { macHeader }
#else
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Shelf", selection: $shelf) {
                        ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                    .accessibilityIdentifier("library-shelf")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { importing = true } label: { Label("Add books", systemImage: "plus") }
                        .disabled(library.isWorking)
                        .accessibilityIdentifier("library-add")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { showingSync = true } label: {
                        Label("Sync", systemImage: sync.isConnected ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                    }
                    .accessibilityIdentifier("library-sync")
                }
            }
#endif
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.importTypes, allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): Task { await library.importFiles(urls) }
                case .failure(let error): library.error = error.localizedDescription
                }
            }
            .sheet(isPresented: $showingSync) { SyncSettingsView(sync: sync, model: model) }
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

#if os(macOS)
    /// Mac windows keep the Library controls in the content, so they read the
    /// same with or without a window toolbar.
    private var macHeader: some View {
        HStack(spacing: 14) {
            Text("Library").font(.title2.weight(.semibold))
            Picker("Shelf", selection: $shelf) {
                ForEach(Shelf.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("library-shelf")
            Spacer()
            Button { showingSync = true } label: {
                Label(sync.isConnected ? "Sync on" : "Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("library-sync")
            Button { importing = true } label: { Label("Add books", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(library.isWorking)
                .accessibilityIdentifier("library-add")
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
    }
#endif

    // MARK: Books

    private var books: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                messages
                if !sync.isConnected && !sync.hasDismissedRecommendation {
                    syncRecommendation
                }
                if let current = library.continueReading {
                    ContinueReadingCard(book: current, library: library) { open(current) }
                }
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
                if library.books.isEmpty && !library.isWorking {
                    Text("Add DRM-free EPUB, TXT or Markdown files to start reading.")
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
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

    private var syncRecommendation: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath").font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                Text("Keep your place on every device").font(.subheadline.weight(.semibold))
                Text("Connect KOReader sync to continue where you left off on your X3/X4 reader, KOReader, or another device running Pocket Daily.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Set up sync") { showingSync = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                        .accessibilityIdentifier("sync-recommend-setup")
                    Button("Not now") { sync.hasDismissedRecommendation = true }
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PocketPalette.panel, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private func menu(for book: LibraryBook) -> some View {
        Button("Read", systemImage: "book") { open(book) }
        Button("Prepare for reader", systemImage: "arrow.up.doc") { prepare(book) }
            .disabled(!model.canPrepareFiles)
        Divider()
        Button("Remove from Library", systemImage: "trash", role: .destructive) { removing = book }
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
                library.notice = "\(book.title) is ready in Reader → Files. Connect and choose Send."
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
                BookCover(book: book, library: library).frame(width: 72, height: 104)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Continue reading").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(book.title).font(.headline).lineLimit(2)
                    if let chapter = book.position?.chapter {
                        Text(chapter).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    ProgressView(value: book.progress).tint(.primary)
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
                ProgressView(value: book.progress).tint(.secondary)
            }
        }
        .contentShape(Rectangle())
    }
}

struct BookCover: View {
    let book: LibraryBook
    @ObservedObject var library: LibraryModel
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                LinearGradient(colors: [Color(white: 0.93), Color(white: 0.86)], startPoint: .top, endPoint: .bottom)
                VStack(spacing: 8) {
                    Text(book.title)
                        .font(.system(.footnote, design: .serif).weight(.semibold))
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                    if !book.author.isEmpty {
                        Text(book.author).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .foregroundStyle(Color(white: 0.15))
                .padding(10)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.black.opacity(0.08)))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
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
