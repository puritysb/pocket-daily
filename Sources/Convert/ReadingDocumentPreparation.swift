import Foundation

enum ReadingDocumentFormat: String, CaseIterable, Sendable {
    case epub = "EPUB", text = "Plain text"
}

/// The first UI input for the EPUB engine. Article import can supply multiple chapters later.
enum ReadingDocumentPreparation {
    static func create(title: String, text: String, format: ReadingDocumentFormat,
                       directory: URL = TextDocument.directory) async throws -> URL {
        try Task.checkCancellation()
        switch format {
        case .epub:
            guard text.utf8.count <= EPUBExporter.maximumInputBytes else { throw EPUBExportError.inputTooLarge }
            let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = title.isEmpty ? "Reading" : title
            let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            return try await EPUBExporter.write(
                EPUBDocument(title: name, chapters: [.init(title: name, paragraphs: normalized.components(separatedBy: "\n\n"))]),
                to: directory)
        case .text:
            // Existing plain-text behavior stays available; its blocking write also stays off the UI actor.
            let url = try await Task.detached(priority: .userInitiated) {
                try TextDocument.write(title: title, text: text, directory: directory)
            }.value
            if Task.isCancelled {
                try await removeExport(at: url)
                throw CancellationError()
            }
            return url
        }
    }

    /// Only for URLs produced by create: removes their owned UUID export folder after the queue copy.
    static func removeExport(at url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }.value
    }
}

extension PocketModel {
    enum ReadingPreparationFailure: LocalizedError {
        case unavailable
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "File preparation is unavailable. Leave demo mode or wait for the current operation, then try again."
            case .failed(let detail): detail
            }
        }
    }

    /// Uses the existing durable local preparation lane. Never sends or connects to a reader.
    /// Wait even when the caller is cancelled: the local copy may already have committed.
    func prepareGeneratedReadingFile(_ url: URL) async throws {
        let previous = Set(preparedTransfers.map(\.id))
        guard let work = upload(url) else { throw ReadingPreparationFailure.unavailable }
        await work.value
        guard preparedTransfers.contains(where: { !previous.contains($0.id) && $0.filename == url.lastPathComponent }) else {
            throw ReadingPreparationFailure.failed(message)
        }
    }
}
