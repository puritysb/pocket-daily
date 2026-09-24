import Foundation
import Combine

/// Explicit, editor-lifetime authorization. Keeps only the newest edit while
/// the existing Apply runs; an uncertain result stops rather than resends.
@MainActor
final class ContentLiveApply: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var message = "Live apply is off."
    private var pending: ContentRevision?
    private var editGeneration = 0
    private var runID = UUID()
    private var worker: Task<Void, Never>?
    private var apply: ((ContentRevision) async -> Bool)?
    private var confirmedRevision: String?
    private let settle: () async throws -> Void

    init(settle: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(800)) }) {
        self.settle = settle
    }

    func start(revision: ContentRevision, apply: @escaping (ContentRevision) async -> Bool) {
        stop()
        self.apply = apply
        isEnabled = true
        update(revision)
    }

    func stop(message: String = "Live apply is off.") {
        isEnabled = false
        runID = UUID()
        worker?.cancel()
        worker = nil
        pending = nil
        apply = nil
        confirmedRevision = nil
        self.message = message
    }

    /// nil invalidates any queued valid draft while the user is still typing.
    func update(_ revision: ContentRevision?) {
        guard isEnabled else { return }
        editGeneration += 1
        pending = revision
        message = revision == nil ? "Waiting for valid content…" : "Waiting for edits to settle…"
        guard worker == nil else { return }
        let id = runID
        worker = Task { [weak self] in
            guard let self else { return }
            defer { if self.runID == id { self.worker = nil } }
            while self.isEnabled, self.runID == id, !Task.isCancelled {
                let generation = self.editGeneration
                do { try await self.settle() } catch { return }
                guard !Task.isCancelled, self.runID == id else { return }
                if generation != self.editGeneration { continue }
                guard let revision = self.pending else { return }
                self.pending = nil
                if revision.revision != self.confirmedRevision {
                    self.message = "Applying content to this reader…"
                    guard let apply = self.apply else { return }
                    let success = await apply(revision)
                    guard !Task.isCancelled, self.runID == id else { return }
                    guard success else {
                        self.stop(message: "Live apply stopped. Check the application result before starting again; nothing will be retried automatically.")
                        return
                    }
                    self.confirmedRevision = revision.revision
                }
                if generation == self.editGeneration {
                    self.message = "Reader redraw confirmed. Live apply is ready for the next edit."
                    return
                }
            }
        }
    }
}
