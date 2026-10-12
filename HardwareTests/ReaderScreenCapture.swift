#if os(macOS)
import AppKit
import CryptoKit
import XCTest
@testable import Pocket

/// Physical reader pixels, not the SwiftUI preview. Opted in by --screen-suite.
@MainActor
extension ReaderInterfaceSuite {
    // Boot/sleep appends to the firmware-owned root log. Its presence must stay
    // unchanged, but its byte count is not a user-content preservation invariant.
    static func sameVisualInventory(_ actual: [String: Int64], _ expected: [String: Int64]) -> Bool {
        guard actual.keys.sorted() == expected.keys.sorted() else { return false }
        return expected.allSatisfy { path, size in path == "/agentdeck.log" || actual[path] == size }
    }

    func screenChecks() async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let expectedVersion = try XCTUnwrap(model.readerStatus?.version)
        let original = try await client.readerProfile(deviceID: identity, host: host, port: 80)
        try JSONEncoder().encode(original.profile).write(to: root.appendingPathComponent("original-profile.json"), options: .atomic)
        let previousCards = try await client.contentState(deviceID: identity, host: host, port: 80)
        let savedCards: ContentDraft
        if let active = previousCards.active {
            savedCards = try await ReaderContentPull.draft(revision: active.revision) { name, offset in
                try await self.client.contentFileChunk(revision: active.revision, name: name, offset: offset,
                    deviceID: self.identity, host: self.host, port: 80)
            }
        } else { savedCards = ContentDraft() }
        try JSONEncoder().encode(savedCards).write(to: root.appendingPathComponent("original-cards.json"), options: .atomic)
        let originalReading = try await client.readingProgress(identity: identity, host: host, port: 80)
        var cardsChanged = false
        var sleepEvidence: [String: Any] = [:]
        var captures: [[String: Any]] = []
        var differences: [String: Int] = [:]
        var sequence: UInt32 = 0
        var activeRun: UInt32?
        func request(_ method: String, _ query: [String: String], expected: Int = 200, endpoint: String = "screen-capture") async throws -> (Data, HTTPURLResponse) {
            var url = URLComponents()
            url.scheme = "http"; url.host = host; url.path = "/api/pocket/v1/dev/" + endpoint
            url.queryItems = (["deviceID": identity].merging(query) { _, new in new }).sorted { $0.key < $1.key }
                .map { URLQueryItem(name: $0.key, value: $0.value) }
            var req = URLRequest(url: try XCTUnwrap(url.url))
            req.httpMethod = method; req.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            try check(http.statusCode == expected, "Screen capture \(method) returned \(http.statusCode); expected \(expected)")
            return (data, http)
        }
        func apply(_ profile: PocketProfile, screen: ReaderScreen) async throws -> UInt32 {
            model.sendReaderLayout(profile: profile, cards: nil, show: screen, includePendingPreferences: false)
            try await drained()
            let actual = try await client.readerProfile(deviceID: identity, host: host, port: 80)
            try check(actual.profile == profile, "Visual case profile was not saved")
            try check(model.screenShow == .shown(screen, generation: actual.generation), "App did not confirm the requested screen render")
            return actual.generation
        }
        func capture(_ name: String, _ profile: PocketProfile, _ screen: ReaderScreen) async throws -> ReaderCapturedPixels {
            let generation = try await apply(profile, screen: screen)
            sequence += 1
            let captureRun = run &+ sequence
            let query = ["run": String(captureRun), "generation": String(generation), "surface": screen.rawValue]
            // A changed generation must never certify the retained old frame.
            _ = try await request("POST", query.merging(["generation": String(generation &- 1)]) { _, b in b }, expected: 409)
            activeRun = captureRun // retained for cleanup even if the POST reply is lost
            _ = try await request("POST", query, expected: 204)
            return try await download(name, surface: screen.rawValue, generation: generation, captureRun: captureRun)
        }
        func download(_ name: String, surface: String, generation: UInt32, captureRun: UInt32) async throws -> ReaderCapturedPixels {
            _ = try await request("GET", ["run": String(captureRun &+ 1), "offset": "0"], expected: 409)
            var bytes = Data()
            var total: Int?
            repeat {
                let (piece, http) = try await request("GET", ["run": String(captureRun), "offset": String(bytes.count)])
                let size = try XCTUnwrap(Int(http.value(forHTTPHeaderField: "X-Capture-Size") ?? ""))
                try check(size > 62 && size <= 100_000 && (total == nil || total == size), "Invalid or changed capture size")
                try check(http.value(forHTTPHeaderField: "X-Capture-Run") == String(captureRun), "Stale capture response")
                try check(piece.count == min(1024, size - bytes.count), "Truncated capture chunk")
                total = size; bytes.append(piece)
            } while bytes.count < (total ?? 0)
            let bmp = root.appendingPathComponent(name + ".bmp")
            try bytes.write(to: bmp, options: .atomic)
            // Decode the file read back from disk, not an in-memory preview.
            let pixels = try ReaderCapturedPixels(data: Data(contentsOf: bmp))
            let png = try XCTUnwrap(NSBitmapImageRep(data: bytes)?.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent(name + ".png"), options: .atomic)
            XCTContext.runActivity(named: "X3 screen " + name) { activity in
                for (data, type, suffix) in [(bytes, "com.microsoft.bmp", ".bmp"), (png, "public.png", ".png")] {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
                    attachment.name = name + suffix
                    attachment.lifetime = .keepAlways
                    activity.add(attachment)
                }
            }
            try check(pixels.width == 528 && pixels.height == 792, "Capture does not have the native X3 panel dimensions")
            try check(pixels.contentInk > 200, "Reader screen has no body content or empty-state explanation")
            try check(pixels.ink > 500 && pixels.ink < pixels.width * pixels.height / 2, "Blank or implausible frame")
            print("POCKET_SCREEN_CAPTURE " + name + " saved")
            captures.append(["name": name, "surface": surface, "generation": generation,
                             "run": captureRun, "sha256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(),
                             "width": pixels.width, "height": pixels.height, "inkPixels": pixels.ink, "contentInkPixels": pixels.contentInk])
            _ = try await request("DELETE", ["run": String(captureRun)], expected: 204)
            activeRun = nil
            return pixels
        }
        func reconnect() async throws {
            let deadline = Date().addingTimeInterval(150)
            while true {
                if let status = try? await client.status(host: host, timeout: 2) {
                    try check(status.deviceID == identity && status.version == expectedVersion, "Reader identity/version changed after automatic return")
                    break
                }
                try check(Date() < deadline, "Reader did not return to Same Wi-Fi automatically")
                try await Task.sleep(for: .seconds(2))
            }
            try await drained()
            model.startConnectionSearch()
            try await wait("automatic app reconnection", seconds: 60) {
                self.model.readerStatus?.deviceID == self.identity && self.idle() && !self.model.isWorking
            }
        }
        func schedule(_ endpoint: String, query: [String: String]) async throws {
            // One mutation only. A missing restart reply is resolved by evidence;
            // blindly retrying could open/sleep the reader a second time.
            do { _ = try await request("POST", query, expected: 202, endpoint: endpoint) }
            catch let failure as Failure { throw failure }
            catch { print("POCKET_SCREEN_CAPTURE restart reply lost; observing automatic return") }
            try await Task.sleep(for: .seconds(25))
            try await reconnect()
        }
        func restore() async throws {
            var failures: [String] = []
            func attempt(_ label: String, _ work: () async throws -> Void) async {
                do { try await work() }
                catch { failures.append(label + ": " + error.localizedDescription) }
            }
            await attempt("capture cleanup") {
                if let activeRun { _ = try await request("DELETE", ["run": String(activeRun)], expected: 204) }
            }
            await attempt("card restoration") {
                if cardsChanged {
                    let revision = try savedCards.revision()
                    let task = try XCTUnwrap(model.applyContent(revision, drawCards: false))
                    await task.value
                    try await drained()
                    let restored = try await client.contentState(deviceID: identity, host: host, port: 80)
                    try check(restored.active?.revision == revision.revision, "Original reader cards were not restored")
                    cardsChanged = false
                }
            }
            await attempt("owned job cleanup") { try await cleanupJobs() }
            await attempt("owned file cleanup") {
                try await cleanupFiles()
                if !jobs.isEmpty { try check(Self.sameVisualInventory(try await fileMap(), baseline), "Reader inventory changed after visual fixture cleanup") }
            }
            await attempt("profile restoration") { _ = try await apply(original.profile, screen: .home) }
            await attempt("reading preservation") {
                let reading = try await client.readingProgress(identity: identity, host: host, port: 80)
                try check(reading == originalReading, "Existing reader positions or recent-book order changed")
            }
            try check(failures.isEmpty, failures.joined(separator: "; "))
        }
        do {
            var base = original.profile
            base.home = .init(items: [.reading], dailyWord: false, weather: .off, nextEvent: false)
            base.sleep = .init(mode: .brief, sections: [.weather])
            let a = try await capture("01-home-reading", base, .home)
            var word = base
            word.home.items = [.word]; word.home.dailyWord = true
            let b = try await capture("02-home-word", word, .home)
            let a2 = try await capture("03-home-reading-restored", base, .home)
            try check(a.difference(b) > 500, "Home item change did not change reader pixels")
            try check(a.difference(a2) == 0, "Home A-B-A did not restore identical content pixels")
            var weather = word
            weather.home.weather = .bottom
            let bottom = try await capture("04-home-weather-bottom", weather, .home)
            weather.home.weather = .top
            let top = try await capture("05-home-weather-top", weather, .home)
            try check(b.difference(bottom) > 500 && top.difference(bottom) > 500,
                      "Weather visibility/placement did not affect the rendered layout")
            let briefWeather = try await capture("06-brief-weather", base, .brief)
            var today = base
            today.sleep.sections = [.today]
            let briefToday = try await capture("07-brief-today", today, .brief)
            let briefRestored = try await capture("08-brief-weather-restored", base, .brief)
            try check(briefWeather.difference(briefToday) > 500, "Brief section change did not change reader pixels")
            try check(briefWeather.difference(briefRestored) == 0, "Brief A-B-A did not restore identical content pixels")
            try check(a.difference(briefWeather) > 500, "Home and Brief unexpectedly have the same frame")
            differences = ["homeItem": a.difference(b), "homeRestored": a.difference(a2),
                           "weatherVisible": b.difference(bottom), "weatherPosition": top.difference(bottom),
                           "briefSection": briefWeather.difference(briefToday),
                           "briefRestored": briefWeather.difference(briefRestored),
                           "homeVsBrief": a.difference(briefWeather)]
            // Keep the title/text identical: only the image changes in A-B-A.
            func image(_ alternate: Bool) throws -> Data {
                var raster = Data(repeating: 0, count: 16 * 96)
                for y in 0..<96 {
                    for x in 0..<128 {
                        let ink = alternate ? (x > 70 && y > 25 && y < 80) : ((x < 40 && y < 60) || (x > 85 && y > 72))
                        if ink { raster[y * 16 + x / 8] |= 0x80 >> (x % 8) }
                    }
                }
                return try ContentImage(width: 128, height: 96, raster: raster).encoded()
            }
            func card(_ name: String, alternate: Bool) async throws -> ReaderCapturedPixels {
                let revision = try ContentRevision(cards: [.init(id: "visual", title: "Image verification",
                    question: "Same words. Different picture.", imagePath: "probe.pbm", layout: .imageFirst)],
                    images: ["probe.pbm": image(alternate)])
                cardsChanged = true
                let task = try XCTUnwrap(model.applyContent(revision))
                await task.value
                try await drained()
                let active = try XCTUnwrap(model.contentRedrawReceipt)
                try check(active.revision == revision.revision, "Card render was not confirmed")
                sequence += 1
                let captureRun = run &+ sequence
                activeRun = captureRun
                let query = ["run": String(captureRun), "surface": "card", "generation": String(active.generation), "revision": active.revision]
                _ = try await request("POST", query.merging(["generation": String(active.generation &- 1)]) { _, b in b }, expected: 409)
                _ = try await request("POST", query, expected: 204)
                let pixels = try await download(name, surface: "card", generation: active.generation, captureRun: captureRun)
                try check(pixels.contains(try ContentImage.decode(image(alternate))), "The card does not contain the exact sent image raster")
                try check(!pixels.contains(try ContentImage.decode(image(!alternate))), "The card retained the other image raster")
                return pixels
            }
            let cardA = try await card("09-card-image-a", alternate: false)
            let cardB = try await card("10-card-image-b", alternate: true)
            let cardRestored = try await card("11-card-image-restored", alternate: false)
            try check(cardA.difference(cardB) > 1000, "Replacing just the card image did not change its pixels")
            try check(cardA.difference(cardRestored) == 0, "Card image A-B-A did not restore the same pixels")
            differences["cardImage"] = cardA.difference(cardB)
            differences["cardRestored"] = cardA.difference(cardRestored)

            // App-authored EPUB, actual on-device reader activity, bounded automatic LAN return.
            sequence += 1
            let bookRun = run &+ sequence
            let defaultsName = "Pocket.visual." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
            defaults.set(true, forKey: "library.welcome.v1")
            defer { defaults.removePersistentDomain(forName: defaultsName) }
            let storage = BookLibrary(root: root.appendingPathComponent("visual-library"))
            let library = LibraryModel(storage: storage, defaults: defaults)
            baseline = try await fileMap()
            let document = EPUBDocument(title: "Pocket visual \(bookRun)", language: "en",
                chapters: [.init(title: "Reader verification", paragraphs: [
                    "The amber fox reads beside the quiet river.",
                    "A blue lantern marks the second paragraph.",
                    "This page comes from the book stored on the reader."] + Array(repeating: "Reading continues across the paper page.", count: 25))])
            let imported = try await storage.importDocument(document, origin: .written)
            // Fixed run-bound developer endpoint; rename only our isolated fixture.
            let importedURL = try await storage.fileURL(for: imported)
            let fixtureName = "Pocket visual \(bookRun).epub"
            try FileManager.default.moveItem(at: importedURL, to: importedURL.deletingLastPathComponent().appendingPathComponent(fixtureName))
            let book = try await storage.update(imported.id) { $0.fileName = fixtureName }
            await library.load()
            let job = try await prepare([book], library: library)
            try await send(job)
            try check(model.bookTransferJob(job)?.items.first?.publishedPath == "/Pocket visual \(bookRun).epub", "Unexpected fixture path")
            activeRun = bookRun
            try await schedule("reader-capture", query: ["run": String(bookRun)])
            _ = try await download("12-reader-body", surface: "reader", generation: 0, captureRun: bookRun)
            try await cleanupJobs()
            try await cleanupFiles()

            // A real deep-sleep entry, retained Brief capture and timer wake.
            _ = try await apply(today, screen: .brief)
            sequence += 1
            let sleepRun = run &+ sequence
            activeRun = sleepRun
            try await schedule("ble-cycle", query: ["run": String(sleepRun), "sleep": "timer"])
            let (cycleData, _) = try await request("GET", [:], endpoint: "ble-cycle")
            let cycle = try XCTUnwrap(try JSONSerialization.jsonObject(with: cycleData) as? [String: Any])
            try check((cycle["run"] as? NSNumber)?.uint32Value == sleepRun && cycle["state"] as? Int == 3 &&
                      cycle["returnMode"] as? Int == 1 && cycle["timerArmed"] as? Bool == true &&
                      cycle["timerWake"] as? Bool == true, "No matching actual deep sleep and timer wake evidence")
            sleepEvidence = cycle
            let asleep = try await download("13-actual-sleep", surface: "sleep", generation: 0, captureRun: sleepRun)
            differences["sleepContentRetained"] = briefToday.difference(asleep)
            try check(briefToday.difference(asleep) == 0, "Actual sleep did not retain the selected Brief body")
            try await restore()
        } catch {
            let failure = error
            do { try await restore() }
            catch { throw Failure(message: "Screen validation: \(failure.localizedDescription). Restoration: \(error.localizedDescription)") }
            throw failure
        }
        let result: [String: Any] = ["passed": true, "captures": captures, "artifactDirectory": root.path,
                                    "restored": true, "staleCaptureRejected": true, "pixelDifferences": differences,
                                    "sleepCycle": sleepEvidence, "cardsRestored": !cardsChanged, "readingPreserved": true,
                                    "scope": "X3 Home/Brief/card/EPUB framebuffer and actual timer deep sleep; excludes optical panel"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent("screen-validation.json"), options: .atomic)
        return result
    }
}

struct ReaderCapturedPixels {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    var ink: Int { pixels.filter { $0 < 128 }.count }
    var contentInk: Int {
        guard height > 180 else { return 0 }
        return pixels[(100 * width)..<((height - 80) * width)].filter { $0 < 128 }.count
    }
    init(data: Data) throws {
        guard let rep = NSBitmapImageRep(data: data), let image = rep.cgImage,
              image.width > 0, image.height > 0, image.width <= 1000, image.height <= 1000 else {
            throw ReaderInterfaceSuite.Failure(message: "Invalid captured bitmap")
        }
        let width = image.width, height = image.height
        self.width = width; self.height = height
        var buffer = [UInt8](repeating: 255, count: width * height)
        let drawn = buffer.withUnsafeMutableBytes { ptr -> Bool in
            guard let context = CGContext(data: ptr.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ReaderInterfaceSuite.Failure(message: "Cannot decode captured pixels") }
        pixels = buffer
    }
    /// Search exact raster bytes, independently of firmware layout coordinates.
    /// Asymmetric fixtures detect mirrored, clipped, stale and inverted images.
    func contains(_ image: ContentImage) -> Bool {
        guard image.width <= width, image.height <= height else { return false }
        let expected = (0..<image.height).flatMap { y in
            (0..<image.width).map { x in image.raster[y * ((image.width + 7) / 8) + x / 8] & (0x80 >> (x % 8)) != 0 }
        }
        let ink = expected.indices.filter { expected[$0] }
        var probes = [0, image.width - 1, image.width * (image.height / 2), expected.count - 1]
        if let first = ink.first, let last = ink.last { probes += [first, ink[ink.count / 2], last] }
        // Reject at distinctive ink positions before scanning a white prefix;
        // an absent image must not scan thousands of blank pixels per origin.
        for y in 0...(height - image.height) {
            for x in 0...(width - image.width) {
                func matches(_ index: Int) -> Bool {
                    (pixels[(y + index / image.width) * width + x + index % image.width] < 128) == expected[index]
                }
                if probes.allSatisfy(matches) && expected.indices.allSatisfy(matches) { return true }
            }
        }
        return false
    }
    func difference(_ other: Self) -> Int {
        guard width == other.width && height == other.height && height > 180 else { return Int.max }
        // Exclude the clock/header and button footer; changing time is not a
        // successful layout mutation and cannot break A-B-A restoration.
        return (100 * width..<(height - 80) * width).reduce(0) {
            $0 + ((pixels[$1] < 128) != (other.pixels[$1] < 128) ? 1 : 0)
        }
    }
}
#endif

#if os(macOS)
@MainActor
final class ReaderScreenCaptureTests: XCTestCase {
    private func fixture(_ changed: Bool, headerOnly: Bool = false, emptyBody: Bool = false) throws -> ReaderCapturedPixels {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 528, pixelsHigh: 792,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
            bytesPerRow: 528, bitsPerPixel: 8))
        let data = try XCTUnwrap(bitmap.bitmapData)
        for y in 0..<792 {
            for x in 0..<528 {
                let base = (!emptyBody || y < 60) && (x * 3 + y * 5) % 31 < 3
                let mutation = changed && (headerOnly ? y < 60 : (y > 200 && y < 260 && x > 30 && x < 180))
                data[y * 528 + x] = base != mutation ? 0 : 255
            }
        }
        return try ReaderCapturedPixels(data: XCTUnwrap(bitmap.representation(using: .bmp, properties: [:])))
    }
    @MainActor
    func testVisualInventoryAllowsOnlyExistingFirmwareLogSizeChanges() {
        let baseline: [String: Int64] = ["/agentdeck.log": 100, "/Books/sample.epub": 200]
        XCTAssertTrue(ReaderInterfaceSuite.sameVisualInventory(["/agentdeck.log": 150, "/Books/sample.epub": 200], baseline))
        XCTAssertFalse(ReaderInterfaceSuite.sameVisualInventory(["/agentdeck.log": 150, "/Books/sample.epub": 201], baseline))
        XCTAssertFalse(ReaderInterfaceSuite.sameVisualInventory(["/Books/sample.epub": 200], baseline))
        XCTAssertFalse(ReaderInterfaceSuite.sameVisualInventory(["/agentdeck.log": 150, "/Books/sample.epub": 200, "/leftover.epub": 1], baseline))
    }

    func testPixelOracleDetectsContentChangeButNotClockOnlyChange() throws {
        let original = try fixture(false)
        XCTAssertEqual(original.difference(try fixture(false)), 0)
        XCTAssertGreaterThan(original.difference(try fixture(true)), 500)
        XCTAssertEqual(original.difference(try fixture(true, headerOnly: true)), 0)
        XCTAssertGreaterThan(original.ink, 500)
    }
    func testHeaderAndFooterCannotCountAsBodyContent() throws {
        let blank = try fixture(false, emptyBody: true)
        XCTAssertGreaterThan(blank.ink, 500)
        XCTAssertEqual(blank.contentInk, 0)
        XCTAssertGreaterThan(try fixture(false).contentInk, 200)
    }
    func testImageOracleRejectsMirroringClippingAndWrongRaster() throws {
        let raster = Data([0xF0, 0xB0, 0x80, 0x04, 0x07])
        let expected = try ContentImage(width: 8, height: 5, raster: raster)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 40, pixelsHigh: 32,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
            bytesPerRow: 40, bitsPerPixel: 8))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for i in 0..<(40 * 32) { bytes[i] = 255 }
        for y in 0..<5 {
            for x in 0..<8 { bytes[(y + 7) * 40 + x + 13] = raster[y] & (0x80 >> x) != 0 ? 0 : 255 }
        }
        let pixels = try ReaderCapturedPixels(data: XCTUnwrap(bitmap.representation(using: .bmp, properties: [:])))
        XCTAssertTrue(pixels.contains(expected))
        XCTAssertFalse(pixels.contains(try ContentImage(width: 8, height: 5, raster: Data(raster.reversed()))))
        XCTAssertFalse(pixels.contains(try ContentImage(width: 8, height: 5, raster: Data([0xF0, 0xB0, 0x80, 0x04, 0x06]))))
        XCTAssertFalse(pixels.contains(try ContentImage(width: 48, height: 5, raster: Data(repeating: 0, count: 30))))
    }
    func testAbsentImageWithWhiteMarginsDoesNotBlockTheAppForMinutes() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 528, pixelsHigh: 792,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceWhite,
            bytesPerRow: 528, bitsPerPixel: 8))
        let bytes = try XCTUnwrap(bitmap.bitmapData)
        for i in 0..<(528 * 792) { bytes[i] = 255 }
        let blank = try ReaderCapturedPixels(data: XCTUnwrap(bitmap.representation(using: .bmp, properties: [:])))
        var raster = Data(repeating: 0, count: 16 * 96)
        raster[26 * 16 + 9] = 0x40
        let pattern = try ContentImage(width: 128, height: 96, raster: raster)
        let started = Date()
        XCTAssertFalse(blank.contains(pattern))
        XCTAssertLessThan(Date().timeIntervalSince(started), 3, "The reader heartbeat must not be starved by white-prefix image searches")
    }
    func testBrokenBitmapIsNeverAcceptedAsScreenEvidence() {
        XCTAssertThrowsError(try ReaderCapturedPixels(data: Data("not a reader bitmap".utf8)))
    }
}
#endif
