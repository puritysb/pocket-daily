import Foundation

/// What the studio's single Send control may do and what its status line says.
/// Pure: derived from the draft and the existing deployment/redraw records, so
/// "Shown on reader" can only appear after the reader's redraw receipt for the
/// exact revision the canvas shows.
enum ContentSendStatus: Equatable {
    case demo
    case disconnected
    case unsupported
    case invalid(String)
    case empty
    case ready
    case sending(String)
    case shown
    case storedNotShown
    case changed
    case failed
    case needsCheck

    struct Inputs: Equatable {
        var isDemo = false
        var connected = false
        /// Reader reports identity plus content presentation (a session exists).
        var canPresent = false
        var validation: String?
        var cardCount = 0
        var draftRevision: String?
        var phase: ContentDeployment.Phase?
        var redrawConfirmed: ContentActiveReceipt?
        var busy = false
    }

    static func evaluate(_ inputs: Inputs) -> ContentSendStatus {
        if inputs.isDemo { return .demo }
        switch inputs.phase {
        case .checking?: return .sending("Checking the reader")
        case .preparing?: return .sending("Preparing cards")
        case let .uploading(_, index, total)?: return .sending("Sending file \(index) of \(total)")
        case .activating?: return .sending("Activating on the reader")
        case .confirming?: return .sending("Waiting for the reader to show it")
        case .needsConfirmation?, .archived?: return .needsCheck
        default: break
        }
        guard inputs.connected else { return .disconnected }
        guard inputs.canPresent else { return .unsupported }
        if inputs.cardCount == 0 { return .empty }
        if let validation = inputs.validation { return .invalid(validation) }
        switch inputs.phase {
        case let .complete(active)?:
            guard active.revision == inputs.draftRevision else { return .changed }
            return inputs.redrawConfirmed == active ? .shown : .storedNotShown
        case .failed?, .cancelled?:
            return .failed
        default:
            return .ready
        }
    }

    /// Send never runs in demo, while another reader operation owns the
    /// connection, or for content already confirmed on screen.
    static func canSend(_ status: ContentSendStatus, busy: Bool, autoSend: Bool) -> Bool {
        guard !busy, !autoSend else { return false }
        switch status {
        case .ready, .changed, .failed, .storedNotShown: return true
        default: return false
        }
    }

    var label: String {
        switch self {
        case .demo: "Demo · nothing is sent to a reader"
        case .disconnected: "Connect a reader to send"
        case .unsupported: "This reader cannot show app cards. Update its firmware."
        case let .invalid(reason): reason
        case .empty: "Add a card to send"
        case .ready: "Ready to send"
        case let .sending(step): "\(step)…"
        case .shown: "Shown on reader"
        case .storedNotShown: "Saved on reader · screen not confirmed"
        case .changed: "Changes not sent"
        case .failed: "Not sent · see the message below"
        case .needsCheck: "Result unknown · check before sending again"
        }
    }

    var symbol: String {
        switch self {
        case .shown: "checkmark.circle.fill"
        case .sending: "arrow.triangle.2.circlepath"
        case .changed, .ready: "circle.dashed"
        case .storedNotShown, .needsCheck, .invalid, .unsupported: "exclamationmark.triangle"
        case .failed: "xmark.octagon"
        case .demo, .disconnected, .empty: "info.circle"
        }
    }

    /// The shared status meaning; `symbol` stays the more specific glyph.
    var tone: StatusTone {
        switch self {
        case .shown: .success
        case .sending, .changed, .ready: .onReader
        case .storedNotShown, .needsCheck, .unsupported: .pending
        case .invalid, .failed: .failure
        case .demo, .disconnected, .empty: .neutral
        }
    }
}
