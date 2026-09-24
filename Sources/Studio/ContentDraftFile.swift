import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Self-contained authoring document. Not firmware, a deployment receipt, or
/// the private on-disk generation/recovery record. Images are canonical PBM.
enum ContentDraftFile {
    static let maximumBytes = 512 * 1024
    private static let format = "pocket-daily/content-draft"
    private struct Envelope: Codable {
        let format: String
        let schema: UInt16
        let draft: ContentDraft
    }
    enum Failure: LocalizedError {
        case size, format, schema, fields, references
        var errorDescription: String? {
            switch self {
            case .size: "Choose a content draft JSON file of at most 512 KiB."
            case .format: "This is not a Pocket Daily content draft. Choose a file exported from the content editor."
            case .schema: "This content draft requires a newer version of Pocket Daily."
            case .fields: "The content draft has missing, invalid or unsupported fields. Nothing was imported."
            case .references: "Card IDs or image references are invalid. Every image must be included and referenced."
            }
        }
    }

    static func validate(_ draft: ContentDraft) throws {
        try draft.validateStorageBounds()
        guard Set(draft.cards.map(\.id)).count == draft.cards.count else { throw Failure.references }
        for card in draft.cards {
            // Incomplete authoring text remains exportable. IDs and assets must
            // still be usable by the editor; publishing validates actual text.
            _ = try ContentCard(id: card.id, title: "Draft", question: "Draft").encoded()
        }
        let references = Set(draft.cards.map(\.imagePath).filter { !$0.isEmpty })
        guard references == Set(draft.images.keys) else { throw Failure.references }
        for bytes in draft.images.values { _ = try ContentImage.decode(bytes) }
    }

    static func encode(_ draft: ContentDraft) throws -> Data {
        try validate(draft)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let bytes = try encoder.encode(Envelope(format: format, schema: 1, draft: draft))
        guard bytes.count <= maximumBytes else { throw Failure.size }
        return bytes
    }

    static func decode(_ bytes: Data) throws -> ContentDraft {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw Failure.size }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              root["format"] as? String == format else { throw Failure.format }
        struct Header: Decodable { let schema: UInt16 }
        guard let header = try? JSONDecoder().decode(Header.self, from: bytes) else { throw Failure.format }
        guard header.schema == 1 else { throw Failure.schema }
        guard Set(root.keys) == ["format", "schema", "draft"],
              let fields = root["draft"] as? [String: Any], Set(fields.keys) == ["cards", "images"],
              let cards = fields["cards"] as? [[String: Any]], cards.count <= 3,
              cards.allSatisfy({ Set($0.keys) == ["id", "title", "question", "context", "imagePath", "layout"] &&
                  !($0["layout"] is NSNull) }) else { throw Failure.fields }
        let document: Envelope
        do { document = try JSONDecoder().decode(Envelope.self, from: bytes) }
        catch { throw Failure.fields }
        try validate(document.draft)
        return document.draft
    }

    static func load(_ url: URL) async throws -> ContentDraft {
        try Task.checkCancellation()
        let draft = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return try decode(handle.read(upToCount: maximumBytes + 1) ?? Data())
        }.value
        try Task.checkCancellation()
        return draft
    }
}

struct ContentDraftDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let draft: ContentDraft
    init(draft: ContentDraft) { self.draft = draft }
    init(configuration: ReadConfiguration) throws {
        guard let bytes = configuration.file.regularFileContents else { throw ContentDraftFile.Failure.format }
        draft = try ContentDraftFile.decode(bytes)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ContentDraftFile.encode(draft))
    }
}

#if DEBUG
/// UUID-scoped UI-test documents only; never the user's saved content. The
/// fixture uses the real encoder/reader but bypasses native provider selection.
enum ContentDraftUITestFiles {
    static func storeURL(_ id: UUID) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("PocketContentUITests/\(id.uuidString)/draft.json")
    }
    static func importFixture(_ id: UUID) async throws -> URL {
        try await Task.detached(priority: .userInitiated) {
            let url = storeURL(id).deletingLastPathComponent().appendingPathComponent("import.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: url.path) {
                let draft = ContentDraft(cards: [.init(id: "imported", title: "Imported card", question: "Imported text",
                                                       imagePath: "picture.pbm", layout: .sideBySide)],
                                         images: ["picture.pbm": Data("P4\n8 1\n".utf8) + Data([0x81])])
                try encodeFixture(draft, to: url)
            }
            return url
        }.value
    }
    private static func encodeFixture(_ draft: ContentDraft, to url: URL) throws {
        try ContentDraftFile.encode(draft).write(to: url, options: .withoutOverwriting)
    }
}
#endif
