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
    private let fallbackFont: Data?
    private var context: Context?

    /// `fallbackFont` is the reader's glyph-fallback font (emoji and symbols);
    /// by default the PocketSymbols font the app offers to install on the reader.
    init(font: Data, hardware: PocketHardware, orientation: Orientation = .portrait,
         fallbackFont: Data? = ReaderSymbolFont.bundledData, bundle: Bundle = .main) throws {
        guard !font.isEmpty, font.count <= 64 * 1024 * 1024 else { throw Failure.invalidFont }
        self.bundle = bundle
        self.font = font
        self.fallbackFont = fallbackFont
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
        if let fallbackFont, !fallbackFont.isEmpty {
            // Without it the preview still renders; only fallback glyphs are missing.
            let installed = fallbackFont.withUnsafeBytes { bytes in
                pdui_set_fallback_font(pointer, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
            }
            if installed != PDUI_OK { NSLog("Pocket preview fallback font was rejected (%d)", installed) }
        }
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
        return try copyFrame(context)
    }

    /// Sample content shown in Home / Daily Brief layout previews (PDUI_SAMPLE_*).
    struct LayoutSamples: OptionSet, Sendable, Hashable {
        let rawValue: UInt32
        static let book = LayoutSamples(rawValue: 1)
        static let study = LayoutSamples(rawValue: 2)
        static let provider = LayoutSamples(rawValue: 4)
        static let weather = LayoutSamples(rawValue: 8)
        static let events = LayoutSamples(rawValue: 16)
        static let usage = LayoutSamples(rawValue: 32)
        static let all: LayoutSamples = [.book, .study, .provider, .weather, .events, .usage]
    }

    /// The Pocket Daily Home face drawn by the firmware's own painter with
    /// representative sample content (sibling docs/pocket-profile-v1.md P1-3).
    /// `cards` are the user's own cards ("My cards"), shown instead of the
    /// sample study card; incomplete cards are skipped as they cannot be sent.
    func renderHome(profile: PocketProfile, cards: ContentDraft = .init(), samples: LayoutSamples = .all,
                    selected: Int = 0) throws -> Frame {
        try Task.checkCancellation()
        var native = try Self.nativeProfile(profile)
        let context = try nativeContext()
        try setCards(cards, on: context)
        let status = pdui_render_home(context.pointer, &native, samples.rawValue, UInt32(clamping: max(0, selected)))
        guard status == PDUI_OK else { throw Failure.render(status) }
        return try copyFrame(context)
    }

    /// The powered-off Daily Brief in the profile's section order.
    func renderBrief(profile: PocketProfile, cards: ContentDraft = .init(), samples: LayoutSamples = .all) throws -> Frame {
        try Task.checkCancellation()
        var native = try Self.nativeProfile(profile)
        let context = try nativeContext()
        try setCards(cards, on: context)
        let status = pdui_render_brief(context.pointer, &native, samples.rawValue)
        guard status == PDUI_OK else { throw Failure.render(status) }
        return try copyFrame(context)
    }

    /// Cards the reader could show: complete text and, when named, the image.
    static func previewCards(_ draft: ContentDraft) -> [(card: Data, image: Data?)] {
        draft.cards.prefix(3).compactMap { card in
            guard let bytes = try? card.encoded() else { return nil }
            if card.imagePath.isEmpty { return (bytes, nil) }
            guard let image = draft.images[card.imagePath] else { return nil }
            return (bytes, image)
        }
    }

    private func setCards(_ draft: ContentDraft, on context: Context) throws {
        let cards = Self.previewCards(draft)
        // Copies stay alive for the call; the renderer keeps its own.
        var buffers: [UnsafeMutableRawBufferPointer] = []
        defer { buffers.forEach { $0.deallocate() } }
        func copy(_ data: Data) -> UnsafePointer<UInt8> {
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: max(1, data.count), alignment: 1)
            data.copyBytes(to: buffer.bindMemory(to: UInt8.self))
            buffers.append(buffer)
            return UnsafePointer(buffer.baseAddress!.assumingMemoryBound(to: UInt8.self))
        }
        var inputs = cards.map { card in
            pdui_card_input(card: copy(card.card), card_size: card.card.count,
                            image: card.image.map(copy), image_size: card.image?.count ?? 0)
        }
        let status = inputs.withUnsafeMutableBufferPointer {
            pdui_set_cards(context.pointer, $0.baseAddress, UInt32($0.count))
        }
        guard status == PDUI_OK else { throw Failure.render(status) }
    }

    /// Same IDs as the firmware profile record (PocketProfile.h).
    static func nativeProfile(_ profile: PocketProfile) throws -> pdui_profile {
        guard profile.validationError == nil else { throw Failure.invalidOptions }
        let home: [UInt8] = profile.home.items.map {
            switch $0 { case .reading: 1; case .study: 2; case .provider: 3; case .monitor: 4; case .word: 5 }
        } + [0, 0, 0, 0]
        let sleep: [UInt8] = profile.sleep.sections.map {
            switch $0 { case .reading: 1; case .study: 2; case .weather: 3; case .today: 4; case .card: 5 }
        } + [0, 0, 0, 0]
        var native = pdui_profile()
        native.home_items = (home[0], home[1], home[2], home[3])
        native.home_count = UInt8(profile.home.items.count)
        native.daily_word = profile.home.dailyWord ? 1 : 0
        native.weather = switch profile.home.weather { case .bottom: 0; case .top: 1; case .off: 2 }
        native.next_event = profile.home.nextEvent ? 1 : 0
        native.sleep_mode = profile.sleep.mode == .brief ? 0 : 1
        native.sleep_sections = (sleep[0], sleep[1], sleep[2], sleep[3])
        native.sleep_count = UInt8(profile.sleep.sections.count)
        return native
    }

    private func copyFrame(_ context: Context) throws -> Frame {
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
