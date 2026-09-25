import CoreGraphics
import Foundation
import PocketUIHost

/// Local-only production renderer. Actor isolation keeps native context lifetime
/// and readback serialized off the main actor. It never owns a reader session.
actor HostRendererBridge {
    enum Orientation: UInt32, CaseIterable, Sendable {
        case portrait, clockwise, inverted, counterclockwise
    }

    struct Options: Sendable, Equatable {
        var sidePadding: Int32
        var topPadding: Int32
        var spacing: Int32
        var emptyTitle: String
        var emptyMessage: String
        var labels: [String]
    }

    struct Frame: Sendable {
        let physicalWidth: Int
        let physicalHeight: Int
        let width: Int
        let height: Int
        let orientation: Orientation
        let pixels: Data

        /// Convert the native physical bit order to the logical preview canvas.
        /// This changes presentation coordinates, not the renderer's pixels.
        func image() -> CGImage? {
            let rotated = orientation == .portrait || orientation == .inverted
            guard (1...2048).contains(physicalWidth), physicalWidth % 8 == 0,
                  (1...2048).contains(physicalHeight),
                  width == (rotated ? physicalHeight : physicalWidth),
                  height == (rotated ? physicalWidth : physicalHeight),
                  pixels.count == physicalWidth / 8 * physicalHeight else { return nil }
            var grayscale = Data(repeating: 255, count: width * height)
            let rowBytes = physicalWidth / 8
            for y in 0..<height {
                for x in 0..<width {
                    let px: Int
                    let py: Int
                    switch orientation {
                    case .portrait: (px, py) = (y, physicalHeight - 1 - x)
                    case .clockwise: (px, py) = (physicalWidth - 1 - x, physicalHeight - 1 - y)
                    case .inverted: (px, py) = (physicalWidth - 1 - y, x)
                    case .counterclockwise: (px, py) = (x, y)
                    }
                    if pixels[pixels.startIndex + py * rowBytes + px / 8] & (0x80 >> (px % 8)) == 0 {
                        grayscale[y * width + x] = 0
                    }
                }
            }
            guard let provider = CGDataProvider(data: grayscale as CFData) else { return nil }
            return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                           bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: [],
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }

    enum Failure: LocalizedError, Equatable {
        case unavailable, invalidFont, invalidOptions, render(Int32), invalidFrame
        var errorDescription: String? {
            switch self {
            case .unavailable: "The verified preview renderer is unavailable. Rebuild with the accepted renderer package."
            case .invalidFont: "The preview font is missing, incompatible, or could not be loaded."
            case .invalidOptions: "The preview labels or layout options are invalid."
            case .render: "The reader renderer could not draw this content. No preview was updated."
            case .invalidFrame: "The renderer returned an incompatible preview frame."
            }
        }
    }

    struct Identity: Decodable, Equatable, Sendable {
        let schema: Int
        let abi: UInt32
        let sourceSHA256: String
        let artifactSHA256: String

        static func accepted(in bundle: Bundle = .main) throws -> Identity {
            struct Provenance: Decodable {
                struct Source: Decodable { let sha256: String }
                let schema: Int
                let abi: UInt32
                let source: Source
                let artifactSHA256: String
            }
            do {
                guard let pinURL = bundle.url(forResource: "PIN", withExtension: "json"),
                      let recordURL = bundle.url(forResource: "PROVENANCE", withExtension: "json") else {
                    throw Failure.unavailable
                }
                let pin = try JSONDecoder().decode(Identity.self, from: Data(contentsOf: pinURL))
                let record = try JSONDecoder().decode(Provenance.self, from: Data(contentsOf: recordURL))
                let hashes = [pin.sourceSHA256, pin.artifactSHA256]
                guard pin.schema == 1, record.schema == 1, pin.abi == 1, pin.abi == record.abi,
                      pin.abi == pdui_abi_version(), pin.sourceSHA256 == record.source.sha256,
                      pin.artifactSHA256 == record.artifactSHA256,
                      hashes.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy {
                          (48...57).contains($0) || (97...102).contains($0)
                      } }) else { throw Failure.unavailable }
                return pin
            } catch { throw Failure.unavailable }
        }
    }

    private final class Context {
        let pointer: OpaquePointer
        init(_ pointer: OpaquePointer) { self.pointer = pointer }
        deinit { pdui_destroy(pointer) }
    }

    private var acceptedIdentity: Identity?
    private let bundle: Bundle
    private let hardware: PocketHardware
    private let orientation: Orientation
    private let font: Data
    private var context: Context?

    init(font: Data, hardware: PocketHardware, orientation: Orientation = .portrait,
         bundle: Bundle = .main) throws {
        guard !font.isEmpty, font.count <= 64 * 1024 * 1024 else { throw Failure.invalidFont }
        self.bundle = bundle
        self.font = font
        self.hardware = hardware
        self.orientation = orientation
    }

    private func nativeContext() throws -> Context {
        _ = try identity()
        if let context { return context }
        var pointer: OpaquePointer?
        // Device profiles report portrait geometry; the native framebuffer is
        // landscape (the same mapping used by the production renderer).
        let status = font.withUnsafeBytes { bytes in
            pdui_create(UInt32(hardware.screenHeight), UInt32(hardware.screenWidth), orientation.rawValue,
                        bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &pointer)
        }
        guard status == PDUI_OK, let pointer else { throw Failure.invalidFont }
        let created = Context(pointer)
        context = created
        return created
    }

    func identity() throws -> Identity {
        if let acceptedIdentity { return acceptedIdentity }
        let accepted = try Identity.accepted(in: bundle)
        acceptedIdentity = accepted
        return accepted
    }

    private func putText<T>(_ text: String, into field: inout T) throws {
        let bytes = Array(text.utf8) + [0]
        guard !text.utf8.contains(0), bytes.count <= MemoryLayout<T>.size else { throw Failure.invalidOptions }
        withUnsafeMutableBytes(of: &field) { output in
            output.initializeMemory(as: UInt8.self, repeating: 0)
            output.copyBytes(from: bytes)
        }
    }

    func render(card: ContentCard?, image: Data? = nil, options: Options) throws -> Frame {
        try Task.checkCancellation()
        guard options.labels.count == 4 else { throw Failure.invalidOptions }
        var native = pdui_content_options()
        native.side_padding = options.sidePadding
        native.top_padding = options.topPadding
        native.spacing = options.spacing
        try putText(options.emptyTitle, into: &native.empty_title)
        try putText(options.emptyMessage, into: &native.empty_message)
        try putText(options.labels[0], into: &native.labels.0)
        try putText(options.labels[1], into: &native.labels.1)
        try putText(options.labels[2], into: &native.labels.2)
        try putText(options.labels[3], into: &native.labels.3)
        let document = try card?.encoded() ?? Data()
        let image = image ?? Data()
        let context = try nativeContext()
        let status = document.withUnsafeBytes { cardBytes in
            image.withUnsafeBytes { imageBytes in
                pdui_render_content(context.pointer,
                                    document.isEmpty ? nil : cardBytes.bindMemory(to: UInt8.self).baseAddress,
                                    cardBytes.count,
                                    image.isEmpty ? nil : imageBytes.bindMemory(to: UInt8.self).baseAddress,
                                    imageBytes.count, &native)
            }
        }
        guard status == PDUI_OK else {
            self.context = nil // Drop sticky font failures; next explicit request can recreate.
            throw Failure.render(status)
        }
        try Task.checkCancellation()
        var info = pdui_frame_info()
        let expectedWidth = hardware.screenHeight
        let expectedHeight = hardware.screenWidth
        let rotated = orientation == .portrait || orientation == .inverted
        guard pdui_get_frame_info(context.pointer, &info) == PDUI_OK,
              info.physical_width == expectedWidth, info.physical_height == expectedHeight,
              info.row_bytes == expectedWidth / 8, info.byte_count == expectedWidth / 8 * expectedHeight,
              info.orientation == orientation.rawValue,
              info.logical_width == (rotated ? expectedHeight : expectedWidth),
              info.logical_height == (rotated ? expectedWidth : expectedHeight) else { throw Failure.invalidFrame }
        var pixels = Data(count: Int(info.byte_count))
        let copied = pixels.withUnsafeMutableBytes { bytes in
            pdui_copy_frame(context.pointer, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
        }
        guard copied == PDUI_OK else { throw Failure.invalidFrame }
        return Frame(physicalWidth: expectedWidth, physicalHeight: expectedHeight,
                     width: Int(info.logical_width), height: Int(info.logical_height),
                     orientation: orientation, pixels: pixels)
    }
}
