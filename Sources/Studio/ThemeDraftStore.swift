import Foundation

/// The existing metric editor's local document, not a device activation receipt.
/// These authoring bounds deliberately match its controls, not every PDUI field.
struct ThemeDraft: Codable, Equatable, Sendable {
    var headerHeight = 44
    var listRowHeight = 56
    var menuRowHeight = 60
    var menuSpacing = 8
    var tabBarHeight = 40
    var contentSidePadding = 20
    var popupCornerRadius = 8
    var popupTextBold = true

    var overrides: [String: Int] {
        ["headerHeight": headerHeight, "listRowHeight": listRowHeight,
         "menuRowHeight": menuRowHeight, "menuSpacing": menuSpacing,
         "tabBarHeight": tabBarHeight, "contentSidePadding": contentSidePadding,
         "popupCornerRadius": popupCornerRadius, "popupTextBold": popupTextBold ? 1 : 0]
    }

    func validate() throws {
        guard (20...120).contains(headerHeight), (30...120).contains(listRowHeight),
              (30...120).contains(menuRowHeight), (0...32).contains(menuSpacing),
              (20...80).contains(tabBarHeight), (0...64).contains(contentSidePadding),
              (0...32).contains(popupCornerRadius) else { throw ThemeDraftStore.Failure.bounds }
    }
}

protocol ThemeDraftStorage: Sendable {
    func load() async throws -> ThemeDraftStore.Saved?
    func save(_ draft: ThemeDraft, replacing generation: UInt64?, recoveryID: UUID?) async throws -> ThemeDraftStore.Saved
    func recover(keeping draft: ThemeDraft) async throws -> ThemeDraftStore.Recovery
}

/// One app-owned actor serializes local writes. Not a cross-process file lock.
actor ThemeDraftStore: ThemeDraftStorage {
    private struct Header: Decodable { let schema: UInt16 }
    struct Saved: Codable, Equatable, Sendable {
        let schema: UInt16
        let generation: UInt64
        let draft: ThemeDraft
        let recoveryID: UUID?

        init(schema: UInt16, generation: UInt64, draft: ThemeDraft, recoveryID: UUID? = nil) {
            self.schema = schema
            self.generation = generation
            self.draft = draft
            self.recoveryID = recoveryID
        }
    }
    struct Recovery: Sendable {
        let saved: Saved
        let backup: URL?
    }
    struct RecoveryFailure: LocalizedError {
        let backup: URL
        let underlying: Error
        var errorDescription: String? {
            "The theme draft could not be recovered. The previous file was preserved at \(backup.path). \(underlying.localizedDescription)"
        }
    }

    enum Failure: LocalizedError, Equatable {
        case bounds, unsupportedSchema, invalidGeneration, conflict, corrupt
        var errorDescription: String? {
            switch self {
            case .bounds: "The theme draft exceeds the supported size or metric limits. Keep the original file before changing it."
            case .unsupportedSchema: "This theme draft requires a newer app. Update the app; the saved file has not been replaced."
            case .invalidGeneration: "The theme draft metadata is invalid. Preserve the saved file before recovering it."
            case .conflict: "Another editor saved a newer theme draft. Your edits are kept here; compare them before replacing the saved file."
            case .corrupt: "The saved theme draft cannot be decoded. Preserve the file before recovering it; it has not been overwritten."
            }
        }
    }

    static let maximumBytes = 16 * 1024
    private let file: URL
    init(file: URL) { self.file = file }

    static func applicationStore() throws -> ThemeDraftStore {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return ThemeDraftStore(file: base.appendingPathComponent("Pocket/Studio/theme-draft.json"))
    }

    func load() throws -> Saved? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard bytes.count <= Self.maximumBytes else { throw Failure.bounds }
        let saved: Saved
        do {
            let decoder = JSONDecoder()
            let schema = try decoder.decode(Header.self, from: bytes).schema
            guard schema == 1 || schema == 2 else { throw Failure.unsupportedSchema }
            saved = try decoder.decode(Saved.self, from: bytes)
        }
        catch let error as Failure { throw error }
        catch { throw Failure.corrupt }
        guard saved.generation > 0 else { throw Failure.invalidGeneration }
        guard (saved.schema == 1 && saved.recoveryID == nil) ||
              (saved.schema == 2 && saved.recoveryID != nil) else { throw Failure.invalidGeneration }
        try saved.draft.validate()
        return saved
    }

    func save(_ draft: ThemeDraft, replacing generation: UInt64?, recoveryID: UUID? = nil) throws -> Saved {
        try draft.validate()
        let previous = try load() // Unknown/corrupt data is never treated as absent.
        guard previous?.generation == generation, previous?.recoveryID == recoveryID else { throw Failure.conflict }
        if let previous, previous.draft == draft { return previous }
        let current = previous?.generation ?? 0
        guard current < UInt64.max else { throw Failure.invalidGeneration }
        let saved = Saved(schema: recoveryID == nil ? 1 : 2, generation: current + 1,
                          draft: draft, recoveryID: recoveryID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(saved)
        guard bytes.count <= Self.maximumBytes else { throw Failure.bounds }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
        return saved
    }

    /// Explicit recovery only: preserve original bytes before publishing the
    /// chosen draft. A new epoch rejects stale pre-recovery generation tokens.
    func recover(keeping draft: ThemeDraft) throws -> Recovery {
        try draft.validate()
        let saved = Saved(schema: 2, generation: 1, draft: draft, recoveryID: UUID())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(saved)
        guard bytes.count <= Self.maximumBytes else { throw Failure.bounds }
        let parent = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let attributes: [FileAttributeKey: Any]?
        do { attributes = try FileManager.default.attributesOfItem(atPath: file.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { attributes = nil }
        var backup: URL?
        if let attributes {
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw CocoaError(.fileReadUnsupportedScheme)
            }
            let destination = parent.appendingPathComponent("theme-draft-backup-\(UUID().uuidString).json")
            try FileManager.default.copyItem(at: file, to: destination)
            backup = destination
        }
        do { try bytes.write(to: file, options: .atomic) }
        catch {
            if let backup { throw RecoveryFailure(backup: backup, underlying: error) }
            throw error
        }
        return Recovery(saved: saved, backup: backup)
    }
}
