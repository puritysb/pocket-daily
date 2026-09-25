import CoreImage
import XCTest
@testable import Pocket

/// Card images the companion makes: QR codes from text or links, images fetched
/// from a link, and text documents to read.
final class CardImageSourcesTests: XCTestCase {
    /// Decodes a 1-bit PBM back into text with the system QR detector.
    private func decodeQR(_ pbm: Data) throws -> String? {
        let image = try ContentImage.decode(pbm)
        let rowBytes = (image.width + 7) / 8
        var gray = [UInt8](repeating: 255, count: image.width * image.height)
        let raster = [UInt8](image.encoded().suffix(rowBytes * image.height))
        for y in 0..<image.height {
            for x in 0..<image.width where raster[y * rowBytes + x / 8] & (0x80 >> (x % 8)) != 0 {
                gray[y * image.width + x] = 0
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: Data(gray) as CFData))
        let cgImage = try XCTUnwrap(CGImage(width: image.width, height: image.height, bitsPerComponent: 8,
                                            bitsPerPixel: 8, bytesPerRow: image.width,
                                            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                                            provider: provider, decode: nil, shouldInterpolate: false,
                                            intent: .defaultIntent))
        let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                                  options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
        let features = detector?.features(in: CIImage(cgImage: cgImage)) ?? []
        return (features.first as? CIQRCodeFeature)?.messageString
    }

    func testQRCodesScanBackAndStayWithinTheReaderLimits() throws {
        for text in ["https://puritysb.github.io/pocket-daily/", "WIFI:T:WPA;S:Home;P:correct horse;;",
                     "이 리더를 찾으면 010-0000-0000으로 연락 주세요"] {
            let qr = try ContentQRCode.image(for: text)
            let image = try ContentImage.decode(qr.data)
            XCTAssertEqual(image.width, image.height)
            XCTAssertLessThanOrEqual(image.width, ContentQRCode.targetPixels)
            XCTAssertGreaterThanOrEqual(image.width, 120, "Large enough to scan on e-paper")
            XCTAssertTrue(ContentManifest.validPath(qr.path, kind: .monoImage))
            XCTAssertEqual(try decodeQR(qr.data), text)
        }
        XCTAssertThrowsError(try ContentQRCode.image(for: "  ")) {
            XCTAssertEqual($0 as? ContentQRCode.Failure, .empty)
        }
        XCTAssertThrowsError(try ContentQRCode.image(for: String(repeating: "a", count: ContentQRCode.maximumBytes + 1))) {
            XCTAssertEqual($0 as? ContentQRCode.Failure, .tooLong)
        }
        // Deterministic: the same text gives the same file and path.
        XCTAssertEqual(try ContentQRCode.image(for: "same").data, try ContentQRCode.image(for: "same").data)
    }

    func testImageLinksMustBeHTTPSImages() async throws {
        do {
            _ = try await ContentImageImport.load(remote: URL(string: "http://example.com/qr.png")!)
            XCTFail("Plain HTTP must be refused")
        } catch let failure as ContentImageImport.RemoteFailure {
            XCTAssertEqual(failure, .scheme)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ImageLinkURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let qr = try ContentQRCode.image(for: "https://example.com")
        ImageLinkURLProtocol.reply = (200, "image/x-portable-bitmap", qr.data)
        let fetched = try await ContentImageImport.load(remote: URL(string: "https://qr.example/code")!, session: session)
        XCTAssertEqual(fetched.data, qr.data)
        ImageLinkURLProtocol.reply = (200, "text/html", Data("<html></html>".utf8))
        do {
            _ = try await ContentImageImport.load(remote: URL(string: "https://qr.example/page")!, session: session)
            XCTFail("A web page is not an image")
        } catch let failure as ContentImageImport.RemoteFailure {
            XCTAssertEqual(failure, .notImage)
        }
        ImageLinkURLProtocol.reply = (404, "image/png", Data())
        do {
            _ = try await ContentImageImport.load(remote: URL(string: "https://qr.example/missing")!, session: session)
            XCTFail("An error status must fail")
        } catch let failure as ContentImageImport.RemoteFailure {
            XCTAssertEqual(failure, .status(404))
        }
    }

    func testTextDocumentsHaveReaderSafeNamesAndKeepTheText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertEqual(TextDocument.filename(for: "Meeting notes: 9/25"), "Meeting notes 9 25.txt")
        XCTAssertEqual(TextDocument.filename(for: "  오늘의 기록  "), "오늘의 기록.txt")
        XCTAssertTrue(TextDocument.filename(for: "///").hasPrefix("Note "))
        let url = try TextDocument.write(title: "Reading list", text: "\nOne\nTwo\n", directory: directory)
        XCTAssertEqual(url.lastPathComponent, "Reading list.txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Reading list\n\nOne\nTwo\n")
        XCTAssertThrowsError(try TextDocument.write(title: "x", text: " \n ", directory: directory)) {
            XCTAssertEqual($0 as? TextDocument.Failure, .empty)
        }
    }
}

private final class ImageLinkURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var reply: (status: Int, type: String, body: Data) = (200, "image/png", Data())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: Self.reply.status, httpVersion: nil,
                                             headerFields: ["Content-Type": Self.reply.type]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
