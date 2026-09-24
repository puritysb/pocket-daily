import Foundation

struct PendingContentActivation: Codable, Equatable, Sendable {
    let id: UUID
    let deviceID: String
    let revision: String
    let previousGeneration: UInt32
    let capabilities: UInt16

    func validate() throws {
        guard deviceID.utf8.count == 8,
              deviceID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }),
              revision.utf8.count == 64,
              revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              [1, 3, 5, 7].contains(capabilities) else { throw ContentActivationJournal.Failure.invalid }
    }
}

/// Write-ahead local intent, not proof that any reader received a command.
/// A single app-owned actor serializes access; not a cross-process lock.
actor ContentActivationJournal {
    enum Failure: LocalizedError {
        case invalid, unresolved
        var errorDescription: String? {
            switch self {
            case .invalid: "The pending content record is unreadable. Preserve it before recovery."
            case .unresolved: "A previous content activation still needs confirmation. Check its outcome before applying again."
            }
        }
    }
    private struct Record: Codable { let schema: Int; let pending: PendingContentActivation? }
    private let file: URL
    init(file: URL) { self.file = file }

    static func applicationStore() throws -> ContentActivationJournal {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw CocoaError(.fileNoSuchFile)
        }
        return ContentActivationJournal(file: base.appendingPathComponent("Pocket/Studio/content-activation.json"))
    }

    func load() throws -> PendingContentActivation? {
        let handle: FileHandle
        do { handle = try FileHandle(forReadingFrom: file) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: 4097) ?? Data()
        guard bytes.count <= 4096 else { throw Failure.invalid }
        let record = try JSONDecoder().decode(Record.self, from: bytes)
        guard record.schema == 1 else { throw Failure.invalid }
        try record.pending?.validate()
        return record.pending
    }

    func begin(_ pending: PendingContentActivation) throws {
        try pending.validate()
        let previous = try load()
        guard previous == nil || previous == pending else { throw Failure.unresolved }
        if previous == pending { return }
        try write(pending)
    }

    func complete(_ pending: PendingContentActivation) throws {
        guard try load() == pending else { throw Failure.unresolved }
        try write(nil)
    }

    /// User-confirmed abandonment of checking, NOT cancellation of a reader
    /// operation. Preserve the exact record before releasing the local gate.
    func archive(_ pending: PendingContentActivation) throws -> URL {
        guard try load() == pending else { throw Failure.unresolved }
        let destination = file.deletingLastPathComponent()
            .appendingPathComponent("content-activation-archive-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: file, to: destination)
        try complete(pending)
        return destination
    }

    /// Explicit recovery of invalid data only. Valid or absent records must use
    /// normal confirmation/archive instead. I/O failures never authorize reset.
    func recoverUnreadableRecord() throws -> URL {
        do {
            _ = try load()
            throw Failure.unresolved
        } catch Failure.invalid {
            // Bounded parser rejected size/schema/field validation.
        } catch is DecodingError {
            // Preserve the original bytes even when no record can be decoded.
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw Failure.invalid }
        let backup = file.deletingLastPathComponent()
            .appendingPathComponent("content-activation-recovery-\(UUID().uuidString).json")
        try FileManager.default.copyItem(at: file, to: backup)
        try write(nil)
        return backup
    }

    private func write(_ pending: PendingContentActivation?) throws {
        let bytes = try JSONEncoder().encode(Record(schema: 1, pending: pending))
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: file, options: .atomic)
    }
}
