import CoreGraphics
import CryptoKit
import Foundation
import ImageIO

enum ContentImageImport {
    static let maximumFileBytes = 20 * 1024 * 1024
    enum Failure: LocalizedError {
        case size, format, dimensions, decode
        var errorDescription: String? {
            switch self {
            case .size: "Choose an image smaller than 20 MB."
            case .format: "Choose a single still image, such as PNG, JPEG or HEIC."
            case .dimensions: "This image's dimensions are unsupported. Choose a smaller image."
            case .decode: "The image could not be decoded. Try exporting it as PNG or JPEG."
            }
        }
    }

    struct Imported: Sendable {
        let path: String
        let data: Data
        let width: Int
        let height: Int
    }

    /// File access and decoding stay off the main actor. No source mutation,
    /// draft save or network operation. Cancellation discards the result.
    static func load(_ url: URL) async throws -> Imported {
        try Task.checkCancellation()
        let imported = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: maximumFileBytes + 1) ?? Data()
            return try convert(bytes)
        }.value
        try Task.checkCancellation()
        return imported
    }

    enum RemoteFailure: LocalizedError, Equatable {
        case scheme, notImage, status(Int)
        var errorDescription: String? {
            switch self {
            case .scheme: "Enter an https:// link to an image."
            case .notImage: "That link returns a web page or other file, not an image. Use a link that opens the image itself."
            case let .status(code): "The link could not be loaded (HTTP \(code))."
            }
        }
    }

    /// Fetches one image the user linked (for example a QR code a service
    /// generates) and converts it like a chosen file. HTTPS only, no cookies
    /// or cache, bounded to the same 20 MB.
    static func load(remote url: URL, session: URLSession = .init(configuration: .ephemeral)) async throws -> Imported {
        guard url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { throw RemoteFailure.scheme }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        let (bytes, response) = try await session.data(for: request)
        try Task.checkCancellation()
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RemoteFailure.status(http.statusCode)
        }
        guard bytes.count <= maximumFileBytes else { throw Failure.size }
        if let type = response.mimeType?.lowercased(), !type.hasPrefix("image/"), type != "application/octet-stream" {
            throw RemoteFailure.notImage
        }
        return try await Task.detached(priority: .userInitiated) {
            do { return try convert(bytes) } catch Failure.format { throw RemoteFailure.notImage }
        }.value
    }

    /// ImageIO applies EXIF orientation while producing a <=512px thumbnail.
    /// We never request a full-resolution decoded source image. SDK-internal
    /// codec memory is not covered by the app's bounded RGBA scratch size.
    static func convert(_ bytes: Data) throws -> Imported {
        guard !bytes.isEmpty, bytes.count <= maximumFileBytes else { throw Failure.size }
        // Canonical PBM can be imported without a lossy decoding round-trip.
        if bytes.starts(with: [80, 52, 10]) { return try imported(ContentImage.decode(bytes)) }
        guard let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1 else { throw Failure.format }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
              (1...32768).contains(width.intValue), (1...32768).contains(height.intValue),
              width.int64Value * height.int64Value <= 100_000_000 else { throw Failure.dimensions }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              (1...512).contains(image.width), (1...512).contains(image.height) else { throw Failure.decode }
        var rgba = Data(repeating: 255, count: image.width * image.height * 4)
        let drawn = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                          bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue |
                                            CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            // Initialized opaque white: transparent source pixels stay white.
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        guard drawn else { throw Failure.decode }
        return try imported(monochrome(width: image.width, height: image.height, opaqueRGBA: rgba))
    }

    static func monochrome(width: Int, height: Int, opaqueRGBA: Data) throws -> ContentImage {
        guard (1...512).contains(width), (1...512).contains(height), opaqueRGBA.count == width * height * 4 else {
            throw Failure.dimensions
        }
        let rowBytes = (width + 7) / 8
        var raster = Data(repeating: 0, count: rowBytes * height)
        for y in 0..<height {
            for x in 0..<width {
                let offset = opaqueRGBA.startIndex + (y * width + x) * 4
                let luminance = (299 * Int(opaqueRGBA[offset]) + 587 * Int(opaqueRGBA[offset + 1]) +
                                 114 * Int(opaqueRGBA[offset + 2]) + 500) / 1000
                if luminance < 128 { raster[y * rowBytes + x / 8] |= 0x80 >> (x % 8) }
            }
        }
        return try ContentImage(width: width, height: height, raster: raster)
    }

    static func imported(_ image: ContentImage) throws -> Imported {
        let data = image.encoded()
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Imported(path: "image-" + hash.prefix(48) + ".pbm", data: data, width: image.width, height: image.height)
    }
}
