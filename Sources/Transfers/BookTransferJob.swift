import Foundation

struct BookTransferTarget: Codable, Equatable, Sendable {
    var readerID: String?
    var displayName: String
}

struct BookTransferOrigin: Codable, Equatable, Sendable {
    var search: String = ""
    var collection: String? = nil
    var focusedBookID: UUID? = nil
}

enum BookTransferDestination: String, Codable, CaseIterable, Sendable {
    case readerWiFi, sdCard
    var title: String { self == .readerWiFi ? "Reader over Wi-Fi" : "SD card" }
}

struct BookSDCopy: Codable, Identifiable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable { case copying, paused, partialCompletion, confirmationUnknown, failed, completed }
    enum Result: String, Codable, Sendable { case waiting, copying, copied, confirmationUnknown, failed }
    struct Item: Codable, Identifiable, Equatable, Sendable {
        var id: UUID { bookID }
        let bookID: UUID
        var result: Result = .waiting
        var path: String?
        var failure: String?
    }
    let id: UUID
    let folderName: String
    var stage: Stage = .copying
    var items: [Item]
    var failure: String?
    var copiedCount: Int { items.filter { $0.result == .copied }.count }
    mutating func recover() {
        for index in items.indices where items[index].result == .copying { items[index].result = .confirmationUnknown }
        if items.contains(where: { $0.result == .confirmationUnknown }) { stage = .confirmationUnknown }
        else if copiedCount == items.count { stage = .completed }
        else if stage == .copying { stage = .paused }
    }
}

enum ReaderTaskDestination: Equatable {
    case bookTransfer(UUID), readerInventory, screens, reading, cards, weatherCalendar, firmware, connection, diagnostics, preparedFiles
}

struct BookTransferJob: Codable, Identifiable, Equatable, Sendable {
    enum Stage: String, Codable, Sendable {
        case preparing, needsConnection, connecting, ready, waitingForOtherWork
        case sending, checking, paused, confirmationUnknown, partialCompletion, failed, completed, discarded
    }
    enum Result: String, Codable, Sendable {
        case unprepared, prepared, sending, confirmationUnknown, saved, failed, discarded
    }
    struct Item: Codable, Identifiable, Equatable, Sendable {
        var id: UUID { bookID }
        let bookID: UUID
        let title: String
        var transferID: UUID?
        var result: Result = .unprepared
        var failure: String?
        var publishedPath: String?
    }
    let id: UUID
    var target: BookTransferTarget?
    let origin: BookTransferOrigin
    var stage: Stage = .preparing
    var items: [Item]
    var failure: String?
    var progress: Double = 0
    var updatedAt: Date = Date()
    var destination: BookTransferDestination? = nil
    var sdCopies: [BookSDCopy]? = nil
    var latestSDCopy: BookSDCopy? { sdCopies?.last }
    var requiresAttention: Bool {
        if needsConfirmation { return true }
        if destination == .sdCard, let copy = latestSDCopy { return copy.stage != .completed }
        return !isFinished
    }
    var presentationStatus: String {
        guard destination == .sdCard else { return stage.displayTitle }
        guard let copy = latestSDCopy else { return "Choose SD card folder" }
        switch copy.stage {
        case .copying: return "Copying to SD card"
        case .paused: return "SD copy paused"
        case .partialCompletion: return "Some books copied to SD card"
        case .confirmationUnknown: return "Check SD copy result"
        case .failed: return "SD copy needs attention"
        case .completed: return "Books copied to SD card"
        }
    }
    var preparedTransferIDs: [UUID] { items.compactMap(\.transferID) }
    var savedCount: Int { items.filter { $0.result == .saved }.count }
    var needsConfirmation: Bool { items.contains { $0.result == .confirmationUnknown } }
    var isFinished: Bool { stage == .completed || stage == .discarded }

    /// Missing copies are never interpreted as a successful publication. An
    /// owner marker repairs the interruption between copy and job persistence.
    mutating func recover(prepared: [PreparedTransfer]) {
        if var copies = sdCopies {
            for index in copies.indices { copies[index].recover() }
            sdCopies = copies
        }
        guard !isFinished else { return }
        for index in items.indices {
            guard items[index].result != .saved && items[index].result != .discarded else { continue }
            let copy = prepared.first {
                $0.bookJobID == id && $0.libraryBookID == items[index].bookID && $0.kind == .content
                    && (items[index].transferID == nil || $0.id == items[index].transferID)
            }
            if let copy {
                items[index].transferID = copy.id
                items[index].result = copy.publicationPending == true || items[index].result == .confirmationUnknown ? .confirmationUnknown : .prepared
                items[index].failure = nil
            } else if items[index].result == .unprepared {
                // The planned ID was saved before copying. No prepared record
                // means it could never be admitted to publication.
                items[index].result = .unprepared
            } else if items[index].transferID != nil {
                items[index].result = .confirmationUnknown
                items[index].failure = "The prepared copy is missing. Check this book on the original reader before starting another transfer."
            } else {
                items[index].result = .unprepared
            }
        }
        if savedCount == items.count { stage = .completed }
        else if items.allSatisfy({ $0.result == .saved || $0.result == .discarded }) { stage = .discarded }
        else if needsConfirmation { stage = .confirmationUnknown }
        else if savedCount > 0 { stage = .partialCompletion }
        else { stage = .paused }
        progress = 0
    }

    /// Ownership written with the very first copy record lets us repair a lost
    /// manifest without adopting any older queue item or inferring IDs from names.
    static func recoveringOrphans(_ jobs: [BookTransferJob], prepared: [PreparedTransfer]) throws -> [BookTransferJob] {
        let groups = Dictionary(grouping: prepared.filter { $0.bookJobID != nil }, by: { $0.bookJobID })
        var recovered = jobs
        for (owner, copies) in groups {
            guard let owner, copies.allSatisfy({ $0.libraryBookID != nil && $0.kind == .content }),
                  Set(copies.compactMap(\.libraryBookID)).count == copies.count else {
                throw BookTransferError.storage("Conflicting prepared book ownership. The copies were kept for recovery.")
            }
            guard !jobs.contains(where: { $0.id == owner }) else { continue }
            let readers = Set(copies.compactMap(\.readerID))
            guard readers.count <= 1 else {
                throw BookTransferError.storage("A recovered transfer refers to different readers. Its copies were kept.")
            }
            let target = readers.first.map { BookTransferTarget(readerID: $0, displayName: "Reader") }
            let items = copies.sorted { $0.id.uuidString < $1.id.uuidString }.compactMap { copy -> Item? in
                guard let bookID = copy.libraryBookID else { return nil }
                return Item(bookID: bookID, title: copy.filename, transferID: copy.id,
                            result: copy.publicationPending == true ? .confirmationUnknown : .prepared)
            }
            var job = BookTransferJob(id: owner, target: target, origin: .init(), items: items)
            job.stage = job.needsConfirmation ? .confirmationUnknown : .paused
            recovered.append(job)
        }
        return recovered
    }
}

enum BookTransferError: LocalizedError {
    case storage(String), unavailable, emptySelection, targetChanged, missingCopy, unknownPublication
    var errorDescription: String? {
        switch self {
        case .storage(let reason): "The transfer record could not be saved. Nothing more will be sent. Check available storage and try again. \(reason)"
        case .unavailable: "Finish the current reader task, then try again."
        case .emptySelection: "Choose a book to send."
        case .targetChanged: "Connect the selected reader, or explicitly choose the connected reader before sending."
        case .missingCopy: "The prepared book is missing. Check the original reader before preparing another copy."
        case .unknownPublication: "The reader may have saved this book. Check its saved result before sending again."
        }
    }
}

/// All new job I/O is isolated from the main actor. Whole-record replacement
/// is atomic; no passwords, file contents or pairing secrets are stored here.
actor BookTransferJobStore {
    private struct Archive: Codable { var version = 1; var jobs: [BookTransferJob] }
    let file: URL
    private let write: @Sendable (Data, URL) throws -> Void
    init(file: URL = TransferPreparation.directory.deletingLastPathComponent().appendingPathComponent("book-transfer-jobs.json"),
         write: @escaping @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.file = file
        self.write = write
    }
    func load() throws -> [BookTransferJob] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
        guard archive.version == 1 else { throw BookTransferError.storage("Unsupported transfer record version.") }
        let transferIDs = archive.jobs.flatMap(\.preparedTransferIDs)
        guard Set(archive.jobs.map(\.id)).count == archive.jobs.count,
              Set(transferIDs).count == transferIDs.count,
              archive.jobs.allSatisfy({ !$0.items.isEmpty && Set($0.items.map(\.bookID)).count == $0.items.count }) else {
            throw BookTransferError.storage("Invalid transfer record.")
        }
        return archive.jobs
    }
    func save(_ jobs: [BookTransferJob]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(JSONEncoder().encode(Archive(jobs: jobs)), file)
    }
}

extension BookTransferJob.Stage {
    var displayTitle: String {
        switch self {
        case .preparing: "Preparing books"
        case .needsConnection: "Connect reader"
        case .connecting: "Connecting"
        case .ready: "Ready to send"
        case .waitingForOtherWork: "Waiting for reader task"
        case .sending: "Sending books"
        case .checking: "Checking saved results"
        case .paused: "Paused"
        case .confirmationUnknown: "Saved result needs checking"
        case .partialCompletion: "Some books saved"
        case .failed: "Transfer needs attention"
        case .completed: "Books saved on reader"
        case .discarded: "Transfer discarded"
        }
    }
}
