import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// The app's surfaces and marks. Light mode is warm paper; dark mode is warm
/// charcoal, so the shelf and the reader's Night page belong to one product.
/// The reader page itself keeps its own themes (`ReaderAppearance.Theme`).
enum PocketPalette {
    /// Window background behind every destination.
    static let workspace = adaptive(light: (0.952, 0.946, 0.925), dark: (0.114, 0.112, 0.104))
    /// The studio's deeper stage behind the reader preview.
    static let stage = adaptive(light: (0.925, 0.918, 0.888), dark: (0.086, 0.084, 0.078))
    /// Raised panels: sidebar, continue-reading card, preview frame.
    static let panel = adaptive(light: (0.977, 0.973, 0.956), dark: (0.165, 0.162, 0.152))
    /// Translucent cards on the workspace.
    static let card = adaptive(light: (1, 1, 1, 0.72), dark: (1, 1, 1, 0.055))
    /// Text-strength ink for marks and dots.
    static let ink = adaptive(light: (0.105, 0.12, 0.115), dark: (0.905, 0.9, 0.87))
    /// Hairlines around cards and rows.
    static let line = adaptive(light: (0, 0, 0, 0.11), dark: (1, 1, 1, 0.12))
    /// The brand's amber: selection, progress, primary actions.
    static let accent = adaptive(light: (0.78, 0.46, 0.12), dark: (0.89, 0.6, 0.27))
    /// A connected reader.
    static let signal = adaptive(light: (0.22, 0.58, 0.38), dark: (0.38, 0.73, 0.52))
    static let selection = accent.opacity(0.15)

    /// Placeholder book covers, when the EPUB brings none.
    static let coverTop = adaptive(light: (0.955, 0.945, 0.905), dark: (0.31, 0.3, 0.28))
    static let coverBottom = adaptive(light: (0.885, 0.87, 0.815), dark: (0.225, 0.218, 0.2))

    /// The reader's chassis and the sidebar mark stay dark in both modes.
    static let paper = Color(red: 0.94, green: 0.93, blue: 0.86)
    static let deviceTop = Color(red: 0.105, green: 0.125, blue: 0.12)
    static let deviceBottom = Color(red: 0.055, green: 0.065, blue: 0.062)

    private typealias RGB = (Double, Double, Double)
    private typealias RGBA = (Double, Double, Double, Double)

    private static func adaptive(light: RGB, dark: RGB) -> Color {
        adaptive(light: (light.0, light.1, light.2, 1), dark: (dark.0, dark.1, dark.2, 1))
    }

    private static func adaptive(light: RGBA, dark: RGBA) -> Color {
#if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: value.0, green: value.1, blue: value.2, alpha: value.3)
        })
#else
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(srgbRed: value.0, green: value.1, blue: value.2, alpha: value.3)
        })
#endif
    }
}

/// A thin capsule bar that looks the same on iOS and macOS, where the system
/// indicator ignores `tint` and nearly vanishes on the paper background.
struct PocketBarProgressStyle: ProgressViewStyle {
    var tint: Color = PocketPalette.accent

    func makeBody(configuration: Configuration) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(PocketPalette.ink.opacity(0.10))
                Capsule().fill(tint)
                    .frame(width: max(5, proxy.size.width * CGFloat(configuration.fractionCompleted ?? 0)))
            }
        }
        .frame(height: 5)
    }
}

extension ProgressViewStyle where Self == PocketBarProgressStyle {
    static var pocketBar: PocketBarProgressStyle { PocketBarProgressStyle() }
    static func pocketBar(tint: Color) -> PocketBarProgressStyle { PocketBarProgressStyle(tint: tint) }
}

/// App chrome follows the system by default; book pages keep their own theme.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

struct AppAppearancePicker: View {
    @AppStorage("appAppearance") private var appearance = AppAppearance.system

    var body: some View {
        Picker("Appearance", selection: $appearance) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("app-appearance")
    }
}
