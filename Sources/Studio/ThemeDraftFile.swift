import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Portable authoring data, deliberately distinct from both PDUI and the
/// private generation/epoch-bearing persistence record. No device identity.
enum ThemeDraftFile {
    static let maximumBytes = 16 * 1024
    private static let format = "pocket-daily/theme-draft"
    private struct Envelope: Codable {
        let format: String
        let schema: UInt16
        let draft: ThemeDraft
    }
    enum Failure: LocalizedError {
        case size, format, schema, fields
        var errorDescription: String? {
            switch self {
            case .size: "Choose a theme draft JSON file of at most 16 KiB."
            case .format: "This is not a Pocket Daily theme draft file. Export a theme draft from Pocket Daily first."
            case .schema: "This theme draft uses an unsupported version. Update Pocket Daily before importing it."
            case .fields: "The theme draft has missing or unsupported fields. Nothing was imported."
            }
        }
    }

    static func encode(_ draft: ThemeDraft) throws -> Data {
        try draft.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(Envelope(format: format, schema: 1, draft: draft))
        guard data.count <= maximumBytes else { throw Failure.size }
        return data
    }

    static func decode(_ bytes: Data) throws -> ThemeDraft {
        guard !bytes.isEmpty, bytes.count <= maximumBytes else { throw Failure.size }
        guard let root = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              root["format"] as? String == format else { throw Failure.format }
        struct Header: Decodable { let schema: UInt16 }
        guard let header = try? JSONDecoder().decode(Header.self, from: bytes) else { throw Failure.format }
        guard header.schema == 1 else { throw Failure.schema }
        // Never silently strip a future author's fields when re-exporting.
        guard Set(root.keys) == ["format", "schema", "draft"],
              let fields = root["draft"] as? [String: Any],
              Set(fields.keys) == Set(ThemeDraft().overrides.keys) else { throw Failure.fields }
        let document: Envelope
        do { document = try JSONDecoder().decode(Envelope.self, from: bytes) }
        catch { throw Failure.fields }
        try document.draft.validate()
        return document.draft
    }

    static func load(_ url: URL) async throws -> ThemeDraft {
        try Task.checkCancellation()
        let draft = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            return try decode(data)
        }.value
        try Task.checkCancellation()
        return draft
    }
}

struct ThemeDraftDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let draft: ThemeDraft
    init(draft: ThemeDraft) { self.draft = draft }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw ThemeDraftFile.Failure.format }
        draft = try ThemeDraftFile.decode(data)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: try ThemeDraftFile.encode(draft))
    }
}
