import Foundation

/// One unit of device-facing change, applied to `DeviceState` through a pure
/// reducer so event handling stays testable without hardware. The
/// device-sourced cases mirror the live-studio wire contract
/// (`docs/live-studio-v1.md` in the firmware repository); the connection and
/// transfer cases cover local session transitions.
enum DeviceEvent: Equatable {
    case sessionStarted(CrossPointStatus)
    case status(CrossPointStatus)
    case preferences(ReaderPreferences?)
    case transferProgress(Double)
    case connection(DeviceConnectionPhase)
}

/// Coarse session phase. In M1 it is fed from the session model's own
/// transitions; later phases map live-studio connection events directly.
enum DeviceConnectionPhase: Equatable {
    case idle
    case searching
    case waitingForReader
    case connected
    case disconnected
}

/// The immutable snapshot the studio surfaces render from.
struct DeviceState: Equatable {
    var status: CrossPointStatus?
    var preferences: ReaderPreferences?
    var transferProgress: Double?
    var phase: DeviceConnectionPhase = .idle
}

enum DeviceStateReducer {
    /// Pure application of one event. A disconnect clears device-derived
    /// state, matching how a session ends today: stale status and preferences
    /// must not survive into the next session.
    static func apply(_ event: DeviceEvent, to state: DeviceState) -> DeviceState {
        var next = state
        switch event {
        case let .sessionStarted(status):
            next = apply(.status(status), to: DeviceState())
        case let .status(status):
            if let previous = state.status,
               previous.deviceID != status.deviceID || previous.device != status.device {
                next = DeviceState()
            }
            next.status = status
            next.phase = .connected
        case let .preferences(preferences):
            next.preferences = preferences
        case let .transferProgress(progress):
            next.transferProgress = progress
        case let .connection(phase):
            if phase != .connected {
                // Searching/waiting is not evidence that the previous reader
                // is still the one the mirror shows.
                next = DeviceState()
            }
            next.phase = phase
        }
        return next
    }
}

/// The observable device snapshot views bind as the studio migration
/// proceeds. M1: `PocketModel` feeds it alongside its legacy published
/// fields; views move onto it in later phases.
@MainActor
final class DeviceMirror: ObservableObject {
    @Published private(set) var state = DeviceState()

    func apply(_ event: DeviceEvent) {
        state = DeviceStateReducer.apply(event, to: state)
    }
}

/// How a session receives device state, decided from the reader's
/// `liveStudio` capability advertisement in `/api/status`.
enum DeviceSyncMode: Equatable {
    case offline
    case poll
    case push(wsPort: Int)
}

enum SyncModePolicy {
    // Match the firmware's listener admission floor, but use the current
    // HTTP status rather than its earlier, pre-listener allocation snapshot.
    // Opening a second socket and enabling frame capture are optional work.
    static let minimumPushFreeHeap = 16 * 1024
    /// No reader (or demo mode) is offline. A reader without the
    /// advertisement is a legacy firmware and stays on the heartbeat poll; a
    /// non-push advertisement (private AP, low heap) also means polling.
    static func syncMode(status: CrossPointStatus?, isDemoMode: Bool = false) -> DeviceSyncMode {
        guard !isDemoMode, let status else { return .offline }
        guard status.freeHeap >= minimumPushFreeHeap else { return .poll }
        guard let live = status.liveStudio,
              live.mode == "push",
              let port = live.wsPort, port > 0 else { return .poll }
        return .push(wsPort: port)
    }
}

/// The seam between device transport and app state. `PocketModel` conforms in
/// M1; `LiveDeviceSession` and `PreviewSession` arrive with the studio so
/// transport never leaks above this protocol. Main-actor isolated because it
/// surfaces UI-observable state.
@MainActor
protocol DeviceSession: AnyObject {
    var mirror: DeviceMirror { get }
    var syncMode: DeviceSyncMode { get }
}
