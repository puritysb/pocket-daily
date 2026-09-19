import Foundation

/// One decoded live-studio event off the WebSocket wire
/// (`docs/live-studio-v1.md` in the firmware repository).
enum LiveStudioEvent: Equatable {
    case hello(proto: String, deviceID: String, version: String)
    case status(CrossPointStatus)
    case frame(seq: Int, bytes: Int)
    case prefsChanged
    case bye

    static func decode(_ text: String) -> LiveStudioEvent? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1 else { return nil }
        if let hello = object["hello"] as? [String: Any],
           let proto = hello["proto"] as? String {
            return .hello(proto: proto,
                          deviceID: hello["deviceID"] as? String ?? "",
                          version: hello["version"] as? String ?? "")
        }
        if let status = object["status"] as? [String: Any],
           let json = try? JSONSerialization.data(withJSONObject: status),
           let decoded = try? JSONDecoder().decode(CrossPointStatus.self, from: json) {
            return .status(decoded)
        }
        if let frame = object["frame"] as? [String: Any],
           let seq = frame["seq"] as? Int,
           let bytes = frame["bytes"] as? Int {
            return .frame(seq: seq, bytes: bytes)
        }
        if let prefs = object["prefs"] as? [String: Any], prefs["changed"] as? Bool == true {
            return .prefsChanged
        }
        if object["bye"] != nil { return .bye }
        return nil
    }
}

/// Coalesces live-frame fetches against the reader's connection budget: one
/// fetch in flight at a time, newer announcements replace older pending ones,
/// and fetch starts are spaced at least a second apart. The X3's radio went
/// deaf after connection-per-chunk hammering, so pacing is part of the
/// contract, not an optimization.
struct FrameFetchPolicy {
    static let minimumFetchSpacing: TimeInterval = 1.0

    private(set) var inFlight = false
    private(set) var pendingSeq: Int?
    private var lastFetchAt = Date.distantPast

    /// Records the announcement and returns true when a fetch should start
    /// now (nothing in flight and spacing elapsed).
    mutating func shouldFetch(seq: Int, at now: Date = Date()) -> Bool {
        pendingSeq = seq
        guard !inFlight else { return false }
        guard now.timeIntervalSince(lastFetchAt) >= Self.minimumFetchSpacing else { return false }
        inFlight = true
        lastFetchAt = now
        pendingSeq = nil
        return true
    }

    /// Marks the in-flight fetch done; returns the newest seq announced while
    /// it ran, if any. The caller re-offers it through `shouldFetch`.
    mutating func fetchCompleted() -> Int? {
        inFlight = false
        return pendingSeq
    }

    mutating func reset() {
        inFlight = false
        pendingSeq = nil
    }
}

/// WebSocket client for the reader's live-studio listener. Subscribes after
/// `hello`, surfaces decoded events on the main actor, and shuts down
/// cleanly. Reconnection is left to the session layer (heartbeat + user
/// action) on purpose: a half-dead radio must not be hammered.
@MainActor
final class LiveSyncClient: NSObject {
    let host: String
    let wsPort: Int
    var onEvent: ((LiveStudioEvent) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?

    init(host: String, wsPort: Int) {
        self.host = host
        self.wsPort = wsPort
    }

    func start() {
        guard task == nil else { return }
        guard let url = URL(string: "ws://\(host):\(wsPort)/") else { return }
        let session = URLSession(configuration: .ephemeral)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveNext()
    }

    func stop() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receiveNext() {
        guard let task else { return }
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self, let current = self.task, current === task else { return }
                switch result {
                case let .success(message):
                    switch message {
                    case let .string(text):
                        if let event = LiveStudioEvent.decode(text) {
                            if case let .hello(proto, _, _) = event, proto == "live-studio/1" {
                                self.send(#"{"subscribe":{"frames":true,"minIntervalMs":300}}"#)
                            }
                            self.onEvent?(event)
                        }
                    case .data:
                        break
                    @unknown default:
                        break
                    }
                    self.receiveNext()
                case .failure:
                    // Transport gone: the session's heartbeat decides whether
                    // the connection is re-established. Do not auto-retry.
                    self.stop()
                }
            }
        }
    }

    private func send(_ text: String) {
        task?.send(.string(text)) { _ in }
    }
}
