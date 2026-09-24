import Combine
import Foundation

/// Internal service contract, implemented by ReaderContentTransport.
/// An adapter must bind every mutation to the same reader identity, publish
/// uploads atomically, and report read/verification errors rather than no-active.
@MainActor
protocol ContentDeploymentTransport {
    func readState() async throws -> ContentDeviceState
    func prepare(revision: String, manifest: Data) async throws -> ContentPreparation
    func upload(_ asset: ContentRevision.Asset, revision: String) async throws -> ContentDestination
    /// Seals and activates; a thrown error does not prove the command failed.
    func activate(revision: String) async throws
}

struct ContentDestination: Equatable {
    let deviceID: String
    let revision: String
}

struct ContentActiveReceipt: Equatable, Decodable {
    let revision: String
    let generation: UInt32
}

struct ContentDeviceState {
    let deviceID: String
    let schema: UInt16
    let capabilities: UInt16
    /// Fully verified storage selection, not evidence of screen rendering.
    let active: ContentActiveReceipt?
}

struct ContentPreparation {
    let destination: ContentDestination
    /// Actual verified files in this candidate directory, never a local cache.
    let verifiedFiles: [ContentManifest.File]
}

@MainActor
final class ContentDeployment: ObservableObject {
    enum Phase: Equatable {
        case idle, checking, preparing
        case uploading(path: String, index: Int, total: Int)
        case activating, confirming
        case complete(ContentActiveReceipt)
        case failed, cancelled, needsConfirmation, archived
    }
    enum Failure: LocalizedError, Equatable {
        case busy, identityMismatch, unsupported, invalidReceipt, notConfirmed
        var errorDescription: String? {
            switch self {
            case .busy: "Another content deployment is running. Wait for it to finish."
            case .identityMismatch: "The reader identity changed. Select the intended reader before applying content."
            case .unsupported: "This reader does not support the content format being applied."
            case .invalidReceipt: "The reader returned an invalid content verification result. The result cannot be trusted."
            case .notConfirmed: "The reader has not confirmed this content revision as active."
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    private(set) var failurePhase: Phase?
    @Published private(set) var archivedRecord: URL?
    private var running = false
    private var pending: PendingContentActivation?
    private let deviceID: String
    private let transport: (any ContentDeploymentTransport)?
    private let journal: ContentActivationJournal?

    init(deviceID: String, transport: any ContentDeploymentTransport, journal: ContentActivationJournal? = nil) {
        self.deviceID = deviceID
        self.transport = transport
        self.journal = journal
    }

    init(restoring pending: PendingContentActivation, journal: ContentActivationJournal) {
        self.deviceID = pending.deviceID
        self.pending = pending
        self.journal = journal
        self.transport = nil
        self.phase = .needsConfirmation
    }

    /// No automatic activation retry. A later user retry starts with a fresh
    /// reader state and returns immediately if the target is already active.
    func deploy(_ revision: ContentRevision) async throws -> ContentActiveReceipt {
        guard !running else { throw Failure.busy }
        // An unresolved operation belongs to its original immutable snapshot.
        // Refuse re-entry before changing phase/pending or touching transport,
        // including coordinators without an on-disk journal.
        guard pending == nil else { throw ContentActivationJournal.Failure.unresolved }
        guard let transport else { throw Failure.notConfirmed }
        running = true
        defer { running = false }
        failurePhase = nil
        var activationAttempted = false
        do {
            try Task.checkCancellation()
            phase = .checking
            guard try await journal?.load() == nil else { throw ContentActivationJournal.Failure.unresolved }
            let initial = try await transport.readState()
            try validate(initial, for: revision)
            try Task.checkCancellation()
            if let active = initial.active, active.revision == revision.revision {
                phase = .complete(active)
                return active
            }

            phase = .preparing
            let prepared = try await transport.prepare(revision: revision.revision, manifest: revision.manifest)
            try validate(prepared.destination, revision: revision.revision)
            let missing = try missingFiles(revision, prepared: prepared.verifiedFiles)
            for (index, asset) in missing.enumerated() {
                try Task.checkCancellation()
                phase = .uploading(path: asset.path, index: index + 1, total: missing.count)
                let destination = try await transport.upload(asset, revision: revision.revision)
                try validate(destination, revision: revision.revision)
            }
            try Task.checkCancellation()
            phase = .activating
            let intent = PendingContentActivation(id: UUID(), deviceID: deviceID, revision: revision.revision,
                                                  previousGeneration: initial.active?.generation ?? 0,
                                                  capabilities: revision.requiredCapabilities)
            try await journal?.begin(intent)
            pending = intent
            // From the durable intent onward, a restart conservatively treats
            // the outcome as unknown, even if cancellation precedes the send.
            activationAttempted = true
            try Task.checkCancellation()
            do {
                try await transport.activate(revision: revision.revision)
            } catch {
                // Even an explicit transport error may follow a durable commit.
                // Resolve once by reading state, never by resending activation.
                if error is CancellationError { throw error }
            }
            try Task.checkCancellation()
            phase = .confirming
            let confirmed = try await transport.readState()
            try validate(confirmed, for: revision)
            try Task.checkCancellation()
            guard let active = confirmed.active, active.revision == revision.revision else {
                throw Failure.notConfirmed
            }
            if let previous = initial.active, active.generation <= previous.generation {
                throw Failure.invalidReceipt
            }
            try await journal?.complete(intent)
            phase = .complete(active)
            pending = nil
            return active
        } catch {
            failurePhase = phase
            if activationAttempted {
                phase = .needsConfirmation
            } else {
                phase = error is CancellationError ? .cancelled : .failed
            }
            throw error
        }
    }

    /// Resolves an ambiguous activation using one read only. Never stages,
    /// uploads or repeats activation, including when cancelled or disconnected.
    func confirmPendingActivation(readState: (() async throws -> ContentDeviceState)? = nil) async throws -> ContentActiveReceipt {
        guard !running else { throw Failure.busy }
        guard let pending else { throw Failure.notConfirmed }
        running = true
        defer { running = false }
        phase = .confirming
        do {
            try Task.checkCancellation()
            let state: ContentDeviceState
            if let readState { state = try await readState() }
            else if let transport { state = try await transport.readState() }
            else { throw Failure.notConfirmed }
            try validate(state, capabilities: pending.capabilities)
            try Task.checkCancellation()
            guard let active = state.active, active.revision == pending.revision else { throw Failure.notConfirmed }
            guard active.generation > pending.previousGeneration else { throw Failure.invalidReceipt }
            try await journal?.complete(pending)
            self.pending = nil
            phase = .complete(active)
            return active
        } catch {
            phase = .needsConfirmation
            throw error
        }
    }

    private func validateIdentity(_ received: String) throws {
        guard !deviceID.isEmpty, received == deviceID else { throw Failure.identityMismatch }
    }

    func archivePendingActivation() async throws {
        guard !running else { throw Failure.busy }
        guard let pending, let journal else { throw Failure.notConfirmed }
        running = true
        defer { running = false }
        // No transport access. On any persistence error, retain pending state.
        let backup = try await journal.archive(pending)
        archivedRecord = backup
        self.pending = nil
        phase = .archived
    }

    private func validate(_ destination: ContentDestination, revision: String) throws {
        try validateIdentity(destination.deviceID)
        guard destination.revision == revision else { throw Failure.invalidReceipt }
    }

    private func validate(_ state: ContentDeviceState, for revision: ContentRevision) throws {
        try validate(state, capabilities: revision.requiredCapabilities)
    }

    private func validate(_ state: ContentDeviceState, capabilities required: UInt16) throws {
        try validateIdentity(state.deviceID)
        guard state.schema == 1, state.capabilities & required == required else { throw Failure.unsupported }
        if let active = state.active {
            guard active.generation > 0, active.revision.utf8.count == 64,
                  active.revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw Failure.invalidReceipt
            }
        }
    }

    private func missingFiles(_ revision: ContentRevision, prepared: [ContentManifest.File]) throws -> [ContentRevision.Asset] {
        guard prepared.count <= 16 else { throw Failure.invalidReceipt }
        var inventory: [String: ContentManifest.File] = [:]
        for file in prepared {
            guard file.sha256.count == 32, inventory[file.path] == nil,
                  revision.files.contains(where: { $0.path == file.path }) else { throw Failure.invalidReceipt }
            inventory[file.path] = file
        }
        return revision.files.filter { asset in
            guard let file = inventory[asset.path] else { return true }
            return file.kind != asset.kind || file.bytes != asset.data.count || file.sha256 != asset.sha256
        }
    }
}
