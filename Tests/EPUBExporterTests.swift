import Foundation
import XCTest
@testable import Pocket

final class EPUBExporterTests: XCTestCase {
    private var directory: URL = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func book(_ text: String = "한글과 English 👩🏽‍💻 & <tags> aren't markup.") -> EPUBDocument {
        EPUBDocument(title: "오늘 & Tomorrow", language: "ko", author: "작가 <A>", chapters: [
            .init(title: "첫 기사", paragraphs: [text], sourceURL: URL(string: "https://example.org/article?a=1&b=2")),
            .init(title: "Second", paragraphs: ["Second article.", "Last paragraph."])
        ], identifier: UUID(uuid: (0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15)),
                     modified: Date(timeIntervalSince1970: 1_790_380_800))
    }

    func testPackageHasConsistentManifestSpineAndBothTablesOfContents() throws {
        let url = try EPUBExporter.build(book(), to: directory)
        XCTAssertEqual(url.pathExtension, "epub")
        let entries = try ZIPInspection.read(url)
        XCTAssertEqual(entries.map(\.name), ["mimetype", "META-INF/container.xml", "EPUB/section-1.xhtml",
                                            "EPUB/section-2.xhtml", "EPUB/nav.xhtml", "EPUB/toc.ncx", "EPUB/package.opf"])
        XCTAssertEqual(String(decoding: entries[0].data, as: UTF8.self), "application/epub+zip")
        let xml = try entries.dropFirst().map { try XMLInspection($0.data) }
        XCTAssertEqual(xml[0].attributes("rootfile", "full-path"), ["EPUB/package.opf"])
        let opf = try XCTUnwrap(xml.last)
        XCTAssertEqual(opf.attributes("package", "version"), ["3.0"])
        XCTAssertEqual(opf.attributes("package", "unique-identifier"), ["book-id"])
        XCTAssertEqual(opf.attributes("spine", "toc"), ["ncx"])
        let manifest = opf.elements.filter { $0.name == "item" }
        let spine = opf.attributes("itemref", "idref")
        XCTAssertEqual(spine.count, 2)
        let spinePaths = try spine.map { id in
            "EPUB/" + (try XCTUnwrap(manifest.first { $0.attributes["id"] == id }?.attributes["href"]))
        }
        XCTAssertEqual(spinePaths, ["EPUB/section-1.xhtml", "EPUB/section-2.xhtml"])
        for item in manifest {
            XCTAssertTrue(entries.contains { $0.name == "EPUB/" + (item.attributes["href"] ?? "") })
        }
        XCTAssertEqual(xml[3].attributes("nav", "epub:type"), ["toc"])
        XCTAssertEqual(xml[3].attributes("a", "href"), ["section-1.xhtml", "section-2.xhtml"])
        XCTAssertEqual(xml[4].attributes("content", "src"), ["section-1.xhtml", "section-2.xhtml"])
        XCTAssertEqual(xml[4].attributes("navPoint", "playOrder"), ["1", "2"])
        XCTAssertEqual(opf.text("dc:title"), [book().title])
        XCTAssertEqual(opf.text("dc:creator"), ["작가 <A>"])
        XCTAssertEqual(opf.text("dc:language"), ["ko"])
    }

    func testTextIsEscapedAndLineBreaksArePreserved() throws {
        let input = "<script>alert('no')</script> & \"quoted\"\r\n줄 2\r줄 3\n끝"
        var document = book(input)
        document.chapters[0].sourceURL = nil
        let entries = try ZIPInspection.read(EPUBExporter.build(document, to: directory))
        let xml = try XMLInspection(entries[2].data)
        XCTAssertEqual(xml.text("p"), [input.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")])
        XCTAssertFalse(xml.elements.contains { $0.name == "script" })
        XCTAssertEqual(xml.elements.filter { $0.name == "br" }.count, 3)
    }

    func testLongParagraphSplitsWithoutLosingUnicodeOrExceedingByteBudget() throws {
        let text = String(repeating: "가👩🏽‍💻e\u{301}&<>", count: 6000)
        var document = book(text)
        document.chapters = [document.chapters[0]]
        document.chapters[0].sourceURL = nil
        let entries = try ZIPInspection.read(EPUBExporter.build(document, to: directory))
        let sections = entries.filter { $0.name.hasPrefix("EPUB/section-") }
        XCTAssertGreaterThan(sections.count, 2)
        var reconstructed = ""
        for section in sections {
            XCTAssertLessThanOrEqual(section.data.count, EPUBExporter.maximumSectionBytes)
            let xml = try XMLInspection(section.data)
            reconstructed += xml.text("p").joined()
            let allowedCharacters = Set("가👩🏽‍💻e\u{301}&<>")
            for paragraph in xml.text("p") { XCTAssertTrue(paragraph.allSatisfy { allowedCharacters.contains($0) }) }
        }
        XCTAssertEqual(reconstructed, text)
        let nav = try XMLInspection(XCTUnwrap(entries.first { $0.name == "EPUB/nav.xhtml" }).data)
        XCTAssertEqual(nav.attributes("a", "href").count, sections.count)
    }

    func testParagraphsMoveTogetherWhenTheyFitAndExactBoundaryIsAllowed() throws {
        var document = book("x")
        document.chapters = [.init(title: "One", paragraphs: ["x"])]
        let baseline = try ZIPInspection.read(EPUBExporter.build(document, to: directory))[2].data.count
        let capacity = EPUBExporter.maximumSectionBytes - baseline + 1
        document.chapters[0].paragraphs = [String(repeating: "a", count: capacity), "after"]
        let sections = try ZIPInspection.read(EPUBExporter.build(document, to: directory))
            .filter { $0.name.hasPrefix("EPUB/section-") }
        XCTAssertEqual(sections.count, 2)
        XCTAssertEqual(sections[0].data.count, EPUBExporter.maximumSectionBytes)
        XCTAssertEqual(try XMLInspection(sections[1].data).text("p"), ["after"])
    }

    func testReproducibleArchiveAndUniqueOutputFolders() throws {
        let first = try EPUBExporter.build(book(), to: directory)
        let second = try EPUBExporter.build(book(), to: directory)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: second))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: first.deletingLastPathComponent().path), [first.lastPathComponent])
    }

    func testFilenameCannotEscapeFolderAndSeparatesBooksWithSameTitle() throws {
        var document = book()
        document.title = "../../folder\\name: <book>"
        let first = try EPUBExporter.build(document, to: directory)
        document.identifier = UUID()
        let second = try EPUBExporter.build(document, to: directory)
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
        XCTAssertFalse(first.lastPathComponent.contains(".."))
        XCTAssertFalse(first.lastPathComponent.contains("\\"))
        XCTAssertEqual(first.deletingLastPathComponent().deletingLastPathComponent().path, directory.path)
        document.title = String(repeating: "가", count: 85)
        let unicode = try EPUBExporter.build(document, to: directory)
        XCTAssertLessThanOrEqual(unicode.lastPathComponent.utf8.count, 162)
    }

    func testRejectsEmptyMalformedAndExcessiveInputsWithoutOutput() throws {
        var cases: [(EPUBDocument, EPUBExportError)] = []
        var document = book()
        document.title = " \n"
        cases.append((document, .emptyContent))
        document = book(); document.chapters = []
        cases.append((document, .emptyContent))
        document = book(); document.chapters[0].paragraphs = [" \t\n"]
        cases.append((document, .emptyContent))
        document = book("bad\u{0}text")
        cases.append((document, .invalidText))
        document = book(); document.language = "ko\" x=\"y"
        cases.append((document, .invalidMetadata))
        document = book(); document.language = "en-a"
        cases.append((document, .invalidMetadata))
        document = book(); document.language = "en\n"
        cases.append((document, .invalidMetadata))
        document = book(); document.title = String(repeating: "한", count: 86)
        cases.append((document, .invalidMetadata))
        document = book(); document.modified = Date(timeIntervalSince1970: .infinity)
        cases.append((document, .invalidMetadata))
        document = book(); document.chapters[0].sourceURL = URL(string: "file:///etc/passwd")
        cases.append((document, .invalidSourceURL))
        document = book(); document.chapters[0].sourceURL = URL(string: "https://user:secret@example.org")
        cases.append((document, .invalidSourceURL))
        document = book(String(repeating: "a", count: EPUBExporter.maximumInputBytes + 1))
        cases.append((document, .inputTooLarge))
        document = book(); document.chapters = Array(repeating: document.chapters[0], count: EPUBExporter.maximumSections + 1)
        cases.append((document, .tooManySections))
        for (input, expected) in cases {
            XCTAssertThrowsError(try EPUBExporter.build(input, to: directory)) { XCTAssertEqual($0 as? EPUBExportError, expected) }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testFailureDuringSplittingCleansPartialArchiveAndPreservesOtherFiles() throws {
        let marker = directory.appendingPathComponent("existing.txt")
        try Data("keep".utf8).write(to: marker)
        // One extended grapheme cannot be split, even if it contains many combining scalars.
        let text = "a" + String(repeating: "\u{301}", count: EPUBExporter.maximumSectionBytes)
        XCTAssertThrowsError(try EPUBExporter.build(book(text), to: directory)) {
            XCTAssertEqual($0 as? EPUBExportError, .unsplittableCharacter)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.txt"])
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
    }

    func testSectionLimitAfterExpansionCleansPartialOutput() throws {
        var document = book()
        document.chapters = Array(repeating: .init(title: "One", paragraphs: [String(repeating: "&", count: 20_000)]),
                                  count: EPUBExporter.maximumSections)
        XCTAssertThrowsError(try EPUBExporter.build(document, to: directory)) {
            XCTAssertEqual($0 as? EPUBExportError, .tooManySections)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testAsyncAPIAndCancellationBeforeWork() async throws {
        let url = try await EPUBExporter.write(book(), to: directory)
        XCTAssertFalse(try ZIPInspection.read(url).isEmpty)
        let input = book()
        let target = directory.appendingPathComponent("cancelled")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EPUBExporter.write(input, to: target)
        }
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testCancellationDuringExportRemovesPartialOutput() async throws {
        var document = book()
        document.chapters = Array(repeating: .init(title: "One", paragraphs: [String(repeating: "&", count: 20_000)]), count: 100)
        let input = document
        let target = directory.appendingPathComponent("in-flight")
        let task = Task { try await EPUBExporter.write(input, to: target) }
        // Wait for the worker to create its owned folder (not a race with preflight validation).
        var observedOutput = false
        for _ in 0..<2000 {
            if FileManager.default.fileExists(atPath: target.path),
               !(try FileManager.default.contentsOfDirectory(atPath: target.path)).isEmpty {
                observedOutput = true
                break
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { }
        XCTAssertTrue(observedOutput)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
    }

    func testNavigationBudgetFailureAlsoRemovesPartialOutput() throws {
        var document = book()
        document.chapters = Array(repeating: .init(title: String(repeating: "&", count: 256), paragraphs: ["Body"]), count: 100)
        XCTAssertThrowsError(try EPUBExporter.build(document, to: directory)) {
            XCTAssertEqual($0 as? EPUBExportError, .navigationTooLarge)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testInvalidDestinationAndWriteFailurePreserveExistingFile() throws {
        let remote = try XCTUnwrap(URL(string: "https://example.org/output"))
        XCTAssertThrowsError(try EPUBExporter.build(book(), to: remote)) {
            XCTAssertEqual($0 as? EPUBExportError, .invalidDestination)
        }
        let file = directory.appendingPathComponent("not-a-folder")
        try Data("keep".utf8).write(to: file)
        XCTAssertThrowsError(try EPUBExporter.build(book(), to: file))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "keep")
    }
}

/// Independent central-directory inspection, with local-header consistency and a bitwise CRC oracle.
private enum ZIPInspection {
    struct Entry { let name: String; let data: Data }
    static func read(_ url: URL) throws -> [Entry] {
        let bytes = [UInt8](try Data(contentsOf: url))
        func uint(_ offset: Int, _ length: Int) throws -> Int {
            guard offset >= 0, offset + length <= bytes.count else { throw CocoaError(.fileReadCorruptFile) }
            return (0..<length).reduce(0) { $0 | (Int(bytes[offset + $1]) << ($1 * 8)) }
        }
        let end = bytes.count - 22
        XCTAssertEqual(try uint(end, 4), 0x06054b50)
        let count = try uint(end + 10, 2)
        var cursor = try uint(end + 16, 4)
        XCTAssertEqual(cursor + (try uint(end + 12, 4)), end)
        var result: [Entry] = []
        var expectedLocal = 0
        for _ in 0..<count {
            XCTAssertEqual(try uint(cursor, 4), 0x02014b50)
            XCTAssertEqual(try uint(cursor + 10, 2), 0)
            let size = try uint(cursor + 24, 4)
            XCTAssertEqual(try uint(cursor + 20, 4), size)
            let nameLength = try uint(cursor + 28, 2)
            let local = try uint(cursor + 42, 4)
            XCTAssertEqual(local, expectedLocal)
            XCTAssertEqual(try uint(local, 4), 0x04034b50)
            XCTAssertEqual(try uint(local + 6, 2), 0)
            XCTAssertEqual(try uint(local + 8, 2), 0)
            XCTAssertEqual(try uint(local + 18, 4), size)
            XCTAssertEqual(try uint(local + 22, 4), size)
            XCTAssertEqual(try uint(local + 26, 2), nameLength)
            XCTAssertEqual(try uint(local + 28, 2), 0)
            let dataStart = local + 30 + nameLength
            guard cursor + 46 + nameLength <= bytes.count, dataStart + size <= bytes.count else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)
            XCTAssertEqual(String(decoding: bytes[(local + 30)..<dataStart], as: UTF8.self), name)
            let data = Data(bytes[dataStart..<(dataStart + size)])
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in data {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xEDB8_8320) }
            }
            XCTAssertEqual(try uint(cursor + 16, 4), Int(crc ^ 0xFFFF_FFFF))
            XCTAssertEqual(try uint(local + 14, 4), Int(crc ^ 0xFFFF_FFFF))
            result.append(Entry(name: name, data: data))
            expectedLocal = dataStart + size
            cursor += 46 + nameLength + (try uint(cursor + 30, 2)) + (try uint(cursor + 32, 2))
        }
        XCTAssertEqual(expectedLocal, try uint(end + 16, 4))
        XCTAssertEqual(cursor, end)
        return result
    }
}

private final class XMLInspection: NSObject, XMLParserDelegate {
    struct Element { let name: String; let attributes: [String: String]; var text = "" }
    var elements: [Element] = []
    private var stack: [Int] = []
    init(_ data: Data) throws {
        super.init()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = self
        guard parser.parse() else { throw parser.parserError ?? CocoaError(.fileReadCorruptFile) }
    }
    func attributes(_ name: String, _ key: String) -> [String] {
        elements.filter { $0.name == name }.compactMap { $0.attributes[key] }
    }
    func text(_ name: String) -> [String] { elements.filter { $0.name == name }.map(\.text) }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "br" { for index in stack { elements[index].text += "\n" } }
        stack.append(elements.count)
        elements.append(Element(name: elementName, attributes: attributeDict))
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        for index in stack { elements[index].text += string }
    }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        stack.removeLast()
    }
}
