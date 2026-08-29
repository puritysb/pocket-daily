import Foundation

struct CrossPointStatus: Codable, Equatable {
    let version: String
    let ip: String
    let mode: String
    let rssi: Int
    let freeHeap: Int
    let uptime: Int
    let device: String
}

struct ReaderPreferences: Equatable, Sendable {
    var startupApp = 1
    var pocketDailySleepCover = true
    var sleepTimeoutMinutes = 10
    var fontSize = 1
}

actor CrossPointClient {
    enum ClientError: LocalizedError {
        case invalidAddress
        case invalidFilename
        case unexpectedMessage(String)

        var errorDescription: String? {
            switch self {
            case .invalidAddress: "The reader address is invalid."
            case .invalidFilename: "The selected filename cannot be sent."
            case let .unexpectedMessage(message): "Unexpected reader response: \(message)"
            }
        }
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func status(host: String = "192.168.4.1", port: Int = 80) async throws -> CrossPointStatus {
        guard let url = URL(string: "http://\(host):\(port)/api/status") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 4
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        return try JSONDecoder().decode(CrossPointStatus.self, from: data)
    }

    func preferences(host: String, port: Int) async throws -> ReaderPreferences {
        guard let url = URL(string: "http://\(host):\(port)/api/settings") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClientError.unexpectedMessage("invalid settings JSON")
        }
        let values = Dictionary(uniqueKeysWithValues: rows.compactMap { row -> (String, Int)? in
            guard let key = row["key"] as? String else { return nil }
            if let value = row["value"] as? Int { return (key, value) }
            if let value = row["value"] as? NSNumber { return (key, value.intValue) }
            return nil
        })
        return ReaderPreferences(
            startupApp: values["startupApp"] ?? 1,
            pocketDailySleepCover: (values["pocketDailySleepCover"] ?? 1) != 0,
            sleepTimeoutMinutes: values["sleepTimeoutMinutes"] ?? 10,
            fontSize: values["fontSize"] ?? 1
        )
    }

    func save(preferences: ReaderPreferences, host: String, port: Int) async throws {
        guard let url = URL(string: "http://\(host):\(port)/api/settings") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "startupApp": preferences.startupApp,
            "pocketDailySleepCover": preferences.pocketDailySleepCover ? 1 : 0,
            "sleepTimeoutMinutes": preferences.sleepTimeoutMinutes,
            "fontSize": preferences.fontSize,
        ])
        let (_, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
    }

    func upload(
        fileURL: URL,
        destination: String = "/",
        host: String = "192.168.4.1",
        port: Int = 81,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        let filename = fileURL.lastPathComponent
        guard !filename.isEmpty, !filename.contains(":"), !filename.contains("\n") else {
            throw ClientError.invalidFilename
        }
        guard let url = URL(string: "ws://\(host):\(port)/") else { throw ClientError.invalidAddress }

        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let total = Int64(values.fileSize ?? 0)
        let socket = session.webSocketTask(with: url)
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil) }

        try await socket.send(.string("START:\(filename):\(total):\(destination)"))
        try await requireText("READY", from: socket)

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var sent: Int64 = 0
        while let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
            try await socket.send(.data(chunk))
            sent += Int64(chunk.count)
            progress(sent, total)
        }

        while true {
            let message = try await socket.receive()
            let text: String
            switch message {
            case let .string(value): text = value
            case let .data(data): text = String(data: data, encoding: .utf8) ?? "<binary>"
            @unknown default: text = "<unknown>"
            }
            if text == "DONE" { return }
            if text.hasPrefix("ERROR:") { throw ClientError.unexpectedMessage(text) }
        }
    }

    private func requireText(_ expected: String, from socket: URLSessionWebSocketTask) async throws {
        let message = try await socket.receive()
        guard case let .string(value) = message, value == expected else {
            throw ClientError.unexpectedMessage(String(describing: message))
        }
    }

    private static func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw ClientError.unexpectedMessage("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }
}
