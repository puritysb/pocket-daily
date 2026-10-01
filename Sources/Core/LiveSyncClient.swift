import Foundation

/// One decoded live-studio event off the WebSocket wire
/// (`docs/live-studio-v1.md` in the firmware repository).
enum LiveStudioEvent: Equatable {
    case hello(proto: String, deviceID: String, version: String)
    case status(CrossPointStatus)
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
        if let prefs = object["prefs"] as? [String: Any], prefs["changed"] as? Bool == true {
            return .prefsChanged
        }
        if object["bye"] != nil { return .bye }
        return nil
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
    var isRunning: Bool { task != nil }

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
                                // Status and preference pushes only; readers no longer stream frames.
                                self.send(#"{"subscribe":{}}"#)
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
