import Foundation
import XCTest
#if os(macOS)
import AppKit
import SwiftUI
#endif
@testable import Pocket

/// Runs only inside the explicitly opted-in hardware host. Each case records
/// its own result; cleanup failures fail the suite rather than hiding damage.
@MainActor
final class ReaderInterfaceSuite {
    static let caseIDs = ["identity-rejection", "storage-usage", "preferences-roundtrip", "profile-roundtrip-conflict",
                          "batch-article-download", "downloaded-book-reading", "pause-resume", "pause-discard", "folder-copy", "inventory-preservation"]
    var results: [[String: Any]] = caseIDs.map { ["id": $0, "state": "not-run"] }
    let model: PocketModel
    let client: CrossPointClient
    let host: String
    let identity: String
    let run: UInt32
    let idle: () -> Bool
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ReaderInterface-" + UUID().uuidString)
    var ownedFiles: [String: Int64] = [:]
    var deletedFiles: Set<String> = []
    var jobs: [UUID] = []
    var downloadedBook: URL?
    var ownedBookSizes: [UUID: Int64] = [:]
    var baseline: [String: Int64] = [:]
    var receivingLibrary: LibraryModel?

    init(model: PocketModel, client: CrossPointClient, host: String, identity: String, run: UInt32,
         idle: @escaping () -> Bool) {
        self.model = model; self.client = client; self.host = host
        self.identity = identity; self.run = run; self.idle = idle
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    func check(_ value: Bool, _ message: String) throws {
        if !value { throw Failure(message: message) }
    }
    func wait(_ message: String, seconds: Double = 60, _ ready: () -> Bool) async throws {
        let end = Date().addingTimeInterval(seconds)
        while !ready() {
            try check(Date() < end, "Timed out: " + message)
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    func drained() async throws { try await wait("reader lane") { idle() && !model.isWorking } }
    func record(_ id: String, _ operation: () async throws -> Void) async throws {
        guard let index = Self.caseIDs.firstIndex(of: id) else { throw Failure(message: "Unknown case") }
        let start = Date()
        results[index]["state"] = "running"
        print("POCKET_INTERFACE_CASE \(id) running")
        do {
            try await drained()
            try await operation()
            results[index]["state"] = "passed"
            print("POCKET_INTERFACE_CASE \(id) passed")
        } catch {
            results[index]["state"] = "failed"
            results[index]["error"] = error.localizedDescription
            results[index]["seconds"] = Date().timeIntervalSince(start)
            throw error
        }
        results[index]["seconds"] = Date().timeIntervalSince(start)
    }

    func runAll() async throws {
        let suite = "Pocket.interface." + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suite) else { throw Failure(message: "No test defaults") }
        defaults.set(true, forKey: "library.welcome.v1")
        defer { defaults.removePersistentDomain(forName: suite) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let storage = BookLibrary(root: root.appendingPathComponent("library"))
        let library = LibraryModel(storage: storage, defaults: defaults)
        receivingLibrary = LibraryModel(storage: BookLibrary(root: root.appendingPathComponent("received-library")), defaults: defaults)
        let before = try await fileMap()
        baseline = before
        do {
            try await record("identity-rejection") {
                let wrong = identity == "FFFFFFFF" ? "00000000" : "FFFFFFFF"
                do {
                    _ = try await client.readerStorageRequest(endpoint: "files", identity: wrong, host: host,
                        port: 80, query: ["path": "/", "cursor": "0"])
                } catch CrossPointClient.ClientError.unexpectedMessage(let message)
                    where message == "Reader identity mismatch" { return }
                throw Failure(message: "Reader accepted an incorrect identity")
            }
            try await record("preferences-roundtrip") { try await preferences() }
            try await record("profile-roundtrip-conflict") { try await profile() }
            try await record("storage-usage") {
                model.refreshReaderSpace()
                try await wait("SD card usage", seconds: 180) { idle() && !model.isWorking }
                try check(model.readerFilesError == nil, "Storage read failed: \(model.readerFilesError ?? "")")
                let space = try XCTUnwrap(model.readerSpace)
                try check(model.readerFilesError == nil && space.deviceID == identity && space.total > 0,
                          "SD card usage was not read from the connected reader")
                if let free = space.free { try check(free >= 0 && free <= space.total, "Invalid free space") }
            }
            let paragraphs = (0..<80).map { "Paragraph \($0). 한글과 English reader interoperability. " + String(repeating: "Reading without distractions. ", count: 8) }
            let book = try await storage.importDocument(.init(title: "Interface \(run)", language: "ko",
                chapters: [.init(title: "First", paragraphs: paragraphs), .init(title: "Second", paragraphs: paragraphs)]), origin: .written)
            let article = try await storage.importArticle(.init(title: "Interface article \(run)", source: "", text: paragraphs.joined(separator: "\n\n")))
            await library.load()
            try await record("batch-article-download") {
                let id = try await prepare([book, article], library: library)
                try await send(id)
                for item in try XCTUnwrap(model.bookTransferJob(id)).items {
                    let source = try XCTUnwrap(library.book(item.bookID))
                    let file = try await library.fileURL(for: source)
                    let path = try XCTUnwrap(item.publishedPath)
                    let prefix = source.isArticle ? "/Articles/" : "/"
                    try check(path == prefix + file.lastPathComponent, "Incorrect publication destination")
                    ownedFiles[path] = source.byteCount
                    try await download(path: path, book: source, original: file, library: library)
                }
                try await feedbackIdle()
            }
            try await record("downloaded-book-reading") { try await readDownloadedBook() }
            // Stored EPUB text is intentionally large enough to observe real
            // socket progress. Distinct lines also resist future ZIP compression.
            let largeText = (0..<4000).map { "\($0) " + UUID().uuidString + " 한글 interruption test. " + String(repeating: "Read and resume. ", count: 8) }
            let large = try await storage.importDocument(.init(title: "Interface interrupted \(run)", language: "ko",
                chapters: [.init(title: "Transfer", paragraphs: largeText)]), origin: .written)
            await library.load()
            try await record("pause-resume") {
                let id = try await prepare([large], library: library)
                try await pause(id)
                try check(model.canSendBookTransferJob(id), "Paused transfer cannot resume")
                try await send(id)
                let path = try XCTUnwrap(model.bookTransferJob(id)?.items.first?.publishedPath)
                ownedFiles[path] = large.byteCount
                let file = try await library.fileURL(for: large)
                try await download(path: path, book: large, original: file, library: library)
                try await feedbackIdle()
            }
            try await record("pause-discard") {
                let id = try await prepare([large], library: library)
                try await pause(id)
                let prepared = model.preparedTransfers.filter { $0.bookJobID == id }.map(\.id)
                model.discardBookTransferJob(id)
                try await drained()
                try check(model.bookTransferJob(id)?.stage == .discarded, "Discard did not finish")
                try check(!model.preparedTransfers.contains { prepared.contains($0.id) }, "Discard left local staging")
                let saved = try XCTUnwrap(ownedFiles.first { $0.value == large.byteCount })
                let original = try await library.fileURL(for: large)
                try await download(path: saved.key, book: large, original: original, library: library)
                try await feedbackIdle()
            }
#if os(macOS)
            try await record("folder-copy") {
                let id = try await prepare([book, article], library: library)
                let destination = root.appendingPathComponent("sd-folder")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                model.copyBookTransferJobToSD(id, root: destination, library: library)
                try await drained()
                let copy = try XCTUnwrap(model.bookTransferJob(id)?.sdCopies?.last)
                try check(copy.stage == .completed && copy.copiedCount == 2, "Folder copy not complete")
                for item in copy.items {
                    let source = try XCTUnwrap(library.book(item.bookID))
                    let original = try await library.fileURL(for: source)
                    let path = try XCTUnwrap(item.path)
                    try check(FileManager.default.contentsEqual(atPath: original.path,
                        andPath: destination.appendingPathComponent(String(path.dropFirst())).path), "Folder copy differs")
                }
                model.discardBookTransferJob(id, localOnly: true)
                try await drained()
            }
#else
            if let index = Self.caseIDs.firstIndex(of: "folder-copy") { results[index]["state"] = "not-applicable" }
#endif
            try await record("inventory-preservation") {
                try await cleanupFiles()
                let after = try await fileMap()
                try check(before == after, "Inventory changed outside owned test files")
            }
            try FileManager.default.removeItem(at: root)
        } catch {
            let original = error
            do { try await cleanupJobs(); try await cleanupFiles() }
            catch { throw Failure(message: "\(original.localizedDescription); cleanup also failed: \(error.localizedDescription). Recovery artifacts: \(root.path)") }
            throw original
        }
    }

    func prepare(_ books: [LibraryBook], library: LibraryModel) async throws -> UUID {
        try await drained()
        for book in books {
            let file = try await library.fileURL(for: book)
            let path = (book.isArticle ? "/Articles/" : "/") + file.lastPathComponent
            try check(baseline[path] == nil, "Test destination already exists; refusing to replace it")
            ownedBookSizes[book.id] = book.byteCount
        }
        let value = await model.createBookTransferJob(books: books, library: library)
        let id = try XCTUnwrap(value)
        jobs.append(id)
        try await drained()
        try check(model.canSendBookTransferJob(id), "Preparation did not enable Send")
        return id
    }
    func send(_ id: UUID) async throws {
        model.sendBookTransferJob(id)
        try await drained()
        let job = try XCTUnwrap(model.bookTransferJob(id))
        try check(job.stage == .completed && job.savedCount == job.items.count, "Incomplete publication: \(job.failure ?? "no detail")")
    }
    func pause(_ id: UUID) async throws {
        model.sendBookTransferJob(id)
        try await wait("observable streaming progress", seconds: 60) {
            (model.bookTransferJob(id)?.items.first?.result == .sending && model.uploadProgress > 0.03
                && model.uploadProgress < 0.9) || model.bookTransferJob(id)?.isFinished == true
        }
        try check(model.bookTransferJob(id)?.isFinished != true, "Fixture completed before pause; interruption not tested")
        model.pauseBookTransferJob(id)
        try await drained()
        try check(model.bookTransferJob(id)?.stage == .paused, "Pause was not retained")
    }
    func feedbackIdle() async throws {
        try check(model.readerStatus?.transferState?.version == 1, "transferState v1 required for full interface suite")
        let prior = model.readerStatus?.uptime ?? 0
        try await wait("fresh idle feedback", seconds: 35) {
            model.readerStatus?.transferState?.phase == "idle" && (model.readerStatus?.uptime ?? 0) > prior
        }
    }
    func download(path: String, book: LibraryBook, original: URL, library: LibraryModel) async throws {
        var result: Result<URL, Error>?
        model.downloadFromReader(path: path, size: book.byteCount, document: book.documentDigest) { result = $0 }
        try await wait("app download", seconds: 120) { result != nil }
        try await drained()
        let file = try XCTUnwrap(result).get()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try check(FileManager.default.contentsEqual(atPath: original.path, andPath: file.path), "Downloaded EPUB bytes differ")
        if downloadedBook == nil {
            let kept = root.appendingPathComponent("downloaded.epub")
            try FileManager.default.copyItem(at: file, to: kept)
            downloadedBook = kept
        }
        let receiver = try XCTUnwrap(receivingLibrary)
        let imported = await receiver.importFiles([file])
        try check(imported?.documentDigest == book.documentDigest, "Reimport changed document identity")
        let saved = try await receiver.fileURL(for: XCTUnwrap(imported))
        try check(saved != original && FileManager.default.contentsEqual(atPath: original.path, andPath: saved.path),
                  "The receiving Library did not persist the downloaded bytes")
    }
    func fileMap() async throws -> [String: Int64] {
        var all: [String: Int64] = [:]
        for folder in ["/", "/Books", "/Articles"] {
            var cursor = 0
            for pageIndex in 0..<64 {
                let data: Data
                do {
                    data = try await client.readerStorageRequest(endpoint: "files", identity: identity,
                        host: host, port: 80, query: ["path": folder, "cursor": String(cursor)])
                } catch ReaderStorageError.folderNotFound where folder != "/" && cursor == 0 {
                    break
                }
                let page = try JSONDecoder().decode(ReaderFilePage.self, from: data)
                try page.validate(identity: identity, folder: folder, cursor: cursor)
                for entry in page.entries where !entry.directory {
                    all[(folder == "/" ? "/" : folder + "/") + entry.name] = entry.size
                }
                cursor = page.nextCursor
                if cursor == 0 { break }
                try check(pageIndex < 63, "Unterminated inventory")
            }
        }
        return all
    }
    func cleanupFiles() async throws {
        try await drained()
        for (path, size) in ownedFiles.sorted(by: { $0.key < $1.key }) {
            model.deleteReaderFile(path, size: size, folder: (path as NSString).deletingLastPathComponent, identity: identity)
            try await drained()
            try check(model.readerFilesError == nil, "Cleanup failed for an owned test file")
            ownedFiles.removeValue(forKey: path)
            deletedFiles.insert(path)
        }
    }
    func cleanupJobs() async throws {
        try await drained()
        for id in jobs {
            guard let job = model.bookTransferJob(id) else { continue }
            for item in job.items {
                if let path = item.publishedPath, !deletedFiles.contains(path), let size = ownedBookSizes[item.bookID] {
                    ownedFiles[path] = size
                }
            }
            if !job.isFinished {
                model.discardBookTransferJob(id)
                try await drained()
                try check(model.bookTransferJob(id)?.stage == .discarded, "Owned transfer staging could not be removed")
            }
        }
    }
    func readDownloadedBook() async throws {
        let file = try XCTUnwrap(downloadedBook)
        let session = ReaderSession(bookFile: file, appearance: ReaderAppearance())
        session.open(at: nil)
#if os(macOS)
        let hosting = NSHostingView(rootView: ReaderWebView(session: session).frame(width: 720, height: 900))
        let frame = NSRect(x: 0, y: -20_000, width: 720, height: 900)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
#else
        session.webView.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
#endif
        try await wait("downloaded book opened", seconds: 30) { session.phase == .ready && session.position != nil }
        let first = try XCTUnwrap(session.position)
        try check(!session.toc.isEmpty && first.xpointer != nil, "Downloaded book has no usable contents or position")
        session.next()
        try await wait("downloaded book page turn", seconds: 10) { (session.position?.fraction ?? 0) > first.fraction }
        session.go(to: first)
        try await wait("downloaded book position restored", seconds: 10) {
            abs((session.position?.fraction ?? 1) - first.fraction) < 0.001
        }
    }
    func preferences() async throws {
        let original = try await client.preferences(host: host, port: 80)
        try JSONEncoder().encode(original).write(to: root.appendingPathComponent("original-preferences.json"), options: .atomic)
        let local = model.preferences, dirty = model.preferencesDirty
        defer { model.preferences = local; model.preferencesDirty = dirty }
        var changed = original
        changed.fontSize = (original.fontSize + 1) % 4
        func apply(_ value: ReaderPreferences) async throws {
            model.sendReaderLayout(profile: nil, cards: nil, settingsOverride: value, includePendingPreferences: false)
            try await drained()
            let observed = try await client.preferences(host: host, port: 80)
            try check(observed == value, "Settings receipt differs from saved device values")
        }
        do { try await apply(changed) }
        catch { let failure = error; try await apply(original); throw failure }
        try await apply(original)
    }
    func profile() async throws {
        let original = try await client.readerProfile(deviceID: identity, host: host, port: 80)
        try JSONEncoder().encode(original.profile).write(to: root.appendingPathComponent("original-profile.json"), options: .atomic)
        try check(model.readerProfile?.generation == original.generation, "App profile is stale before test")
        var changed = original.profile
        changed.home.nextEvent.toggle()
        changed.sleep.mode = original.profile.sleep.mode == .brief ? .reader : .brief
        func apply(_ value: PocketProfile) async throws {
            model.sendReaderLayout(profile: value, cards: nil, includePendingPreferences: false)
            try await drained()
            let actual = try await client.readerProfile(deviceID: identity, host: host, port: 80)
            try check(actual.profile == value && actual.generation == model.readerProfile?.generation, "Profile not stored as acknowledged")
        }
        do {
            try await apply(changed)
            var rejected = false
            do { _ = try await client.saveReaderProfile(original.profile, generation: original.generation,
                    deviceID: identity, host: host, port: 80) }
            catch CrossPointClient.ProfileRequestError.conflict { rejected = true }
            try check(rejected, "Stale profile overwrote newer settings")
        } catch { let failure = error; try await apply(original.profile); throw failure }
        try await apply(original.profile)
    }
}
