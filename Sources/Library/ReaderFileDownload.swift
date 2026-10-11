import Foundation

/// One reply to `GET /api/pocket/v1/files/content` (firmware docs/reader-files.md,
/// "Reader file download"): a piece from the requested offset, or a state the
/// download recovers from.
enum ReaderFilePiece: Equatable {
    case data(Data)
    /// 503: the reader is short of working memory; retry the same offset later.
    case busy
    /// 409: the file changed (or the reader is busy with an upload); start again at 0.
    case changed
}

enum ReaderDownloadError: LocalizedError, Equatable {
    case unavailable
    case interrupted
    case malformedPiece
    case changedTwice
    case readerBusy
    case incomplete
    case fingerprintMismatch

    var errorDescription: String? {
        switch self {
        case .unavailable: "The reader cannot start a download right now. Wait for the current task or reconnect, then try again."
        case .interrupted: "The reader download was interrupted. Reconnect and try again; no incomplete book was added."
        case .malformedPiece: "The reader sent an unexpected piece of the book. Try again."
        case .changedTwice: "The book changed on the reader while it was being copied. Try again when the reader is idle."
        case .readerBusy: "The reader is short of memory. Leave it on the Sync screen for a moment and try again."
        case .incomplete: "The copy is incomplete. Try again."
        case .fingerprintMismatch: "The copy does not match the book on the reader. Nothing was added; try again."
        }
    }
}

/// One request, including rejection and cancellation before its I/O starts.
/// Contains counters only: no host, filename, book text or device identity.
@MainActor
final class ReaderDownloadOperation {
    enum Phase: String { case queued, fetching, waitingForReader, saving, verifying, completed, failed, cancelled, rejected }
    enum Event { case request, busy, restart, received(Int64), saving, verifying }
    private(set) var phase: Phase = .queued
    private(set) var received: Int64 = 0
    private(set) var requests = 0
    private(set) var busyReplies = 0
    private(set) var restarts = 0
    private(set) var errorCode: Int?
    private(set) var failurePhase: Phase?
    private(set) var terminal = false
    let size: Int64
    private let began = ProcessInfo.processInfo.systemUptime
    private var progressAt = ProcessInfo.processInfo.systemUptime
    private var completion: ((Result<URL, Error>) -> Void)?

    init(size: Int64, completion: @escaping (Result<URL, Error>) -> Void) {
        self.size = size; self.completion = completion
    }
    var diagnostics: [String: Any] {
        var value: [String: Any] = ["phase": phase.rawValue, "received": received, "size": size,
            "requests": requests, "busyReplies": busyReplies, "restarts": restarts,
            "elapsed": ProcessInfo.processInfo.systemUptime - began,
            "progressAge": ProcessInfo.processInfo.systemUptime - progressAt, "terminal": terminal]
        if let errorCode { value["errorCode"] = errorCode }
        if let failurePhase { value["failurePhase"] = failurePhase.rawValue }
        return value
    }
    func note(_ event: Event) {
        guard !terminal else { return }
        switch event {
        case .request: phase = .fetching; requests += 1
        case .busy: phase = .waitingForReader; busyReplies += 1
        case .restart: restarts += 1; received = 0
        case .received(let bytes): received = bytes; progressAt = ProcessInfo.processInfo.systemUptime
        case .saving: phase = .saving
        case .verifying: phase = .verifying
        }
    }
    func finish(_ result: Result<URL, Error>, phase: Phase) {
        guard !terminal else { return }
        if case .failure(let error) = result {
            errorCode = (error as NSError).code; failurePhase = self.phase
        }
        terminal = true; self.phase = phase
        let callback = completion; completion = nil
        callback?(result)
    }
    /// The lane can discard a cancelled operation before calling its body.
    func drained() {
        if !terminal { finish(.failure(ReaderDownloadError.interrupted), phase: .cancelled) }
    }
}

/// Copies one reader file piece by piece into a local file. The reader picks each
/// piece's size, so the offset advances by what arrived; a busy reader is retried
/// at the same offset with backoff, and a changed file restarts once from 0.
struct ReaderFileDownloader {
    var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    /// Consecutive busy replies before giving up.
    var busyLimit = 12

    @MainActor
    func download(size: Int64, to destination: URL,
                  fetch: (Int64) async throws -> ReaderFilePiece,
                  observe: (ReaderDownloadOperation.Event) -> Void = { _ in },
                  progress: (Int64) -> Void) async throws {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var restarted = false
        var busy = 0
        var backoff = Duration.milliseconds(500)
        while offset < size {
            try Task.checkCancellation()
            observe(.request)
            switch try await fetch(offset) {
            case let .data(piece):
                guard !piece.isEmpty, offset + Int64(piece.count) <= size else { throw ReaderDownloadError.malformedPiece }
                try handle.write(contentsOf: piece)
                offset += Int64(piece.count)
                busy = 0
                backoff = .milliseconds(500)
                progress(offset)
                observe(.received(offset))
            case .busy:
                observe(.busy)
                busy += 1
                guard busy <= busyLimit else { throw ReaderDownloadError.readerBusy }
                try await sleep(backoff)
                backoff = min(backoff * 2, .seconds(4))
            case .changed:
                observe(.restart)
                guard !restarted else { throw ReaderDownloadError.changedTwice }
                restarted = true
                try handle.truncate(atOffset: 0)
                offset = 0
                progress(0)
            }
        }
        observe(.saving)
        try handle.synchronize()
        let written = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value
        guard written == size else { throw ReaderDownloadError.incomplete }
    }

    /// The reader reports a fingerprint for its recent books; a copy must match it.
    static func verify(_ url: URL, document: String?) throws {
        guard let document else { return }
        guard try KOReaderDocumentDigest.partialMD5(of: url) == document.lowercased() else {
            throw ReaderDownloadError.fingerprintMismatch
        }
    }
}
