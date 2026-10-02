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
    case malformedPiece
    case changedTwice
    case readerBusy
    case incomplete
    case fingerprintMismatch

    var errorDescription: String? {
        switch self {
        case .malformedPiece: "The reader sent an unexpected piece of the book. Try again."
        case .changedTwice: "The book changed on the reader while it was being copied. Try again when the reader is idle."
        case .readerBusy: "The reader is short of memory. Leave it on the Sync screen for a moment and try again."
        case .incomplete: "The copy is incomplete. Try again."
        case .fingerprintMismatch: "The copy does not match the book on the reader. Nothing was added; try again."
        }
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
            switch try await fetch(offset) {
            case let .data(piece):
                guard !piece.isEmpty, offset + Int64(piece.count) <= size else { throw ReaderDownloadError.malformedPiece }
                try handle.write(contentsOf: piece)
                offset += Int64(piece.count)
                busy = 0
                backoff = .milliseconds(500)
                progress(offset)
            case .busy:
                busy += 1
                guard busy <= busyLimit else { throw ReaderDownloadError.readerBusy }
                try await sleep(backoff)
                backoff = min(backoff * 2, .seconds(4))
            case .changed:
                guard !restarted else { throw ReaderDownloadError.changedTwice }
                restarted = true
                try handle.truncate(atOffset: 0)
                offset = 0
                progress(0)
            }
        }
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
