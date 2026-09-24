import Foundation

struct ContentPresentationReceipt: Decodable, Equatable {
    enum Phase: String, Decodable { case queued, rendered, failed }
    let schema: UInt16
    let deviceID: String
    let revision: String
    let generation: UInt32
    let phase: Phase
    var failure: String? = nil

    static func decode(_ data: Data, deviceID: String, active: ContentActiveReceipt) throws -> Self {
        guard data.count <= 512 else { throw ContentDeployment.Failure.invalidReceipt }
        let receipt = try JSONDecoder().decode(Self.self, from: data)
        guard receipt.schema == 1, receipt.deviceID == deviceID,
              receipt.revision == active.revision, receipt.generation == active.generation,
              receipt.generation > 0, receipt.revision.utf8.count == 64,
              receipt.revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw ContentDeployment.Failure.invalidReceipt
        }
        return receipt
    }
}

/// Separate from durable activation. A display failure never repeats uploads,
/// activation, session-end or Wi-Fi operations. Rendered means driver completion,
/// not optical verification of the panel.
@MainActor
enum ContentPresenter {
    static let maximumStateReads = 45
    static let confirmationBudget: TimeInterval = 90
    enum Failure: LocalizedError {
        case failed, unconfirmed, memory, preparation
        var errorDescription: String? {
            switch self {
            case .failed: "The reader could not complete the content redraw."
            case .unconfirmed: "The reader has not confirmed the content redraw."
            case .memory: "The card is stored, but the reader does not have enough memory to prepare its screen. Nothing was resent."
            case .preparation: "The card is stored, but the reader could not prepare its content or fonts for display."
            }
        }
    }
    struct Operations {
        var request: () async throws -> ContentPresentationReceipt
        var state: () async throws -> ContentPresentationReceipt
        var wait: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    static func present(deviceID: String, active: ContentActiveReceipt, using operations: Operations) async throws {
        try Task.checkCancellation()
        var receipt: ContentPresentationReceipt
        do { receipt = try await operations.request() }
        catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            let requestError = error
            // Even a lost POST response may have queued a frame. Only read.
            // If recovery also fails, preserve the actionable POST rejection
            // (for example low memory), not the consequent "not presenting".
            do { receipt = try await operations.state() }
            catch {
                try Task.checkCancellation()
                if error is CancellationError { throw error }
                throw requestError
            }
        }
        let deadline = operations.now() + confirmationBudget
        for attempt in 0...maximumStateReads {
            try Task.checkCancellation()
            guard receipt.schema == 1, receipt.deviceID == deviceID, receipt.revision == active.revision,
                  receipt.generation == active.generation, receipt.generation > 0 else {
                throw ContentDeployment.Failure.invalidReceipt
            }
            switch receipt.phase {
            case .rendered: return
            case .failed:
                switch receipt.failure {
                case "memory": throw Failure.memory
                case "preparation": throw Failure.preparation
                default: throw Failure.failed
                }
            case .queued:
                guard attempt < maximumStateReads, operations.now() < deadline else { throw Failure.unconfirmed }
                try await operations.wait()
                try Task.checkCancellation()
                guard operations.now() < deadline else { throw Failure.unconfirmed }
                do { receipt = try await operations.state() }
                catch {
                    try Task.checkCancellation()
                    // The reader acknowledged the paint. Font preparation can
                    // temporarily prevent HTTP service on its single core.
                    // Retry only a bounded read, never POST, activation or upload.
                    guard let networkError = error as? URLError,
                          [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                           .cannotFindHost, .notConnectedToInternet].contains(networkError.code) else { throw error }
                }
            }
        }
    }
}
