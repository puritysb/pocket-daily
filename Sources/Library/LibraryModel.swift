import SwiftUI

@MainActor
final class LibraryModel: ObservableObject {
    static let shared: LibraryModel = {
#if DEBUG
        // Screenshots and UI tests start from a library holding only the guide.
        if ProcessInfo.processInfo.arguments.contains("--ui-test-fresh-library") {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("fresh-library-\(UUID().uuidString)")
            let defaults = UserDefaults(suiteName: "fresh-library-\(UUID().uuidString)") ?? .standard
            return LibraryModel(storage: BookLibrary(root: root), defaults: defaults)
        }
#endif
        return LibraryModel()
    }()

    @Published private(set) var books: [LibraryBook] = []
    @Published private(set) var isWorking = false
    @Published var notice: String?
    @Published var error: String?

    let storage: BookLibrary
    private let defaults: UserDefaults
    private var pendingPositions: [UUID: ReadingPosition] = [:]
    private var positionTask: Task<Void, Never>?
    private static let welcomeKey = "library.welcome.v1"

    init(storage: BookLibrary = .shared, defaults: UserDefaults = .standard) {
        self.storage = storage
        self.defaults = defaults
    }

    var continueReading: LibraryBook? {
        books.first { $0.lastOpenedAt != nil && $0.progress < 0.995 }
    }

    func book(_ id: UUID) -> LibraryBook? { books.first { $0.id == id } }

    func load() async {
        do {
            if !defaults.bool(forKey: Self.welcomeKey) {
                _ = try await storage.importDocument(WelcomeBook.document, origin: .welcome)
                defaults.set(true, forKey: Self.welcomeKey)
            }
            books = try await storage.books()
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func importFiles(_ urls: [URL]) async -> LibraryBook? {
        guard !urls.isEmpty else { return nil }
        isWorking = true
        defer { isWorking = false }
        var last: LibraryBook?
        var failures: [String] = []
        for url in urls {
            do { last = try await storage.importFile(at: url) }
            catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        await refresh()
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
        if failures.isEmpty, let last { notice = urls.count == 1 ? "Added \(last.title)." : "Added \(urls.count) books." }
        return last
    }

    func importArticle(_ id: UUID, store: ArticleStore = .shared) async -> LibraryBook? {
        isWorking = true
        defer { isWorking = false }
        do {
            let record = try await store.load(id)
            let book = try await storage.importArticle(record)
            await refresh()
            return book
        } catch {
            self.error = error.localizedDescription
            return nil
        }
    }

    func remove(_ book: LibraryBook) async {
        do {
            try await storage.remove(book.id)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func fileURL(for book: LibraryBook) async throws -> URL {
        try await storage.fileURL(for: book)
    }

    func markOpened(_ id: UUID) {
        Task {
            _ = try? await storage.update(id) { $0.lastOpenedAt = Date() }
            await refresh()
        }
    }

    /// Page turns arrive quickly; positions are written at most every second.
    func savePosition(_ position: ReadingPosition, for id: UUID) {
        guard position.fraction.isFinite else { return }
        pendingPositions[id] = position
        if let index = books.firstIndex(where: { $0.id == id }) { books[index].position = position }
        guard positionTask == nil else { return }
        positionTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.flushPositions()
        }
    }

    func flushPositions() async {
        positionTask = nil
        let pending = pendingPositions
        pendingPositions = [:]
        for (id, position) in pending {
            do { _ = try await storage.update(id) { $0.position = position } }
            catch { self.error = error.localizedDescription }
        }
    }

    func cover(for book: LibraryBook) async -> URL? {
        await storage.coverURL(for: book)
    }

    private func refresh() async {
        do { books = try await storage.books() }
        catch { self.error = error.localizedDescription }
    }
}
