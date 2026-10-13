#if os(macOS)
import AppKit
import CryptoKit
import ImageIO
import SwiftUI
import Vision
import WebKit
import XCTest
@testable import Pocket

@MainActor
extension ReaderInterfaceSuite {
    /// Real EPUB, offer transport, confirmation actions, rendered pages and exit records.
    func continuityChecks() async throws -> [String: Any] {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        baseline = try await fileMap()
        let original = try await client.readingProgress(identity: identity, host: host, port: 80)
        let domain = "Pocket.continuity." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.set(true, forKey: "library.welcome.v1")
        defaults.set(false, forKey: "sync.icloud.enabled")
        defer { defaults.removePersistentDomain(forName: domain) }
        let storage = BookLibrary(root: root.appendingPathComponent("library"))
        let library = LibraryModel(storage: storage, defaults: defaults)
        let sync = ReadingSync(defaults: defaults, deviceName: "Continuity Mac", iCloudAvailable: { false })
        let names = ["Amber orchard", "Silver meadow", "Violet harbor"]
        let bookRun = run &+ 20
        let document = EPUBDocument(title: "Pocket visual \(bookRun)", language: "en", chapters: names.map { name in
            .init(title: name, paragraphs: (1...35).map { index in
                "\(name) checkpoint \(index). The quiet traveler reads beside the river and remembers this place. A lantern lights the path through the garden."
            })
        })
        let sourcePath = ProcessInfo.processInfo.environment["POCKET_HARDWARE_CONTINUITY_EPUB"]
        let imported: LibraryBook
        if let sourcePath, !sourcePath.isEmpty {
            imported = try await storage.importFile(at: URL(fileURLWithPath: sourcePath))
        } else {
            imported = try await storage.importDocument(document, origin: .written)
        }
        // Digest-keyed firmware records must never alias an existing user's book.
        try check(!original.books.contains { $0.document == imported.documentDigest }, "Continuity fixture already has reader history; refusing to alter it")
        receivingLibrary = LibraryModel(storage: BookLibrary(root: root.appendingPathComponent("received-library")), defaults: defaults)
        let importedURL = try await storage.fileURL(for: imported)
        let fileName = "Pocket visual \(bookRun).epub"
        let file = importedURL.deletingLastPathComponent().appendingPathComponent(fileName)
        try FileManager.default.moveItem(at: importedURL, to: file)
        let book = try await storage.update(imported.id) { $0.fileName = fileName }
        if let sourcePath, !sourcePath.isEmpty {
            try check(FileManager.default.contentsEqual(atPath: sourcePath, andPath: file.path), "Import changed the source EPUB bytes")
        }
        let sourceSHA = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        await library.load()
        let session = ReaderSession(bookFile: file, appearance: ReaderAppearance())
        session.open(at: nil)
        let hosting = NSHostingView(rootView: BookReaderView(book: book, session: session, library: library, sync: sync, close: {}))
        let frame = NSRect(x: 0, y: -20_000, width: 620, height: 850)
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = hosting
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        var fixtureArmed = false
        var captures: [[String: Any]] = []
        var cases: [[String: Any]] = []
        defer {
            if let data = try? JSONSerialization.data(withJSONObject: ["cases": cases, "captures": captures], options: [.sortedKeys]) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "continuity-checkpoints"; attachment.lifetime = .keepAlways; XCTContext.runActivity(named: "Continuity checkpoints") { $0.add(attachment) }
            }
        }
        func request(_ method: String, _ endpoint: String = "reader-capture", query: [String: String] = [:], expected: Int = 200) async throws -> (Data, HTTPURLResponse) {
            var url = URLComponents()
            url.scheme = "http"; url.host = host; url.path = "/api/pocket/v1/dev/" + endpoint
            url.queryItems = ["deviceID": identity, "run": String(bookRun)].merging(query) { _, new in new }
                .sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            var req = URLRequest(url: try XCTUnwrap(url.url)); req.httpMethod = method; req.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: req)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            let knownFailures = ["Another file transfer is active", "Reader identity mismatch",
                                 "Missing reader fixture or request could not be saved",
                                 "Reader memory is too low for content verification"]
            let body = String(data: data, encoding: .utf8) ?? ""
            let detail = knownFailures.contains(body) ? ": " + body : ""
            try check(http.statusCode == expected, "Continuity \(method) \(endpoint): HTTP \(http.statusCode)\(detail)")
            return (data, http)
        }
        func pixels(_ name: String) async throws -> [String] {
            var bytes = Data(), total = 0
            repeat {
                let (part, http) = try await request("GET", "screen-capture", query: ["offset": String(bytes.count)])
                let size = try XCTUnwrap(Int(http.value(forHTTPHeaderField: "X-Capture-Size") ?? ""))
                try check(size > 62 && size < 100_000 && (total == 0 || total == size), "Invalid capture size")
                try check(http.value(forHTTPHeaderField: "X-Capture-Run") == String(bookRun), "Stale reading capture")
                try check(part.count == min(1024, size - bytes.count), "Incomplete reading capture")
                total = size; bytes.append(part)
            } while bytes.count < total
            let bmp = root.appendingPathComponent(name + ".bmp")
            try bytes.write(to: bmp, options: .atomic)
            let saved = try Data(contentsOf: bmp)
            let decoded = try ReaderCapturedPixels(data: saved)
            try check(decoded.width == 528 && decoded.height == 792 && decoded.contentInk > 200, "No native X3 page")
            let png = try XCTUnwrap(NSBitmapImageRep(data: saved)?.representation(using: .png, properties: [:]))
            try png.write(to: root.appendingPathComponent(name + ".png"), options: .atomic)
            // Keep native pixels intact. The user's reading orientation can be
            // landscape; Vision's implicit rotation misreads opening quotes/I.
            // Each candidate is checked independently with exact source text.
            var readings: [String] = []
            for orientation: CGImagePropertyOrientation in [.up, .right, .down, .left] {
                let recognition = VNRecognizeTextRequest()
                recognition.recognitionLevel = .accurate; recognition.recognitionLanguages = ["en-US"]
                recognition.usesLanguageCorrection = false
                try VNImageRequestHandler(data: png, orientation: orientation).perform([recognition])
                readings.append((recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
            }
            try check(readings.contains { !$0.isEmpty }, "No text recognized in the X3 page")
            XCTContext.runActivity(named: name) { activity in
                for (data, type, suffix) in [(saved, "com.microsoft.bmp", ".bmp"), (png, "public.png", ".png")] {
                    let attachment = XCTAttachment(data: data, uniformTypeIdentifier: type)
                    attachment.name = name + suffix; attachment.lifetime = .keepAlways; activity.add(attachment)
                }
            }
            captures.append(["name": name, "run": bookRun, "sha256": SHA256.hash(data: saved).map { String(format: "%02x", $0) }.joined(), "ocrOrientations": ["up", "right", "down", "left"], "text": readings])
            _ = try await request("DELETE", "screen-capture", expected: 204)
            return readings
        }
        func exercise(_ action: String, name: String) async throws -> (ReaderReadingList, [String]) {
            print("POCKET_CONTINUITY \(name) running")
            let (readiness, _) = try await request("GET")
            XCTContext.runActivity(named: name + " admission") { activity in
                let attachment = XCTAttachment(data: readiness, uniformTypeIdentifier: "public.json")
                attachment.name = name + "-admission"; attachment.lifetime = .keepAlways
                activity.add(attachment)
            }
            do {
                _ = try await request("POST", query: ["action": action], expected: 202)
                fixtureArmed = true
            } catch let error as Failure { throw error }
            catch {
                fixtureArmed = true // an unknown POST outcome still needs cleanup
                print("POCKET_CONTINUITY restart reply lost; waiting for evidence")
            }
            try await Task.sleep(for: .seconds(25))
            let deadline = Date().addingTimeInterval(150)
            while true {
                if let status = try? await client.status(host: host, timeout: 2), status.deviceID == identity { break }
                try check(Date() < deadline, "X3 did not return after reading")
                try await Task.sleep(for: .seconds(2))
            }
            let (data, _) = try await request("GET")
            let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            try check(result["completed"] as? Bool == true, "Reading action did not reach its acceptance/exit checkpoint")
            try await drained()
            model.startConnectionSearch()
            try await wait("app reconnection after reading") {
                model.readerStatus?.deviceID == identity && idle() && !model.isWorking
            }
            let text = try await pixels(name)
            let list = try await client.readingProgress(identity: identity, host: host, port: 80)
            return (list, text)
        }
        func entry(_ list: ReaderReadingList) throws -> ReaderReadingEntry {
            let value = try XCTUnwrap(list.books.first { $0.document == book.documentDigest })
            try check(value.progress != nil && (value.seq ?? 0) > 0, "No actual exit position")
            return value
        }
        func normalize(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
        func containsAnchor(_ text: String, _ expected: String) -> Bool {
            let haystack = normalize(text), needle = normalize(expected)
            guard !needle.isEmpty, let range = haystack.range(of: needle) else { return false }
            // Checkpoint 1 must not certify checkpoint 10 or 19.
            return range.upperBound == haystack.endIndex || !haystack[range.upperBound].isNumber
        }
        func pageText() async throws -> String {
            let value = try await session.webView.evaluateJavaScript("document.querySelector('foliate-view').lastLocation.range.toString()")
            return try XCTUnwrap(value as? String)
        }
        func navigate(fraction: Double, chapter: Int, paragraph: Int, label: String) async throws {
            let previous = session.position?.xpointer
            let target = "/body/DocFragment[\(chapter)]/body/p[\(paragraph)]/text().0"
            if sourcePath == nil {
                // A short book's whole page can exceed 5% of its length.
                // Select and verify a character instead of assuming progress
                // rounds within an arbitrary percentage of the requested value.
                session.go(to: ReadingPosition(fraction: fraction, xpointer: target, cfi: nil,
                                               chapter: nil, updatedAt: Date()))
            } else {
                session.go(toFraction: fraction)
            }
            try await wait(label) {
                guard let current = session.position, current.xpointer != previous else { return false }
                return sourcePath == nil
                    ? current.xpointer?.hasPrefix("/body/DocFragment[\(chapter)]/") == true
                    : abs(current.fraction - fraction) < 0.05
            }
            if sourcePath == nil {
                let visible = try await session.webView.callAsyncJavaScript(ReaderContinuityPosition.visibleCharacter,
                    arguments: ["pointer": target], contentWorld: .page) as? Bool
                try check(visible == true, "\(label): target paragraph is not on the visible page")
            }
        }
        func textAfter(_ pointer: String) async throws -> String {
            let value = try await session.webView.callAsyncJavaScript("""
                const X = await import('pocket-reader://engine/xpointer.js');
                const v = document.querySelector('foliate-view');
                const p = X.parse(pointer);
                const d = await v.book.sections[p.sectionIndex].createDocument();
                const resolved = X.toRange(d, p);
                if (!resolved.exact) throw Error('Inexact anchor');
                const range = resolved.range;
                range.setEnd(d.body, d.body.childNodes.length);
                return range.toString();
                """, arguments: ["pointer": pointer], contentWorld: .page)
            return try XCTUnwrap(value as? String)
        }
        func anchor(_ pointer: String) async throws -> String {
            let value = try await session.webView.callAsyncJavaScript("""
                const X = await import('pocket-reader://engine/xpointer.js');
                const v = document.querySelector('foliate-view');
                const p = X.parse(pointer);
                const d = await v.book.sections[p.sectionIndex].createDocument();
                const resolved = X.toRange(d, p);
                if (!resolved.exact) throw Error('Inexact anchor');
                const range = resolved.range;
                const el = range.startContainer.nodeType === 3 ? range.startContainer.parentElement : range.startContainer;
                const para = el.closest('p') || el.querySelector('p');
                return para?.textContent?.split('. ')[0] || '';
                """, arguments: ["pointer": pointer], contentWorld: .page)
            return try XCTUnwrap(value as? String)
        }
        func exchange(expectedSent: Int) async throws {
            try await drained()
            var completed = false
            var sent = -1
            var failure: Error?
            model.exchangeReadingPositions(force: true, prepare: { list, name in
                sync.exchange(with: list, readerName: name, library: library.books)
            }, finish: { name, count, error in
                sync.exchangeFinished(readerName: name, sent: count, error: error)
                sent = count; failure = error; completed = true
            })
            try await wait("shipping reading exchange", seconds: 30) { completed }
            if let failure { throw failure }
            try check(sent == expectedSent, "Unexpected reading offers: \(sent), expected \(expectedSent)")
            try await drained()
        }
        func restore() async throws {
            var failures: [String] = []
            func attempt(_ work: () async throws -> Void) async {
                do { try await work() } catch { failures.append(error.localizedDescription) }
            }
            await attempt {
                if fixtureArmed { _ = try await request("DELETE", expected: 204); fixtureArmed = false }
            }
            await attempt { try await cleanupJobs() }
            await attempt { try await cleanupFiles() }
            await attempt {
                let after = try await client.readingProgress(identity: identity, host: host, port: 80)
                try check(after == original, "Original reader positions/recents changed")
                try check(Self.sameVisualInventory(try await fileMap(), baseline), "Inventory changed after reading trial")
            }
            try check(failures.isEmpty, failures.joined(separator: "; "))
        }
        do {
            try await wait("app reader page") { session.phase == .ready && session.position != nil }
            let job = try await prepare([book], library: library)
            try await send(job)
            try await download(path: "/" + fileName, book: book, original: file, library: library)
            let (seedList, _) = try await exercise("seed", name: "continuity-seed")
            let seed = try entry(seedList)
            try await exchange(expectedSent: 0)
            for (index, fraction) in [0.48, 0.16].enumerated() {
                let expectedChapter = index == 0 ? 2 : 1
                try await navigate(fraction: fraction, chapter: expectedChapter, paragraph: 17, label: "app source position")
                print("POCKET_CONTINUITY app source fraction=\(session.position?.fraction ?? -1)")
                await library.flushPositions()
                let position = try XCTUnwrap(session.position)
                let sourcePointer = try XCTUnwrap(position.xpointer)
                let expected: String
                if sourcePath != nil {
                    expected = String(normalize(try await textAfter(sourcePointer)).prefix(32))
                } else {
                    expected = try await anchor(sourcePointer)
                }
                try check(!expected.isEmpty, "No distinct source paragraph")
                let before = try await client.readingProgress(identity: identity, host: host, port: 80)
                try await exchange(expectedSent: 1)
                let pending = try await client.readingProgress(identity: identity, host: host, port: 80)
                try check(try entry(pending) == entry(before), "Posting the offer moved the reader without consent")
                let (accepted, rendered) = try await exercise("accept", name: "continuity-app-to-x3-\(index)")
                let landed = try entry(accepted)
                try check(rendered.contains { containsAnchor($0, expected) }, "X3 accepted a different paragraph: expected \(expected); OCR \(rendered)")
                try check(landed.seq != (try entry(before)).seq && abs(landed.percentage - position.fraction) < 0.09, "X3 did not record its accepted page")
                try await exchange(expectedSent: 0)
                // Put the app in another chapter before the reader reads again.
                // A target already on the Mac page cannot prove actual navigation.
                let parkedChapter = index == 0 ? 1 : 3
                let parkedFraction = index == 0 ? 0.0 : 0.9
                try await navigate(fraction: parkedFraction, chapter: parkedChapter, paragraph: 1,
                                   label: "app parked away from reader")
                await library.flushPositions()
                let (advanced, advancedText) = try await exercise("advance", name: "continuity-x3-to-app-\(index)")
                let readerPlace = try entry(advanced)
                try check(readerPlace.seq != landed.seq && readerPlace.progress != landed.progress, "X3 did not turn and record a new page")
                let tail = try await textAfter(try XCTUnwrap(readerPlace.progress))
                let readerAnchor: String
                if sourcePath != nil {
                    readerAnchor = String(normalize(tail).prefix(32))
                } else {
                    let marker = try XCTUnwrap(tail.range(of: "(?:Amber orchard|Silver meadow|Violet harbor) checkpoint [0-9]+\\.", options: .regularExpression))
                    readerAnchor = String(tail[marker].dropLast())
                }
                let firstCharacters = String(normalize(tail).prefix(32))
                try check(advancedText.contains { containsAnchor($0, readerAnchor) && normalize($0).contains(firstCharacters) },
                          "X3 saved character differs from captured page: \(readerPlace.progress ?? "nil"), prefix \(firstCharacters), anchor \(readerAnchor); OCR \(advancedText)")
                let appBefore = session.position
                let readerChapter = try XCTUnwrap(readerPlace.progress?.split(separator: "/").first { $0.hasPrefix("DocFragment[") })
                try check(appBefore?.xpointer?.contains(String(readerChapter) + "/") == false,
                          "Reader offer must begin outside the app's current chapter")
                try await exchange(expectedSent: 0)
                let expectedLabel = "Go to " + readerPlace.percentage.formatted(.percent.precision(.fractionLength(0)))
                let go = try await ReaderContinuityInput.locate(expectedLabel, in: hosting)
                try check(session.position == appBefore, "Receiving reader position moved the app without consent")
                try ReaderContinuityInput.press(go, in: window, name: "continuity-app-offer-\(index)")
                try await wait("app accepted reader position") { session.position != appBefore }
                let targetVisible = try await session.webView.callAsyncJavaScript(ReaderContinuityPosition.visibleCharacter,
                    arguments: ["pointer": try XCTUnwrap(readerPlace.progress)], contentWorld: .page)
                let snapshot = try await session.webView.takeSnapshot(configuration: nil)
                XCTContext.runActivity(named: "continuity-app-accepted-\(index)") { activity in
                    let attachment = XCTAttachment(image: snapshot); attachment.name = "continuity-app-accepted-\(index)"; attachment.lifetime = .keepAlways; activity.add(attachment)
                }
                try check(targetVisible as? Bool == true, "Accepted XPointer character is outside the app's visible page")
                let appText = try await pageText()
                try check(normalize(appText).count > 50, "Accepted app page contains no readable body")
                cases.append(["direction": "bidirectional", "round": index, "backwardOffer": index == 1,
                              "passed": true, "appAnchor": expected, "readerAnchor": readerAnchor,
                              "readerSeq": readerPlace.seq ?? 0, "noMovementBeforeAcceptance": true, "acceptedCharacterVisible": true, "navigatedFromAnotherChapter": true])
                print("POCKET_CONTINUITY round \(index) passed")
            }
            try check(seed.percentage < 0.1, "Seed did not start at the beginning")
            try await restore()
        } catch {
            let failure = error
            do { try await restore() }
            catch { throw Failure(message: "Continuity: \(failure.localizedDescription). Cleanup: \(error.localizedDescription). Artifacts: \(root.path)") }
            throw failure
        }
        return ["passed": true, "restored": true, "cases": cases, "captures": captures, "artifactDirectory": root.path,
                "epub": ["kind": sourcePath == nil ? "generated" : "published-book", "sha256": sourceSHA,
                         "bytes": book.byteCount, "roundTripBytesMatch": true, "libraryReimportMatches": true],
                "downloads": downloadEvidence]
    }
}
/// Element XPointers name a boundary before text, not a character in the page.
/// Require the first following source character; text offsets remain exact.
enum ReaderContinuityPosition {
    static let visibleCharacter = """
        const X = await import('pocket-reader://engine/xpointer.js');
        const v = document.querySelector('foliate-view');
        const p = X.parse(pointer);
        if (!p) return false;
        const content = v.renderer.getContents().find(c => c.index === p.sectionIndex);
        if (!content) return false;
        const target = X.toRange(content.doc, p);
        if (!target.exact) return false;
        let node = target.range.startContainer, offset = target.range.startOffset;
        if (node.nodeType !== Node.TEXT_NODE) {
            const walker = content.doc.createTreeWalker(content.doc.body, NodeFilter.SHOW_TEXT);
            let found = false;
            while ((node = walker.nextNode())) {
                offset = node.data.search(/\\S/);
                if (offset >= 0 && target.range.comparePoint(node, offset) >= 0) { found = true; break; }
            }
            if (!found) return false;
        }
        return v.lastLocation.range.isPointInRange(node, offset);
        """
}
#endif
