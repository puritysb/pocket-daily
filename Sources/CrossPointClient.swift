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
    let screenPreviewAvailable: Bool?
    let screenPreviewBytes: Int?
    let uploadChunkBytes: Int?
    let uploadStreamPort: Int?
    let uploadStreamResume: Bool?
    let diagnosticsAffordable: Bool?
    var deviceID: String? = nil
    var sessionEnd: Bool? = nil
    var contentPresentation: Bool? = nil
    /// Live-studio capability advertisement. Absent on readers that predate
    /// the contract (`docs/live-studio-v1.md` in the firmware repository).
    var liveStudio: LiveStudioAdvertisement? = nil
    var uploadStreamWindow: Int? = nil
    /// Pocket Daily profile endpoints (sibling docs/pocket-profile-v1.md).
    var pocketProfile: Int? = nil
    /// Read-only published content files (sibling docs/content-read-v1.md).
    var contentRead: Int? = nil
    /// Weather and events from the app (sibling docs/pocket-glance-v1.md).
    var pocketGlance: Int? = nil
    /// Draws the saved Home or Daily Brief inside Sync
    /// (sibling docs/pocket-screen-present-v1.md).
    var screenPresentation: Int? = nil
    var transferControl: Int?
    var articleLibrary: Int? = nil
    var totalHeap: Int? = nil
    var readerFiles: Int? = nil
    /// Reading positions exchanged without a server (docs/READING_PROGRESS.md,
    /// sibling docs/reading-progress-v1.md).
    var readingProgress: Int? = nil
}

/// What the reader advertises about its live-studio listener. `mode` is
/// `"push"` when the WebSocket listener is running (then `wsPort` is set)
/// and `"poll"` when only HTTP polling is available.
struct LiveStudioAdvertisement: Codable, Equatable {
    let wsPort: Int?
    let mode: String
    let frameStream: Bool?
    let uiPacks: Bool?
    let activePack: String?
    let activePackVersion: String?
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
    /// The reader's "never" value (CrossPointSettings::SLEEP_TIMEOUT_NEVER_MINUTES).
    static let neverSleepMinutes = 31
    /// What the side buttons do in a book (CrossPointSettings::SIDE_BUTTON_LAYOUT).
    enum SideButtons: Int, CaseIterable, Sendable {
        case previousNext = 0, nextPrevious = 1, off = 2
        var title: String {
            switch self {
            case .previousNext: "Up turns back"
            case .nextPrevious: "Up turns forward"
            case .off: "Off"
            }
        }
    }

    var startupApp = 1
    var pocketDailySleepCover = true
    var sleepTimeoutMinutes = 10
    var fontSize = 1
    /// Nil when the reader does not report it (firmware before 2026-09-26);
    /// the app then neither offers nor sends it.
    var sideButtons: SideButtons? = nil
    var frontButtonsFollowOrientation: Bool? = nil

    var hasButtonSettings: Bool { sideButtons != nil && frontButtonsFollowOrientation != nil }

    /// `GET /api/pocket/v1/preferences`. The button keys are optional; a value
    /// outside the known range hides that control rather than being sent back.
    static func decode(_ data: Data) throws -> ReaderPreferences {
        struct Wire: Decodable {
            let startupApp: Int
            let pocketDailySleepCover: Int
            let sleepTimeoutMinutes: Int
            let fontSize: Int
            let sideButtonLayout: Int?
            let frontButtonFollowOrientation: Int?
        }
        let wire = try JSONDecoder().decode(Wire.self, from: data)
        var preferences = ReaderPreferences(
            startupApp: wire.startupApp,
            pocketDailySleepCover: wire.pocketDailySleepCover != 0,
            sleepTimeoutMinutes: wire.sleepTimeoutMinutes,
            fontSize: wire.fontSize
        )
        preferences.sideButtons = wire.sideButtonLayout.flatMap(SideButtons.init(rawValue:))
        preferences.frontButtonsFollowOrientation = wire.frontButtonFollowOrientation.flatMap {
            $0 == 0 || $0 == 1 ? $0 == 1 : nil
        }
        return preferences
    }

    /// `POST /api/pocket/v1/preferences`; button keys only when the reader reported them.
    func requestBody() throws -> Data {
        var body: [String: Int] = [
            "startupApp": startupApp,
            "pocketDailySleepCover": pocketDailySleepCover ? 1 : 0,
            "sleepTimeoutMinutes": sleepTimeoutMinutes,
            "fontSize": fontSize,
        ]
        if let sideButtons { body["sideButtonLayout"] = sideButtons.rawValue }
        if let frontButtonsFollowOrientation { body["frontButtonFollowOrientation"] = frontButtonsFollowOrientation ? 1 : 0 }
        return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }
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

    private let cancellationLock = NSLock()
    private var uploadTask: URLSessionUploadTask?
    private var cancelled = false

    func upload(request: URLRequest, bodyFile: URL) async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.waitsForConnectivity = true
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 900
                let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.uploadTask(with: request, fromFile: bodyFile)
                cancellationLock.withLock {
                    uploadTask = task
                    if cancelled { task.cancel() }
                }
                task.resume()
            }
        } onCancel: {
            self.cancellationLock.withLock {
                self.cancelled = true
                self.uploadTask?.cancel()
            }
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
        cancellationLock.withLock { uploadTask = nil }
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

/// One `POCKET-PUT/1` transfer over the reader's persistent upload socket.
///
/// The reader may answer at any moment (`ERROR …` when its SD write fails,
/// `RESUME <n>` when asked to continue a retained staging file), so replies
/// are read concurrently with sending instead of only after the last byte.
/// A stall watchdog matches the reader's own 30-second idle timeout so a
/// dropped hotspot surfaces as a retryable failure instead of a 15-minute wait.
final class PocketStreamUploader: @unchecked Sendable {
    enum StreamError: LocalizedError, Equatable {
        case invalidPort
        case invalidPath
        case disconnected
        case stalled
        case timedOut
        case readerRejected(String)
        case invalidResponse(String)
        case verificationFailed

        /// Transport-class failures where retrying with `Resume: 1` is safe.
        var isTransient: Bool {
            switch self {
            case .disconnected, .stalled: true
            // These exact protocol replies mean the reader retained a prefix.
            // SD/validation rejections must remain terminal.
            case .readerRejected("Upload timed out"), .readerRejected("Upload disconnected"): true
            default: false
            }
        }

        var errorDescription: String? {
            switch self {
            case .invalidPort: "The reader's upload port is invalid."
            case .invalidPath: "The destination path cannot be sent."
            case .disconnected: "The reader disconnected before verifying the upload."
            case .stalled: "The reader stopped accepting data."
            case .timedOut: "The transfer took too long and was cancelled."
            case let .readerRejected(message): "The reader stopped the transfer: \(message)."
            case let .invalidResponse(message): "Unexpected reader response: \(message)"
            case .verificationFailed: "The reader reported a different file size or checksum."
            }
        }
    }

    enum Reply: Equatable {
        case ok(size: Int64, crc32: UInt32)
        case resume(offset: Int64)
        case ack(offset: Int64)
        case error(String)
        case invalid(String)

        static func parse(_ line: String) -> Reply {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard let verb = fields.first else { return .invalid(trimmed) }
            switch verb {
            case "OK":
                guard fields.count == 3, let size = Int64(fields[1]), let crc = UInt32(fields[2], radix: 16) else {
                    return .invalid(trimmed)
                }
                return .ok(size: size, crc32: crc)
            case "RESUME":
                guard fields.count == 2, let offset = Int64(fields[1]) else { return .invalid(trimmed) }
                return .resume(offset: offset)
            case "ERROR":
                return .error(fields.dropFirst().joined(separator: " "))
            case "ACK":
                guard fields.count == 2, let offset = Int64(fields[1]), offset > 0 else { return .invalid(trimmed) }
                return .ack(offset: offset)
            default:
                return .invalid(trimmed)
            }
        }
    }

    static let chunkBytes = 16 * 1024
    static let stallTimeout: Duration = .seconds(30)
    static let overallTimeout: TimeInterval = 900

    static func header(path: String, size: Int64, resume: Bool, flowControl: Bool = false) -> Data {
        var text = "POCKET-PUT/1\nPath: \(path)\nSize: \(size)\n"
        if resume || flowControl { text += "Resume: 1\n" }
        if flowControl { text += "Window: 4096\n" }
        text += "\n"
        return Data(text.utf8)
    }

    private let connection: NWConnection
    private let input: FileHandle
    private let total: Int64
    private let remotePath: String
    private let resume: Bool
    private let flowControl: Bool
    private let progress: @Sendable (Int64, Int64) -> Void
    private let queue = DispatchQueue(label: "bound.serendipity.pocket.daily.upload-stream")
    private var continuation: CheckedContinuation<UInt32, Error>?
    private var sent: Int64 = 0
    private var bytesRead: Int64 = 0
    private var streaming = false
    private var crc = CRC32()
    private var response = Data()
    private var lastActivity = ContinuousClock.now
    private var stallTimer: DispatchSourceTimer?

    init(
        fileURL: URL,
        host: String,
        port: Int,
        remotePath: String,
        total: Int64,
        resume: Bool = false,
        flowControl: Bool = false,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) throws {
        guard let endpointPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else {
            throw StreamError.invalidPort
        }
        guard remotePath.hasPrefix("/"), !remotePath.contains("\n"), !remotePath.contains("\r") else {
            throw StreamError.invalidPath
        }
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort,
                                  using: NWParameters(tls: nil, tcp: tcp))
        input = try FileHandle(forReadingFrom: fileURL)
        self.total = total
        self.remotePath = remotePath
        self.resume = resume || flowControl
        self.flowControl = flowControl
        self.progress = progress
    }

    deinit {
        stallTimer?.cancel()
        try? input.close()
        connection.cancel()
    }

    private var cancelled = false // accessed only on queue

    func upload() async throws -> UInt32 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    guard !cancelled else { continuation.resume(throwing: CancellationError()); return }
                    self.continuation = continuation
                    connection.stateUpdateHandler = { [weak self] state in
                        guard let self else { return }
                        switch state {
                        case .ready:
                            self.touch()
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
                    startStallTimer()
                    queue.asyncAfter(deadline: .now() + Self.overallTimeout) { [weak self] in
                        guard let self, self.continuation != nil else { return }
                        self.finish(.failure(StreamError.timedOut))
                    }
                }
            }
        } onCancel: {
            self.queue.async {
                self.cancelled = true
                self.finish(.failure(CancellationError()))
            }
        }
    }

    private func touch() {
        lastActivity = ContinuousClock.now
    }

    private func startStallTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self, self.continuation != nil else { return }
            if ContinuousClock.now - self.lastActivity > Self.stallTimeout {
                self.finish(.failure(StreamError.stalled))
            }
        }
        timer.resume()
        stallTimer = timer
    }

    private func sendHeader() {
        let header = Self.header(path: remotePath, size: total, resume: resume, flowControl: flowControl)
        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            self.receiveNextLine()
            // A resume request must wait for the reader to say where its
            // retained prefix ends; a fresh upload streams immediately.
            if !self.resume { self.startStreaming(from: 0) }
        })
    }

    private func startStreaming(from offset: Int64) {
        guard !streaming else {
            finish(.failure(StreamError.invalidResponse("duplicate resume offset")))
            return
        }
        guard offset >= 0, offset <= total else {
            finish(.failure(StreamError.invalidResponse("resume offset \(offset) exceeds \(total) bytes")))
            return
        }
        streaming = true
        do {
            // The reader continues its running CRC across the prefix it kept;
            // rebuild the same prefix locally so both sides verify the whole file.
            try input.seek(toOffset: 0)
            var remaining = offset
            while remaining > 0 {
                guard let chunk = try input.read(upToCount: Int(min(remaining, 64 * 1024))), !chunk.isEmpty else {
                    throw StreamError.invalidResponse("the local file is shorter than the reader's retained prefix")
                }
                crc.update(chunk)
                remaining -= Int64(chunk.count)
            }
        } catch {
            finish(.failure(error))
            return
        }
        sent = offset
        bytesRead = offset
        touch()
        progress(sent, total)
        sendNextChunk()
    }

    private func sendNextChunk() {
        guard continuation != nil else { return }
        do {
            guard let chunk = try input.read(upToCount: flowControl ? 4096 : Self.chunkBytes), !chunk.isEmpty else {
                if bytesRead != total { finish(.failure(StreamError.verificationFailed)) }
                return  // The receive loop delivers the reader's OK line.
            }
            crc.update(chunk)
            bytesRead += Int64(chunk.count)
            if flowControl {
                sendFlowFragment(chunk, offset: 0)
                return
            }
            connection.send(content: chunk, completion: .contentProcessed { [weak self] error in
                guard let self, self.continuation != nil else { return }
                if let error {
                    self.finish(.failure(error))
                    return
                }
                self.sent += Int64(chunk.count)
                self.touch()
                self.progress(self.sent, self.total)
                self.sendNextChunk()
            })
        } catch {
            finish(.failure(error))
        }
    }

    private func sendFlowFragment(_ chunk: Data, offset: Int) {
        guard continuation != nil, offset < chunk.count else { return }
        // The reader still grants one 4 KiB SD window. Avoid putting that
        // entire window into its scarce Wi-Fi RX heap in one burst.
        let end = min(offset + 512, chunk.count)
        connection.send(content: chunk.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, self.continuation != nil else { return }
            if let error {
                self.finish(.failure(error))
                return
            }
            guard end < chunk.count else { return } // Only SD ACK grants the next window.
            self.queue.asyncAfter(deadline: .now() + .milliseconds(10)) { [weak self] in
                self?.sendFlowFragment(chunk, offset: end)
            }
        })
    }

    private func receiveNextLine() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, isComplete, error in
            guard let self, self.continuation != nil else { return }
            if let data, !data.isEmpty {
                self.response.append(data)
                self.touch()
            }
            if let error {
                self.finish(.failure(error))
                return
            }
            if self.response.count > 256 {
                self.finish(.failure(StreamError.invalidResponse("response too large")))
                return
            }
            while let newline = self.response.firstIndex(of: 0x0A) {
                let line = String(decoding: self.response[self.response.startIndex ..< newline], as: UTF8.self)
                self.response.removeSubrange(self.response.startIndex ... newline)
                self.handle(Reply.parse(line), raw: line)
                if self.continuation == nil { return }
            }
            if isComplete {
                self.finish(.failure(StreamError.disconnected))
                return
            }
            self.receiveNextLine()
        }
    }

    private func handle(_ reply: Reply, raw: String) {
        switch reply {
        case let .resume(offset):
            guard resume, !streaming else {
                finish(.failure(StreamError.invalidResponse(raw)))
                return
            }
            startStreaming(from: offset)
        case let .ok(size, readerCRC):
            guard bytesRead == total, size == total, readerCRC == crc.finalized else {
                finish(.failure(StreamError.verificationFailed))
                return
            }
            progress(total, total)
            finish(.success(readerCRC))
        case let .ack(offset):
            guard flowControl, streaming, offset == bytesRead, offset > sent, offset < total else {
                finish(.failure(StreamError.invalidResponse(raw)))
                return
            }
            sent = offset
            progress(sent, total)
            sendNextChunk()
        case let .error(message):
            finish(.failure(StreamError.readerRejected(message.isEmpty ? "unspecified error" : message)))
        case let .invalid(line):
            finish(.failure(StreamError.invalidResponse(line)))
        }
    }

    private func finish(_ result: Result<UInt32, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        stallTimer?.cancel()
        stallTimer = nil
        try? input.close()
        connection.cancel()
        continuation.resume(with: result)
    }
}

/// Decides whether an interrupted transfer is worth another attempt. Reader
/// rejections (bad header, SD failure, checksum mismatch) are final; link-level
/// failures are retried with `Resume: 1` when the reader advertises support.
enum UploadRetryPolicy {
    static let maxAttempts = 3

    static func shouldRetry(_ error: Error, attempt: Int, maxAttempts: Int = maxAttempts) -> Bool {
        guard attempt < maxAttempts else { return false }
        if error is CancellationError { return false }
        if let stream = error as? PocketStreamUploader.StreamError { return stream.isTransient }
        if let urlError = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cannotConnectToHost, .notConnectedToInternet, .cannotFindHost]
                .contains(urlError.code)
        }
        if error is NWError { return true }
        return (error as NSError).domain == NSPOSIXErrorDomain
    }

    static func delay(afterAttempt attempt: Int) -> Duration {
        .seconds(min(max(attempt, 1), 3))
    }
}

/// One HTTP request per reader host. Actor isolation alone does not provide
/// this: awaiting URLSession lets another caller enter the actor. Different
/// hosts remain independent so LAN discovery retains its bounded parallelism.
private actor ReaderHTTPTransport {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var active: Set<String> = []
    private var waiting: [String: [Waiter]] = [:]

    func data(for request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        guard let host = request.url?.host?.lowercased() else { throw URLError(.badURL) }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await acquire(host: host, id: id)
            defer { release(host: host) }
            try Task.checkCancellation()
            return try await session.data(for: request)
        } onCancel: {
            Task { await self.cancelWaiting(host: host, id: id) }
        }
    }

    private func acquire(host: String, id: UUID) async throws {
        try Task.checkCancellation()
        if active.insert(host).inserted { return }
        try await withCheckedThrowingContinuation { continuation in
            waiting[host, default: []].append(Waiter(id: id, continuation: continuation))
        }
    }

    private func release(host: String) {
        guard var queue = waiting[host], !queue.isEmpty else {
            active.remove(host)
            return
        }
        let next = queue.removeFirst()
        waiting[host] = queue.isEmpty ? nil : queue
        next.continuation.resume()
    }

    private func cancelWaiting(host: String, id: UUID) {
        guard var queue = waiting[host], let index = queue.firstIndex(where: { $0.id == id }) else { return }
        let cancelled = queue.remove(at: index)
        waiting[host] = queue.isEmpty ? nil : queue
        cancelled.continuation.resume(throwing: CancellationError())
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
    private let http = ReaderHTTPTransport()

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Preparation after manifest/asset staging may copy existing reader assets.
    /// Uses the per-reader HTTP queue; never retries a busy/storage failure.
    func inspectPreparedContent(
        _ revision: ContentRevision, deviceID: String, host: String, port: Int
    ) async throws -> ContentPreparation {
        let body = try await contentResponse(action: "prepare", method: "POST", revision: revision.revision,
                                             deviceID: deviceID, host: host, port: port)
        return try ContentPreparationReceipt.decode(body, target: revision, deviceID: deviceID)
    }

    func contentState(deviceID: String, host: String, port: Int) async throws -> ContentDeviceState {
        let body = try await contentResponse(action: "state", method: "GET", revision: nil,
                                             deviceID: deviceID, host: host, port: port)
        return try ContentStateReceipt.decode(body, deviceID: deviceID)
    }

    func presentContent(_ active: ContentActiveReceipt, deviceID: String, host: String, port: Int) async throws -> ContentPresentationReceipt {
        let body = try await contentResponse(action: "present", method: "POST", revision: active.revision,
                                             deviceID: deviceID, host: host, port: port)
        return try ContentPresentationReceipt.decode(body, deviceID: deviceID, active: active)
    }

    func contentPresentation(_ active: ContentActiveReceipt, deviceID: String, host: String, port: Int) async throws -> ContentPresentationReceipt {
        let body = try await contentResponse(action: "presentation", method: "GET", revision: active.revision,
                                             deviceID: deviceID, host: host, port: port)
        return try ContentPresentationReceipt.decode(body, deviceID: deviceID, active: active)
    }

    /// Asks the reader to draw a saved screen for `generation` of its profile.
    func presentScreen(_ screen: ReaderScreen, generation: UInt32, deviceID: String, host: String,
                       port: Int) async throws -> ScreenPresentationReceipt {
        try await screenResponse(path: "present", method: "POST", screen: screen, generation: generation,
                                 deviceID: deviceID, host: host, port: port)
    }

    /// Read-only receipt for a screen presentation request.
    func screenPresentation(_ screen: ReaderScreen, generation: UInt32, deviceID: String, host: String,
                            port: Int) async throws -> ScreenPresentationReceipt {
        try await screenResponse(path: "presentation", method: "GET", screen: screen, generation: generation,
                                 deviceID: deviceID, host: host, port: port)
    }

    private func screenResponse(path: String, method: String, screen: ReaderScreen, generation: UInt32,
                                deviceID: String, host: String, port: Int) async throws -> ScreenPresentationReceipt {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/screen/" + path,
                                 query: ["deviceID": deviceID, "surface": screen.rawValue,
                                         "generation": String(generation)]) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (body, response) = try await http.data(for: request, session: session)
        try Task.checkCancellation()
        try Self.requireSuccess(response, body: body)
        return try ScreenPresentationReceipt.decode(body, deviceID: deviceID, screen: screen, generation: generation)
    }

    /// One chunk of one file of a published content revision. The caller
    /// verifies every byte (ReaderContentPull); this is transport only.
    func contentFileChunk(revision: String, name: String, offset: Int, deviceID: String, host: String,
                          port: Int) async throws -> Data {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/content/file",
                                 query: ["deviceID": deviceID, "revision": revision, "name": name,
                                         "offset": String(offset)]) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (body, response) = try await http.data(for: request, session: session)
        try Task.checkCancellation()
        try Self.requireSuccess(response, body: body)
        return body
    }

    /// Stores the weather and events the reader shows; the reader validates
    /// the whole document (sibling docs/pocket-glance-v1.md).
    func saveGlance(_ glance: ReaderGlance, deviceID: String, host: String, port: Int) async throws {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/glance", query: ["deviceID": deviceID]) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = try glance.requestBody()
        let (body, response) = try await http.data(for: request, session: session)
        try Task.checkCancellation()
        try Self.requireSuccess(response, body: body)
    }

    enum ProfileRequestError: LocalizedError, Equatable {
        case conflict
        case rejected(String)
        var errorDescription: String? {
            switch self {
            case .conflict: "The reader's profile changed since it was loaded. The latest version was reloaded; review it and send again."
            case let .rejected(reason): "The reader rejected the profile: \(reason)"
            }
        }
    }

    func readerProfile(deviceID: String, host: String, port: Int) async throws -> ReaderProfileState {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/profile", query: ["deviceID": deviceID]) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (body, response) = try await http.data(for: request, session: session)
        try Task.checkCancellation()
        try Self.requireSuccess(response, body: body)
        return try ReaderProfileState.decode(body, deviceID: deviceID)
    }

    /// Compare-and-swap on the generation the app loaded; the reader validates
    /// the whole document before storing it (no partial application).
    func saveReaderProfile(_ profile: PocketProfile, generation: UInt32, deviceID: String, host: String,
                           port: Int) async throws -> ReaderProfileState {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/profile",
                                 query: ["deviceID": deviceID, "generation": String(generation)]) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = try profile.requestBody()
        let (body, response) = try await http.data(for: request, session: session)
        try Task.checkCancellation()
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        if status == 409, String(data: body, encoding: .utf8)?.contains("profile changed") == true {
            throw ProfileRequestError.conflict
        }
        if status == 400 {
            throw ProfileRequestError.rejected(String(data: body.prefix(160), encoding: .utf8) ?? "invalid profile")
        }
        try Self.requireSuccess(response, body: body)
        return try ReaderProfileState.decode(body, deviceID: deviceID)
    }

    /// Resolved preview inputs. nil when the reader predates the endpoint (404).
    func readerDisplay(deviceID: String, host: String, port: Int) async throws -> ReaderDisplayState? {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/display", query: ["deviceID": deviceID]) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (body, response) = try await http.data(for: request, session: session)
        try Task.checkCancellation()
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        try Self.requireSuccess(response, body: body)
        return try ReaderDisplayState.decode(body, deviceID: deviceID)
    }

    /// This request can commit even when its response is lost. The deployment
    /// coordinator must read contentState afterward and must not blindly retry.
    func activateContent(_ revision: ContentRevision, deviceID: String, host: String, port: Int) async throws {
        let body = try await contentResponse(action: "activate", method: "POST", revision: revision.revision,
                                             deviceID: deviceID, host: host, port: port)
        let state = try ContentStateReceipt.decode(body, deviceID: deviceID)
        guard state.active?.revision == revision.revision else { throw ClientError.verificationFailed }
    }

    private func contentResponse(action: String, method: String, revision: String?, deviceID: String,
                                 host: String, port: Int) async throws -> Data {
        guard deviceID.utf8.count == 8,
              deviceID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) }) else {
            throw ClientError.verificationFailed
        }
        var query = ["deviceID": deviceID]
        if let revision { query["revision"] = revision }
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/content/" + action,
                                 query: query) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        let (body, response) = try await http.data(for: request, session: session)
        try Task.checkCancellation()
        try Self.requireSuccess(response, body: body)
        guard body.count <= 512 else { throw ClientError.verificationFailed }
        return body
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
        let (data, response) = try await http.data(for: request, session: session)
        try Self.requireSuccess(response)
        return try JSONDecoder().decode(CrossPointStatus.self, from: data)
    }

    func endDirectSession(host: String, port: Int) async throws {
        guard let url = URL(string: "http://\(host):\(port)/api/pocket/v1/session/end") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        let (data, response) = try await http.data(for: request, session: session)
        try Self.requireSuccess(response, body: data)
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
            let (chunk, response) = try await http.data(for: request, session: session)
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
        let (data, response) = try await http.data(for: request, session: session)
        try Self.requireSuccess(response)
        return try ReaderPreferences.decode(data)
    }

    func save(preferences: ReaderPreferences, host: String, port: Int) async throws {
        guard let url = URL(string: "http://\(host):\(port)/api/pocket/v1/preferences") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try preferences.requestBody()
        let (_, response) = try await http.data(for: request, session: session)
        try Self.requireSuccess(response)
    }

    func readingProgress(identity: String, host: String, port: Int) async throws -> ReaderReadingList {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/reading", query: ["deviceID": identity]) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await http.data(for: request, session: session)
        try Self.requireSuccess(response, body: data)
        return try ReaderReadingList.decode(data, deviceID: identity)
    }

    /// Offers a position to the reader; it asks before moving when the book opens.
    func offerReadingProgress(_ record: PositionRecord, identity: String, host: String, port: Int) async throws {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/reading") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "deviceID": identity, "document": record.document, "progress": record.progress,
            "percentage": record.percentage, "device": record.device,
        ])
        let (data, response) = try await http.data(for: request, session: session)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return }
        try Self.requireSuccess(response, body: data)
    }

    func readerStorageRequest(endpoint: String, identity: String, host: String, port: Int,
                              query: [String: String], delete: Bool = false) async throws -> Data {
        var query = query
        query["deviceID"] = identity
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/" + endpoint, query: query) else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = delete ? "DELETE" : "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (body, response) = try await http.data(for: request, session: session)
        try Task.checkCancellation()
        try Self.requireSuccess(response, body: body)
        guard body.count <= 8192 else { throw ClientError.unexpectedMessage("Reader response is too large.") }
        return body
    }

    /// Only hidden UUID staging files can be discarded. Published content/update.bin is never a target.
    func controlTransfer(action: String, transferID: UUID, destination: String,
                         kind: TransferKind, host: String, port: Int) async throws {
        guard let url = Self.url(host: host, port: port, path: "/api/pocket/v1/transfer") else {
            throw ClientError.invalidAddress
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "action": action, "kind": kind.rawValue,
            "staging": Self.join(Self.normalizedDirectory(destination), ".pocket-\(transferID.uuidString.lowercased()).part")
        ])
        let (data, response) = try await http.data(for: request, session: session)
        try Self.requireSuccess(response, body: data)
        struct Receipt: Decodable { let ok: Bool }
        guard data.count <= 512, try JSONDecoder().decode(Receipt.self, from: data).ok else {
            throw ClientError.verificationFailed
        }
    }

    func uploadAtomically(
        fileURL: URL,
        publishedFilename: String? = nil,
        destination: String = "/",
        host: String = "192.168.4.1",
        port: Int = 80,
        uploadChunkBytes: Int? = nil,
        uploadStreamPort: Int? = nil,
        uploadStreamResume: Bool = false,
        uploadStreamWindow: Int? = nil,
        expectedDeviceID: String? = nil,
        transferID: UUID = UUID(),
        transferControl: Bool = false,
        transferKind: TransferKind = .content,
        note: (@Sendable (String) -> Void)? = nil,
        reconnect: (@Sendable () async -> Bool)? = nil,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> String {
        let filename = publishedFilename ?? fileURL.lastPathComponent
        guard !filename.isEmpty, !filename.contains(":"), !filename.contains("\n") else {
            throw ClientError.invalidFilename
        }

        let normalizedDestination = Self.normalizedDirectory(destination)
        let stagingName = ".pocket-\(transferID.uuidString.lowercased()).part"
        guard let uploadURL = Self.url(host: host, port: port, path: "/upload", query: ["path": normalizedDestination]),
              let commitURL = Self.url(host: host, port: port, path: "/api/pocket/v1/commit") else {
            throw ClientError.invalidAddress
        }

        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }

        let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
        let total = Int64(values.fileSize ?? 0)
        if transferControl {
            try await controlTransfer(action: "prepare", transferID: transferID,
                destination: normalizedDestination, kind: transferKind, host: host, port: port)
        }
        let crc32: UInt32
        if let streamPort = uploadStreamPort, streamPort > 0 {
            // The staging name stays fixed across attempts so a reader that
            // retained the interrupted prefix can continue it (`Resume: 1`).
            // Readers without resume support simply restart the same path.
            let stagingPath = Self.join(normalizedDestination, stagingName)
            var attempt = 0
            var resume = uploadStreamResume
            while true {
                attempt += 1
                do {
                    let uploader = try PocketStreamUploader(
                        fileURL: fileURL,
                        host: host,
                        port: streamPort,
                        remotePath: stagingPath,
                        total: total,
                        resume: resume,
                        flowControl: uploadStreamWindow == 4096,
                        progress: progress
                    )
                    crc32 = try await uploader.upload()
                    break
                } catch {
                    try Task.checkCancellation()
                    guard UploadRetryPolicy.shouldRetry(error, attempt: attempt) else { throw error }
                    note?("Transfer interrupted: \(error.localizedDescription) Reconnecting (attempt \(attempt + 1) of \(UploadRetryPolicy.maxAttempts))…")
                    try await Task.sleep(for: UploadRetryPolicy.delay(afterAttempt: attempt))
                    try await waitForReader(host: host, port: port, expectedDeviceID: expectedDeviceID,
                                            reconnect: reconnect)
                    // A reader restart loses its display metadata even though the queue survives.
                    if transferControl {
                        try await controlTransfer(action: "prepare", transferID: transferID,
                            destination: normalizedDestination, kind: transferKind, host: host, port: port)
                    }
                    resume = uploadStreamResume
                }
            }
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

        try Task.checkCancellation()
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
        let (commitData, commitResponse) = try await http.data(for: commitRequest, session: session)
        try Self.requireSuccess(commitResponse, body: commitData)
        let committed = try JSONDecoder().decode(PocketCommitResponse.self, from: commitData)
        guard committed.size == total,
              committed.crc32.caseInsensitiveCompare(String(format: "%08X", crc32)) == .orderedSame else {
            throw ClientError.verificationFailed
        }
        return targetPath
    }

    /// Recovery is bounded and probe-gated on LAN as well as a private AP.
    /// Never open another bulk socket while the reader is still unreachable.
    func waitForReader(
        host: String, port: Int, expectedDeviceID: String?,
        reconnect: (@Sendable () async -> Bool)? = nil,
        recoveryBudget: Duration = .seconds(45), probeSpacing: Duration = .seconds(3)
    ) async throws {
        let deadline = ContinuousClock.now + recoveryBudget
        var attemptedRejoin = false
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let recovered: CrossPointStatus?
            do { recovered = try await status(host: host, port: port, timeout: 3) }
            catch {
                try Task.checkCancellation()
                // Invalid HTTP/JSON responses are not evidence of a lost link.
                guard UploadRetryPolicy.shouldRetry(error, attempt: 1) else { throw error }
                recovered = nil
            }
            if let recovered {
                guard PocketHardware(deviceName: recovered.device) != nil,
                      expectedDeviceID == nil || recovered.deviceID == expectedDeviceID else {
                    throw ClientError.unexpectedMessage("The reader changed during recovery. Reconnect before sending files.")
                }
                return
            }
            if !attemptedRejoin, let reconnect {
                attemptedRejoin = true
                _ = await reconnect()
            }
            try await Task.sleep(for: probeSpacing)
        }
        throw PocketStreamUploader.StreamError.stalled
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
