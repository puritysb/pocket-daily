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
        let (data, response) = try await session.data(from: url)
        try Self.requireSuccess(response)
        return try JSONDecoder().decode(CrossPointStatus.self, from: data)
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
