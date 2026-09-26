import Foundation

/// A Pocket Daily screen the reader can draw inside a Sync session
/// (sibling docs/pocket-screen-present-v1.md).
enum ReaderScreen: String, Sendable {
    case home, brief
}

/// The reader's receipt for one screen presentation request.
struct ScreenPresentationReceipt: Decodable, Equatable {
    enum Phase: String, Decodable { case queued, rendered, failed }
    let schema: UInt16
    let deviceID: String
    let surface: String
    let generation: UInt32
    let phase: Phase
    var failure: String? = nil

    /// Accepts only a receipt for exactly this reader, screen and profile generation.
    static func decode(_ data: Data, deviceID: String, screen: ReaderScreen, generation: UInt32) throws -> Self {
        guard data.count <= 512 else { throw ContentDeployment.Failure.invalidReceipt }
        let receipt = try JSONDecoder().decode(Self.self, from: data)
        guard receipt.matches(deviceID: deviceID, screen: screen, generation: generation) else {
            throw ContentDeployment.Failure.invalidReceipt
        }
        return receipt
    }

    func matches(deviceID: String, screen: ReaderScreen, generation: UInt32) -> Bool {
        schema == 1 && self.deviceID == deviceID && surface == screen.rawValue && self.generation == generation
    }
}

/// Asks the reader to draw a saved Home or Daily Brief and follows the receipt
/// with reads only, like `ContentPresenter`: a lost POST response is resolved
/// by reading, and nothing is ever re-requested. `rendered` means the display
/// driver finished, not optical proof.
@MainActor
enum ScreenPresenter {
    static let maximumStateReads = ContentPresenter.maximumStateReads
    static let confirmationBudget = ContentPresenter.confirmationBudget

    enum Failure: LocalizedError, Equatable {
        case failed, unconfirmed, memory, preparation
        var errorDescription: String? {
            switch self {
            case .failed: "The reader could not draw the screen."
            case .unconfirmed: "The reader has not confirmed drawing the screen."
            case .memory: "The reader does not have enough memory to draw the screen right now. It shows the change when you leave Sync."
            case .preparation: "The reader could not prepare the screen or its fonts. It shows the change when you leave Sync."
            }
        }
    }

    struct Operations {
        var request: () async throws -> ScreenPresentationReceipt
        var state: () async throws -> ScreenPresentationReceipt
        var wait: () async throws -> Void = { try await Task.sleep(for: .seconds(2)) }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    }

    static func present(deviceID: String, screen: ReaderScreen, generation: UInt32,
                        using operations: Operations) async throws {
        try Task.checkCancellation()
        var receipt: ScreenPresentationReceipt
        do { receipt = try await operations.request() }
        catch {
            if error is CancellationError { throw error }
            let requestError = error
            // A lost POST response may still have queued the frame. Only read,
            // and keep the POST's own rejection when the read fails too.
            do { receipt = try await operations.state() }
            catch {
                if error is CancellationError { throw error }
                throw requestError
            }
        }
        let deadline = operations.now() + confirmationBudget
        for attempt in 0...maximumStateReads {
            try Task.checkCancellation()
            guard receipt.matches(deviceID: deviceID, screen: screen, generation: generation) else {
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
                    // Drawing can briefly keep the reader's single core from
                    // answering; retry the bounded read only.
                    guard let networkError = error as? URLError,
                          [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                           .cannotFindHost, .notConnectedToInternet].contains(networkError.code) else { throw error }
                }
            }
        }
        throw Failure.unconfirmed
    }
}
