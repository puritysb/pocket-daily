import Combine
import Foundation
import XCTest

@testable import Pocket

/// Opt-in only: this test talks to a physical reader and can reboot it into a
/// developer standby trial. Normal unit/simulator runs skip it without I/O.
final class ReaderHardwareTests: XCTestCase {
    @MainActor
    func testDeveloperConnectionCycle() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["POCKET_HARDWARE_ENABLED"] == "1" else {
            throw XCTSkip("Run the firmware repository's scripts/dev_pipeline.py to opt in.")
        }
#if targetEnvironment(simulator)
        throw Failure.reason("Physical reader tests cannot run on a simulator.")
#elseif !DEBUG
        throw Failure.reason("Hardware harness requires a Debug app.")
#else
        var evidence: [String: Any] = ["passed": false, "run": env["POCKET_HARDWARE_RUN"] ?? ""]
#if os(macOS)
        evidence["platform"] = "macOS"
#else
        evidence["platform"] = "iOS-device"
#endif
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.sortedKeys]),
               let json = String(data: data, encoding: .utf8) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "reader-hardware-evidence"
                attachment.lifetime = .keepAlways
                add(attachment)
                print("POCKET_HARDWARE_RESULT " + json)
            }
        }
        do {
            let host = try required("POCKET_HARDWARE_HOST", env)
            let identity = try required("POCKET_HARDWARE_DEVICE_ID", env)
            let version = try required("POCKET_HARDWARE_VERSION", env)
            let runText = try required("POCKET_HARDWARE_RUN", env)
            guard let run = UInt32(runText), run != 0 else { throw Failure.reason("Invalid cycle ID") }
            let standby = env["POCKET_HARDWARE_STANDBY"] == "1"
            let client = CrossPointClient()
            let preflight = try await client.status(host: host)
            try verify(preflight, identity: identity, version: version)
            evidence["version"] = version
            try await until("app startup", timeout: 20) { ReaderDevelopmentContext.model != nil }
            let model = try XCTUnwrap(ReaderDevelopmentContext.model)
            try require(!model.isDemoMode, "Exit demo mode before hardware testing.")
            var busy = true
            let ownership = model.readerWorkActive.sink { busy = $0 }
            defer { ownership.cancel() }
            try await until("reader work drain", timeout: 45) { !busy && !model.isWorking && !model.bookTransferJobsLoading }
            model.startConnectionSearch()
            try require(model.readerStatus == nil, "Connect did not start a fresh attempt")
            try await until("actual app LAN connection", timeout: 100) {
                model.readerStatus?.deviceID == identity && !busy && !model.isWorking
            }
            try verify(try XCTUnwrap(model.readerStatus), identity: identity, version: version)
            try await inventory(model, idle: { !busy })
            evidence["initialConnection"] = true

            if standby {
                try require(ReaderBluetoothLink.shared.rememberedReader?.readerID == identity,
                            "Pair this Debug app with the reader before the standby trial.")
                var request = URLRequest(url: try XCTUnwrap(URL(string:
                    "http://\(host)/api/pocket/v1/dev/ble-cycle?run=\(run)&sleep=standby")))
                request.httpMethod = "POST"
                request.httpBody = Data()
                request.timeoutInterval = 8
                // Exactly one mutation. A lost reply is observed, never replayed.
                do {
                    let (_, response) = try await URLSession.shared.data(for: request)
                    try require((response as? HTTPURLResponse)?.statusCode == 202, "Standby trial rejected")
                } catch let failure as Failure { throw failure }
                catch { evidence["cycleReplyLost"] = true }
                try await Task.sleep(for: .seconds(40))
                let online = try? await client.status(host: host, timeout: 2)
                try require(online == nil, "Reader did not enter offline standby")
                try await until("reader lane before wake", timeout: 20) { !busy && !model.isWorking }
                let started = Date()
                model.startConnectionSearch()
                try require(model.readerStatus == nil, "Wake did not start a fresh attempt")
                try await until("actual app BLE wake and LAN return", timeout: 100) {
                    model.readerStatus?.deviceID == identity && !busy && !model.isWorking
                }
                evidence["appReconnectSeconds"] = Date().timeIntervalSince(started)
                try verify(try XCTUnwrap(model.readerStatus), identity: identity, version: version)
                try await inventory(model, idle: { !busy })
                let url = try XCTUnwrap(URL(string: "http://\(host)/api/pocket/v1/dev/ble-cycle"))
                var read = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
                read.httpMethod = "GET"
                let (data, response) = try await URLSession.shared.data(for: read)
                try require((response as? HTTPURLResponse)?.statusCode == 200, "Missing cycle evidence")
                let cycle = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
                evidence["cycle"] = cycle
                try require((cycle["run"] as? NSNumber)?.uint32Value == run, "Stale cycle evidence")
                try require(cycle["state"] as? Int == 3 && cycle["close"] as? String == "app-wifi"
                            && cycle["fromWifi"] as? Bool == true, "App wake did not complete")
                try require((cycle["lightSleepMs"] as? Int ?? 0) > 0
                            && (cycle["lightSleeps"] as? Int ?? 0) > 0 && cycle["returnMode"] as? Int == 2,
                            "No actual light sleep and app return recorded")
                let recovered = (cycle["afterFree"] as? Int ?? 0) - (cycle["beforeFree"] as? Int ?? 0)
                let frame = cycle["frameBytes"] as? Int ?? 0
                try require(cycle["frameReleased"] as? Bool == true && frame > 0 && recovered >= frame,
                            "Sleep did not recover framebuffer memory")
                try require(cycle["statsValid"] as? Bool == true && cycle["gate"] as? String == "open"
                            && (cycle["opened"] as? Int ?? 0) > 0
                            && (cycle["minFree"] as? Int ?? 0) > 50 * 1024
                            && (cycle["minBlock"] as? Int ?? 0) >= 8 * 1024,
                            "BLE memory/admission requirements failed")
            }
            // Exercise the real client through EOF too; an optional subfolder
            // failure must not be hidden by the app's best-effort inventory.
            var folders: [String: Int] = [:]
            for folder in ["/", "/Books"] {
                var cursor = 0, count = 0, pages = 0
                repeat {
                    let data = try await client.readerStorageRequest(endpoint: "files", identity: identity,
                        host: host, port: 80, query: ["path": folder, "cursor": String(cursor)])
                    let page = try JSONDecoder().decode(ReaderFilePage.self, from: data)
                    try page.validate(identity: identity, folder: folder, cursor: cursor)
                    count += page.entries.count
                    cursor = page.nextCursor
                    pages += 1
                    try require(pages < 64 || cursor == 0, "Folder did not terminate")
                } while cursor != 0
                folders[folder] = count
            }
            evidence["folderCounts"] = folders
            evidence["inventoryCount"] = model.readerInventory?.files.count ?? 0
            evidence["bookTransferBytes"] = try await verifyBookRoundTrip(model, client: client,
                host: host, identity: identity, run: run, idle: { !busy })
            evidence["passed"] = true
        } catch {
            evidence["error"] = error.localizedDescription
            throw error
        }
#endif
    }

    private enum Failure: LocalizedError {
        case reason(String)
        var errorDescription: String? { if case let .reason(message) = self { return message }; return nil }
    }

    private func required(_ key: String, _ env: [String: String]) throws -> String {
        guard let value = env[key], !value.isEmpty else { throw Failure.reason("Missing " + key) }
        return value
    }

    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.reason(message) }
    }

    private func verify(_ status: CrossPointStatus, identity: String, version: String) throws {
        try require(status.deviceID == identity && status.version == version && status.mode == "STA",
                    "Reader identity, version or Same Wi-Fi mode changed")
        try require(version.contains("-dev-"), "Developer firmware required")
    }

    @MainActor
    private func verifyBookRoundTrip(_ model: PocketModel, client: CrossPointClient, host: String,
                                    identity: String, run: UInt32, idle: () -> Bool) async throws -> Int {
        // Only this run's generated book is sent or removed. Never adopt a user's
        // library item or delete a path derived from the reader's inventory.
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "Pocket.hardware." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        defaults.set(true, forKey: "library.welcome.v1")
        let storage = BookLibrary(root: root)
        let document = EPUBDocument(title: "Pocket hardware check \(run)", language: "ko",
            chapters: [.init(title: "Round trip", paragraphs: ["Test-only reader transfer. 한글 파일 검증."])])
        let book = try await storage.importDocument(document, origin: .written)
        let library = LibraryModel(storage: storage, defaults: defaults)
        await library.load()
        let file = try await library.fileURL(for: book)
        let original = try Data(contentsOf: file)
        try await until("lane before book transfer", timeout: 30) { idle() && !model.isWorking }
        let created = await model.createBookTransferJob(books: [book], library: library)
        let id = try XCTUnwrap(created)
        try await until("generated book preparation", timeout: 30) { idle() && !model.isWorking }
        try require(model.canSendBookTransferJob(id), "Generated book was not ready to send")
        model.sendBookTransferJob(id)
        try await until("app book transfer", timeout: 90) { idle() && !model.isWorking }
        let job = try XCTUnwrap(model.bookTransferJob(id))
        try require(job.stage == .completed && job.savedCount == 1, "App did not confirm book publication")
        let path = try XCTUnwrap(job.items.first?.publishedPath)
        try require(path == "/" + file.lastPathComponent, "Unexpected generated book destination")
        var received = Data()
        while received.count < original.count {
            let piece = try await client.readerFilePiece(identity: identity, path: path,
                size: Int64(original.count), offset: Int64(received.count), host: host, port: 80)
            guard case .data(let bytes) = piece, !bytes.isEmpty else {
                throw Failure.reason("Reader did not return the generated book")
            }
            received.append(bytes)
            try require(received.count <= original.count, "Reader returned extra book bytes")
        }
        try require(received == original, "Published EPUB differs from library bytes")
        try await until("lane before test book cleanup", timeout: 30) { idle() && !model.isWorking }
        model.deleteReaderFile(path, size: Int64(original.count), folder: "/", identity: identity)
        try await until("test book cleanup", timeout: 30) { idle() && !model.isWorking }
        try require(model.readerFilesError == nil && model.readerFilePage != nil,
                    "Test book cleanup was not confirmed")
        // Fetch a fresh inventory after deletion; the pipeline must finish with
        // the reader's pre-test books intact and the generated file absent.
        try await inventory(model, idle: idle)
        try require(model.readerInventory?.files.contains(where: { $0.path == path }) == false,
                    "Generated book remains in inventory")
        return original.count
    }

    @MainActor
    private func until(_ stage: String, timeout: TimeInterval, _ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !ready() {
            try require(Date() < deadline, "Timed out: " + stage)
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    @MainActor
    private func inventory(_ model: PocketModel, idle: () -> Bool) async throws {
        let started = Date()
        model.requestReaderInventoryRefresh()
        try await until("fresh app inventory", timeout: 60) {
            (model.readerInventory?.readAt ?? .distantPast) >= started && idle()
        }
        try require(model.readerInventoryError == nil, "App inventory failed")
    }
}
