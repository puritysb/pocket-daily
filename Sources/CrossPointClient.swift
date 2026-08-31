import CryptoKit
import Foundation
import Network

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
    let uploadChunkBytes: Int?
    let uploadStreamPort: Int?
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

enum CrashReportArchive {
    static func store(report: String, device: String, directory: URL? = nil) throws -> URL {
        let data = Data(report.utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let safeDevice = device.lowercased().filter { $0.isLetter || $0.isNumber }
        let root = directory ?? defaultDirectory
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("\(safeDevice.isEmpty ? "pocket" : safeDevice)-\(digest.prefix(16)).txt")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Pocket", isDirectory: true)
            .appendingPathComponent("crash-reports", isDirectory: true)
    }
}

private struct PocketPreferencesResponse: Decodable {
    let startupApp: Int
    let pocketDailySleepCover: Int
    let sleepTimeoutMinutes: Int
    let fontSize: Int
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

private final class PocketStreamUploader: @unchecked Sendable {
    private enum StreamError: LocalizedError {
        case invalidPort
        case invalidPath
        case disconnected
        case invalidResponse(String)
        case verificationFailed

        var errorDescription: String? {
            switch self {
            case .invalidPort: "The reader's upload port is invalid."
            case .invalidPath: "The destination path cannot be sent."
            case .disconnected: "The reader disconnected before verifying the upload."
            case let .invalidResponse(message): "Unexpected reader response: \(message)"
            case .verificationFailed: "The reader reported a different file size or checksum."
            }
        }
    }

    private let connection: NWConnection
    private let input: FileHandle
    private let total: Int64
    private let remotePath: String
    private let progress: @Sendable (Int64, Int64) -> Void
    private let queue = DispatchQueue(label: "io.github.puritysb.pocketdaily.upload-stream")
    private var continuation: CheckedContinuation<UInt32, Error>?
    private var sent: Int64 = 0
    private var crc = CRC32()
    private var response = Data()

    init(
        fileURL: URL,
        host: String,
        port: Int,
        remotePath: String,
        total: Int64,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else {
            throw StreamError.invalidPort
        }
        guard remotePath.hasPrefix("/"), !remotePath.contains("\n"), !remotePath.contains("\r") else {
            throw StreamError.invalidPath
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tcp)
        input = try FileHandle(forReadingFrom: fileURL)
        self.total = total
        self.remotePath = remotePath
        self.progress = progress
    }

    deinit {
        try? input.close()
        connection.cancel()
    }

    func upload() async throws -> UInt32 {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.sendHeader()
                case let .failed(error):
                    self.finish(.failure(error))
                case .cancelled:
                    if self.continuation != nil { self.finish(.failure(StreamError.disconnected)) }
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 900) { [weak self] in
                guard let self, self.continuation != nil else { return }
                self.finish(.failure(URLError(.timedOut)))
            }
        }
    }

    private func sendHeader() {
        let header = Data("POCKET-PUT/1\nPath: \(remotePath)\nSize: \(total)\n\n".utf8)
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error { self.finish(.failure(error)) } else { self.sendNextChunk() }
        })
    }

    private func sendNextChunk() {
        do {
            guard let chunk = try input.read(upToCount: 16 * 1024), !chunk.isEmpty else {
                receiveReply()
                return
            }
            crc.update(chunk)
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if let error {
                    self.finish(.failure(error))
                    return
                }
                self.sent += Int64(chunk.count)
                self.progress(self.sent, self.total)
                self.sendNextChunk()
            })
        } catch {
            finish(.failure(error))
        }
    }

    private func receiveReply() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 160) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.response.append(data) }
            if let error {
                self.finish(.failure(error))
                return
            }
            if self.response.count > 256 {
                self.finish(.failure(StreamError.invalidResponse("response too large")))
                return
            }
            if let newline = self.response.firstIndex(of: 0x0A) {
                let line = String(decoding: self.response[..<newline], as: UTF8.self)
                self.verify(line: line)
            } else if isComplete {
                self.finish(.failure(StreamError.disconnected))
            } else {
                self.receiveReply()
            }
        }
    }

    private func verify(line: String) {
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 3, fields[0] == "OK",
              let readerSize = Int64(fields[1]),
              let readerCRC = UInt32(fields[2], radix: 16)
        else {
            finish(.failure(StreamError.invalidResponse(line)))
            return
        }
        guard sent == total, readerSize == total, readerCRC == crc.finalized else {
            finish(.failure(StreamError.verificationFailed))
            return
        }
        finish(.success(readerCRC))
    }

    private func finish(_ result: Result<UInt32, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        try? input.close()
        connection.cancel()
        continuation.resume(with: result)
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

    func status(
        host: String = "192.168.4.1",
        port: Int = 80,
        timeout: TimeInterval = 4
    ) async throws -> CrossPointStatus {
        guard let url = URL(string: "http://\(host):\(port)/api/status") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeout
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        return try JSONDecoder().decode(CrossPointStatus.self, from: data)
    }

    func crashDiagnostic(host: String, port: Int, expectedBytes: Int) async throws -> CrashDiagnostic {
        guard expectedBytes > 0, expectedBytes <= 65_536 else {
            throw ClientError.unexpectedMessage("invalid crash report size")
        }

        var reportData = Data()
        reportData.reserveCapacity(expectedBytes)
        while reportData.count < expectedBytes {
            guard let url = Self.url(
                host: host,
                port: port,
                path: "/api/pocket/v1/crash-report",
                query: ["offset": String(reportData.count)]
            ) else { throw ClientError.invalidAddress }
            var request = URLRequest(url: url)
            request.timeoutInterval = 4
            request.setValue("close", forHTTPHeaderField: "Connection")
            let (chunk, response) = try await session.data(for: request)
            try Self.requireSuccess(response, body: chunk)
            guard !chunk.isEmpty, reportData.count + chunk.count <= expectedBytes else {
                throw ClientError.unexpectedMessage("invalid crash report chunk")
            }
            reportData.append(chunk)
        }

        guard let report = String(data: reportData, encoding: .utf8), !report.isEmpty else {
            throw ClientError.unexpectedMessage("empty crash report")
        }
        return CrashDiagnostic(report: report)
    }

    func preferences(host: String, port: Int) async throws -> ReaderPreferences {
        guard let url = URL(string: "http://\(host):\(port)/api/pocket/v1/preferences") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let (data, response) = try await session.data(for: request)
        try Self.requireSuccess(response)
        let preferences = try JSONDecoder().decode(PocketPreferencesResponse.self, from: data)
        return ReaderPreferences(
            startupApp: preferences.startupApp,
            pocketDailySleepCover: preferences.pocketDailySleepCover != 0,
            sleepTimeoutMinutes: preferences.sleepTimeoutMinutes,
            fontSize: preferences.fontSize
        )
    }

    func save(preferences: ReaderPreferences, host: String, port: Int) async throws {
        guard let url = URL(string: "http://\(host):\(port)/api/pocket/v1/preferences") else {
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
        uploadChunkBytes: Int? = nil,
        uploadStreamPort: Int? = nil,
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
        let crc32: UInt32
        if let streamPort = uploadStreamPort, streamPort > 0 {
            let stagingPath = Self.join(normalizedDestination, stagingName)
            let uploader = try PocketStreamUploader(
                fileURL: fileURL,
                host: host,
                port: streamPort,
                remotePath: stagingPath,
                total: total,
                progress: progress
            )
            crc32 = try await uploader.upload()
        } else if let advertisedChunk = uploadChunkBytes, advertisedChunk > 0, total > 0 {
            let chunkSize = min(max(advertisedChunk, 1_024), 64 * 1_024)
            let input = try FileHandle(forReadingFrom: fileURL)
            defer { try? input.close() }
            var crc = CRC32()
            var offset: Int64 = 0
            while let chunk = try input.read(upToCount: chunkSize), !chunk.isEmpty {
                try Task.checkCancellation()
                crc.update(chunk)
                let boundary = "PocketBoundary-\(UUID().uuidString)"
                let multipart = try Self.makeMultipartBody(
                    data: chunk,
                    uploadFilename: stagingName,
                    boundary: boundary
                )
                defer { try? FileManager.default.removeItem(at: multipart) }
                guard let chunkURL = Self.url(
                    host: host,
                    port: port,
                    path: "/upload",
                    query: ["path": normalizedDestination, "offset": String(offset)]
                ) else { throw ClientError.invalidAddress }

                var uploadRequest = URLRequest(url: chunkURL)
                uploadRequest.httpMethod = "POST"
                uploadRequest.timeoutInterval = 60
                uploadRequest.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                let chunkStart = offset
                let chunkCount = Int64(chunk.count)
                let uploader = HTTPUploadDelegate { sent, expected in
                    let payloadSent = expected > 0 ? min(chunkCount, chunkCount * sent / expected) : 0
                    progress(chunkStart + payloadSent, total)
                }
                let (uploadData, uploadResponse) = try await uploader.upload(request: uploadRequest, bodyFile: multipart)
                try Self.requireSuccess(uploadResponse, body: uploadData)
                try? FileManager.default.removeItem(at: multipart)
                offset += chunkCount
                progress(offset, total)
            }
            guard offset == total else { throw ClientError.verificationFailed }
            crc32 = crc.finalized
        } else {
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
            crc32 = multipart.crc32
        }

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
            "crc32": String(format: "%08X", crc32),
        ])
        let (commitData, commitResponse) = try await session.data(for: commitRequest)
        try Self.requireSuccess(commitResponse, body: commitData)
        let committed = try JSONDecoder().decode(PocketCommitResponse.self, from: commitData)
        guard committed.size == total,
              committed.crc32.caseInsensitiveCompare(String(format: "%08X", crc32)) == .orderedSame else {
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

    private static func makeMultipartBody(data: Data, uploadFilename: String, boundary: String) throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pocket-upload-\(UUID().uuidString)")
        let prefix = "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(uploadFilename)\"\r\nContent-Type: application/octet-stream\r\n\r\n"
        var body = Data(prefix.utf8)
        body.append(data)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        try body.write(to: temp, options: .atomic)
        return temp
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
