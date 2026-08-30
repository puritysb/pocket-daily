import Foundation

struct CrossPointStatus: Codable, Equatable {
    let version: String
    let ip: String
    let mode: String
    let rssi: Int
    let freeHeap: Int
    let uptime: Int
    let device: String
    let crashReportAvailable: Bool?
    let crashReportBytes: Int?
}

struct CrashDiagnostic: Equatable, Sendable {
    let version: String
    let resetReason: String
    let reason: String
    let breadcrumb: String?
    let lastEvent: String
    let analysis: String
    let report: String

    init(report: String) {
        self.report = report
        let lines = report.components(separatedBy: .newlines)
        version = Self.value(after: "CrossPoint version:", in: lines) ?? "Unknown firmware"
        resetReason = Self.value(after: "Reset reason:", in: lines) ?? "not recorded by this firmware"
        if let recordedReason = Self.value(after: "Panic reason:", in: lines), !recordedReason.isEmpty {
            reason = recordedReason
        } else {
            reason = "No panic message was captured."
        }
        breadcrumb = Self.value(after: "Runtime breadcrumb:", in: lines)

        let logBody = report.components(separatedBy: "Last logs:\n").dropFirst().first?
            .components(separatedBy: "\n\nStack memory:").first ?? ""
        let events = logBody.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        lastEvent = events.last ?? "No event was captured before reset."

        let lower = report.lowercased()
        if resetReason.contains("watchdog") {
            analysis = "A watchdog reset interrupted the device. The checkpoint and last event identify the active subsystem."
        } else if resetReason == "brownout" || resetReason == "power glitch" {
            analysis = "Power became unstable. The report separates this hardware/power event from a firmware panic."
        } else if lower.contains("stack canary") || lower.contains("stack overflow") {
            analysis = "Probable task stack exhaustion. The last event identifies the active subsystem."
        } else if lower.contains("abort()") && lower.contains("heap") {
            analysis = "Probable memory pressure or heap fragmentation. The firmware aborted while the recorded subsystem was active."
        } else if lower.contains("watchdog") || lower.contains("wdt") {
            analysis = "Probable watchdog reset caused by work that did not yield in time."
        } else if lower.contains("load access fault") || lower.contains("store access fault") {
            analysis = "Probable invalid memory access. The raw stack report is retained for symbolication."
        } else {
            analysis = "Crash captured. Export the raw report with the matching firmware build for symbolication."
        }
    }

    private static func value(after prefix: String, in lines: [String]) -> String? {
        guard let line = lines.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

struct ReaderPreferences: Equatable, Sendable {
    var startupApp = 1
    var pocketDailySleepCover = true
    var sleepTimeoutMinutes = 10
    var fontSize = 1
}

private struct PocketCommitResponse: Decodable {
    let size: Int64
    let crc32: String
}

private final class HTTPUploadDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) -> Void
    private var responseData = Data()
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var session: URLSession?

    init(progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.progress = progress
    }

    func upload(request: URLRequest, bodyFile: URL) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 60
            configuration.timeoutIntervalForResource = 900
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.uploadTask(with: request, fromFile: bodyFile).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        progress(totalBytesSent, totalBytesExpectedToSend)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        responseData.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let continuation else { return }
        self.continuation = nil
        self.session = nil
        session.finishTasksAndInvalidate()
        if let error {
            continuation.resume(throwing: error)
        } else if let response = task.response {
            continuation.resume(returning: (responseData, response))
        } else {
            continuation.resume(throwing: URLError(.badServerResponse))
        }
    }
}

actor CrossPointClient {
    enum ClientError: LocalizedError {
        case invalidAddress
        case invalidFilename
        case unexpectedMessage(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .invalidAddress: "The reader address is invalid."
            case .invalidFilename: "The selected filename cannot be sent."
            case let .unexpectedMessage(message): "Unexpected reader response: \(message)"
            case .verificationFailed: "The reader could not verify the transferred file. The previous file was kept."
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

    func crashDiagnostic(host: String, port: Int) async throws -> CrashDiagnostic {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/crash-report") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response, body: data)
        guard let report = String(data: data, encoding: .utf8), !report.isEmpty else {
            throw ClientError.unexpectedMessage("empty crash report")
        }
        return CrashDiagnostic(report: report)
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

    func uploadAtomically(
        fileURL: URL,
        publishedFilename: String? = nil,
        destination: String = "/",
        host: String = "192.168.4.1",
        port: Int = 80,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> String {
        let filename = publishedFilename ?? fileURL.lastPathComponent
        guard !filename.isEmpty, !filename.contains(":"), !filename.contains("\n") else {
            throw ClientError.invalidFilename
        }

        let normalizedDestination = Self.normalizedDirectory(destination)
        let stagingName = ".pocket-\(UUID().uuidString.lowercased()).part"
        guard let uploadURL = Self.url(host: host, port: port, path: "/upload", query: ["path": normalizedDestination]),
              let commitURL = Self.url(host: host, port: port, path: "/api/pocket/v1/commit") else {
            throw ClientError.invalidAddress
        }

        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let total = Int64(values.fileSize ?? 0)
        let boundary = "PocketBoundary-\(UUID().uuidString)"
        let multipart = try Self.makeMultipartBody(
            source: fileURL,
            uploadFilename: stagingName,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: multipart.url) }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.timeoutInterval = 900
        uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let uploader = HTTPUploadDelegate(progress: progress)
        let (uploadData, uploadResponse) = try await uploader.upload(request: uploadRequest, bodyFile: multipart.url)
        try Self.requireSuccess(uploadResponse, body: uploadData)

        let stagingPath = Self.join(normalizedDestination, stagingName)
        let targetPath = Self.join(normalizedDestination, filename)
        var commitRequest = URLRequest(url: commitURL)
        commitRequest.httpMethod = "POST"
        commitRequest.timeoutInterval = 30
        commitRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        commitRequest.httpBody = try JSONSerialization.data(withJSONObject: [
            "staging": stagingPath,
            "target": targetPath,
            "size": total,
            "crc32": String(format: "%08X", multipart.crc32),
        ])
        let (commitData, commitResponse) = try await session.data(for: commitRequest)
        try Self.requireSuccess(commitResponse, body: commitData)
        let committed = try JSONDecoder().decode(PocketCommitResponse.self, from: commitData)
        guard committed.size == total,
              committed.crc32.caseInsensitiveCompare(String(format: "%08X", multipart.crc32)) == .orderedSame else {
            throw ClientError.verificationFailed
        }
        return targetPath
    }

    private static func makeMultipartBody(
        source: URL,
        uploadFilename: String,
        boundary: String
    ) throws -> (url: URL, crc32: UInt32) {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-upload-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        let output = try FileHandle(forWritingTo: temp)
        defer { try? output.close() }
        let prefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(uploadFilename)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        try output.write(contentsOf: Data(prefix.utf8))

        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        var crc = CRC32()
        while let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty {
            crc.update(chunk)
            try output.write(contentsOf: chunk)
        }
        try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
        return (temp, crc.finalized)
    }

    private static func normalizedDirectory(_ path: String) -> String {
        var value = path.hasPrefix("/") ? path : "/" + path
        while value.count > 1, value.hasSuffix("/") { value.removeLast() }
        return value
    }

    private static func join(_ directory: String, _ filename: String) -> String {
        directory == "/" ? "/\(filename)" : "\(directory)/\(filename)"
    }

    private static func url(host: String, port: Int, path: String, query: [String: String] = [:]) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = path
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url
    }

    private static func requireSuccess(_ response: URLResponse, body: Data = Data()) throws {
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let detail = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ClientError.unexpectedMessage(detail?.isEmpty == false ? detail! : "HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
    }
}

struct CRC32 {
    private var value: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        for byte in data {
            value ^= UInt32(byte)
            for _ in 0 ..< 8 {
                value = (value >> 1) ^ (0xEDB8_8320 & (0 &- (value & 1)))
            }
        }
    }

    var finalized: UInt32 { value ^ 0xFFFF_FFFF }
}
