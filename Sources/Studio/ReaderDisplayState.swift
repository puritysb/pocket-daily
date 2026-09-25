import Foundation

/// The reader's resolved content-page render inputs (`GET /api/pocket/v1/display`,
/// sibling docs/pocket-profile-v1.md): theme metrics after any UI pack, the
/// reader's UI language and button remapping, orientation and installed font size.
/// Previews use these instead of assuming a reference theme.
struct ReaderDisplayState: Equatable, Sendable {
    struct ContentPage: Equatable, Sendable {
        let sidePadding: Int32
        let topPadding: Int32
        let spacing: Int32
        let title: String
        let empty: String
        let labels: [String]
    }

    let deviceID: String
    let theme: String
    let orientation: HostRendererBridge.Orientation
    let fontFamily: String
    let fontPointSize: Int
    let contentPage: ContentPage

    /// The bundled preview font. A reader with another installed size cannot be
    /// matched pixel for pixel, and the studio says so instead of pretending.
    static let previewFontPointSize = 12

    enum Failure: Error, Equatable { case malformed, identity, unsupportedSchema, outOfRange }

    private struct Wire: Decodable {
        struct Font: Decodable { let family: String; let pointSize: Int }
        struct Page: Decodable {
            let sidePadding: Int
            let topPadding: Int
            let spacing: Int
            let title: String
            let empty: String
            let labels: [String]
        }
        let schema: Int
        let deviceID: String
        let theme: String
        let orientation: Int
        let font: Font
        let contentPage: Page
    }

    /// Bounds follow the host renderer ABI (NUL-terminated 64/192/64-byte fields)
    /// so a validated state always renders without truncation.
    static func decode(_ data: Data, deviceID expected: String) throws -> ReaderDisplayState {
        guard data.count <= 2048, let wire = try? JSONDecoder().decode(Wire.self, from: data) else { throw Failure.malformed }
        guard wire.schema == 1 else { throw Failure.unsupportedSchema }
        guard wire.deviceID == expected else { throw Failure.identity }
        let page = wire.contentPage
        guard let orientation = HostRendererBridge.Orientation(rawValue: UInt32(clamping: wire.orientation)),
              (0...3).contains(wire.orientation),
              [page.sidePadding, page.topPadding, page.spacing].allSatisfy({ (0...200).contains($0) }),
              page.labels.count == 4, page.labels.allSatisfy({ $0.utf8.count < 64 }),
              page.title.utf8.count < 64, page.empty.utf8.count < 192,
              (0...255).contains(wire.font.pointSize), wire.font.family.utf8.count < 64 else { throw Failure.outOfRange }
        return .init(deviceID: wire.deviceID, theme: wire.theme, orientation: orientation,
                     fontFamily: wire.font.family, fontPointSize: wire.font.pointSize,
                     contentPage: .init(sidePadding: Int32(page.sidePadding), topPadding: Int32(page.topPadding),
                                        spacing: Int32(page.spacing), title: page.title, empty: page.empty,
                                        labels: page.labels))
    }

    var matchesPreviewFont: Bool { fontPointSize == Self.previewFontPointSize }
}

/// What a preview renders with, and where those inputs came from.
struct PreviewStyle: Equatable, Sendable {
    enum Source: Equatable, Sendable { case reader(theme: String, fontMatches: Bool), reference }

    let options: HostRendererBridge.Options
    let orientation: HostRendererBridge.Orientation?
    let source: Source

    /// Without a reader (demo, offline, older firmware): the default device
    /// theme (Lyra: 20/5/16) with English strings, labelled as a reference.
    static let reference = PreviewStyle(
        options: .init(sidePadding: 20, topPadding: 5, spacing: 16, emptyTitle: "Pocket",
                       emptyMessage: "Pocket is ready. Connect briefly to refresh.",
                       labels: ["Back", "", "Prev", "Next"]),
        orientation: nil, source: .reference)

    init(options: HostRendererBridge.Options, orientation: HostRendererBridge.Orientation?, source: Source) {
        self.options = options
        self.orientation = orientation
        self.source = source
    }

    init(reader: ReaderDisplayState) {
        let page = reader.contentPage
        self.init(options: .init(sidePadding: page.sidePadding, topPadding: page.topPadding, spacing: page.spacing,
                                 emptyTitle: page.title, emptyMessage: page.empty, labels: page.labels),
                  orientation: reader.orientation,
                  source: .reader(theme: reader.theme, fontMatches: reader.matchesPreviewFont))
    }

    var caption: String {
        switch source {
        case let .reader(theme, true): "Matches this reader · \(theme) theme"
        case let .reader(theme, false): "\(theme) theme · reader font size differs, line breaks may shift"
        case .reference: "Default theme · connect a reader to match it"
        }
    }
}
