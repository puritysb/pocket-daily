import SwiftUI

/// Reading look shared by every book. Defaults aim at a paper-like page with
/// instant page turns, like the reader hardware.
struct ReaderAppearance: Codable, Equatable, Sendable {
    enum Theme: String, Codable, CaseIterable, Identifiable, Sendable {
        case paper, white, night
        var id: String { rawValue }
        var title: String {
            switch self {
            case .paper: "Paper"
            case .white: "White"
            case .night: "Night"
            }
        }
        var background: Color {
            switch self {
            case .paper: Color(red: 0.957, green: 0.945, blue: 0.918)
            case .white: .white
            case .night: Color(white: 0.067)
            }
        }
        var foreground: Color {
            switch self {
            case .paper: Color(white: 0.106)
            case .white: .black
            case .night: Color(white: 0.84)
            }
        }
        var colorScheme: ColorScheme { self == .night ? .dark : .light }
    }

    enum FontFamily: String, Codable, CaseIterable, Identifiable, Sendable {
        case publisher, serif, sans
        var id: String { rawValue }
        var title: String {
            switch self {
            case .publisher: "Book"
            case .serif: "Serif"
            case .sans: "Sans"
            }
        }
    }

    enum Margin: String, Codable, CaseIterable, Identifiable, Sendable {
        case narrow, normal, wide
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
        var points: Int {
            switch self {
            case .narrow: 16
            case .normal: 28
            case .wide: 44
            }
        }
        /// Column gap as a percentage of the page, which sets the side margins.
        var gap: Int {
            switch self {
            case .narrow: 4
            case .normal: 7
            case .wide: 12
            }
        }
    }

    static let fontScales = [80, 90, 100, 110, 120, 135, 150, 170, 200]
    static let lineHeights = [1.3, 1.45, 1.6, 1.8, 2.0]

    var theme: Theme = .paper
    var fontScale = 100
    var lineHeight = 1.6
    var fontFamily: FontFamily = .publisher
    var justify = true
    var hyphenate = true
    var margin: Margin = .normal
    /// Two columns only when the page is wide enough (iPad landscape, Mac).
    var allowsTwoColumns = true

    func script(insetTop: Double, insetBottom: Double) -> [String: Any] {
        [
            "theme": theme.rawValue,
            "fontScale": fontScale,
            "lineHeight": lineHeight,
            "fontFamily": fontFamily.rawValue,
            "justify": justify,
            "hyphenate": hyphenate,
            "margin": margin.points,
            "gap": margin.gap,
            "maxInlineSize": 720,
            "columns": allowsTwoColumns ? 2 : 1,
            "insetTop": insetTop,
            "insetBottom": insetBottom,
        ]
    }

    mutating func stepFont(_ direction: Int) {
        let index = Self.fontScales.firstIndex(of: fontScale) ?? Self.fontScales.firstIndex(of: 100)!
        fontScale = Self.fontScales[min(max(index + direction, 0), Self.fontScales.count - 1)]
    }
}

@MainActor
final class ReaderAppearanceStore: ObservableObject {
    static let shared = ReaderAppearanceStore()
    private static let key = "reader.appearance.v1"
    private let defaults: UserDefaults

    @Published var appearance: ReaderAppearance {
        didSet {
            if let data = try? JSONEncoder().encode(appearance) { defaults.set(data, forKey: Self.key) }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(ReaderAppearance.self, from: $0) } ?? ReaderAppearance()
    }
}
