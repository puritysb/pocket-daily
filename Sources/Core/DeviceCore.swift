import Foundation

/// One unit of device-facing change, applied to `DeviceState` through a pure
/// reducer so event handling stays testable without hardware. The
/// device-sourced cases mirror the live-studio wire contract
/// (`docs/live-studio-v1.md` in the firmware repository); the connection and
/// transfer cases cover local session transitions.
enum DeviceEvent: Equatable {
    case status(CrossPointStatus)
    case frame(seq: Int, capturedAt: Date, data: Data)
    case preferences(ReaderPreferences?)
    case transferProgress(Double)
    case connection(DeviceConnectionPhase)
    case packStateChanged(activePack: String?, version: String?)
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

struct DeviceFrame: Equatable {
    let seq: Int
    let capturedAt: Date
    let data: Data
}

/// The immutable snapshot the studio surfaces render from.
struct DeviceState: Equatable {
    var status: CrossPointStatus?
    var preferences: ReaderPreferences?
    var latestFrame: DeviceFrame?
    /// Monotonic frame counter across gaps in reader-reported sequence
    /// numbers, so consumers can detect "a newer frame arrived" cheaply.
    var frameSequence = 0
    var transferProgress: Double?
    var phase: DeviceConnectionPhase = .idle
    var activePack: String?
    var activePackVersion: String?
}

enum DeviceStateReducer {
    /// Pure application of one event. A disconnect clears device-derived
    /// state, matching how a session ends today: stale status, preferences,
    /// and frames must not survive into the next session.
    static func apply(_ event: DeviceEvent, to state: DeviceState) -> DeviceState {
        var next = state
        switch event {
        case let .status(status):
            next.status = status
            next.phase = .connected
        case let .frame(seq, capturedAt, data):
            next.frameSequence = max(state.frameSequence + 1, seq)
            next.latestFrame = DeviceFrame(seq: seq, capturedAt: capturedAt, data: data)
        case let .preferences(preferences):
            next.preferences = preferences
        case let .transferProgress(progress):
            next.transferProgress = progress
        case let .connection(phase):
            next.phase = phase
            if phase == .disconnected {
                next.status = nil
                next.preferences = nil
                next.latestFrame = nil
                next.transferProgress = nil
            }
        case let .packStateChanged(activePack, version):
            next.activePack = activePack
            next.activePackVersion = version
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
    /// No reader (or demo mode) is offline. A reader without the
    /// advertisement is a legacy firmware and stays on the heartbeat poll; a
    /// non-push advertisement (private AP, low heap) also means polling.
    static func syncMode(status: CrossPointStatus?, isDemoMode: Bool = false) -> DeviceSyncMode {
        guard !isDemoMode, let status else { return .offline }
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
