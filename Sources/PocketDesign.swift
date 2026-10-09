import SwiftUI

/// Shared chrome metrics. Book pages and reader-device renderings have their
/// own typography; these values belong to the surrounding app interface.
enum PocketDesign {
    static let contentWidth: CGFloat = 1100
    static let pageInset: CGFloat = 20
    static let compactInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let cardInset: CGFloat = 16
    static let cardRadius: CGFloat = 12
    static let controlRadius: CGFloat = 8
    static let sidebarWidth: CGFloat = 208

    /// Width from which the sidebar replaces tabs (never at accessibility
    /// text sizes).
    static let wideLayoutWidth: CGFloat = 920
    /// Width from which an editor places its preview beside the controls.
    static let splitLayoutWidth: CGFloat = 680
    /// Below this height a one-column editor shrinks its preview and keeps
    /// only the status line and actions in its apply bar.
    static let condensedEditorHeight: CGFloat = 430

    static var pageTitle: Font {
#if os(macOS)
        .system(size: 22, weight: .semibold)
#else
        .title2.weight(.semibold)
#endif
    }

    static var actionTarget: CGFloat {
#if os(macOS)
        32
#else
        44
#endif
    }

    static var navigationTarget: CGFloat {
#if os(macOS)
        36
#else
        44
#endif
    }
}

/// SF Symbols have different intrinsic widths. A shared optical size and a
/// reserved slot keep text and controls aligned without stretching glyphs.
struct PocketSymbol: View {
    enum Role {
        case navigation, action, section, destination, accessory

        var size: CGFloat {
            switch self {
            case .navigation, .action, .section: 16
            case .destination: 20
            case .accessory: 12
            }
        }

        var slot: CGFloat {
            switch self {
            case .navigation, .action, .section: 20
            case .destination: 28
            case .accessory: 16
            }
        }
    }

    let name: String
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var slot: CGFloat = 20

    init(_ name: String, role: Role = .section) {
        self.name = name
        _size = ScaledMetric(wrappedValue: role.size, relativeTo: .body)
        _slot = ScaledMetric(wrappedValue: role.slot, relativeTo: .body)
    }

    var body: some View {
        Image(systemName: name)
            .font(.system(size: size, weight: .regular))
            .frame(width: slot, height: slot)
            .accessibilityHidden(true)
    }
}

/// Icon actions retain a platform-appropriate hit target independently of
/// their glyph size. The owning Button or Menu supplies its accessible name.
struct PocketActionGlyph: View {
    let name: String

    var body: some View {
        PocketSymbol(name, role: .action)
            .frame(width: PocketDesign.actionTarget, height: PocketDesign.actionTarget)
            .contentShape(Rectangle())
    }
}

struct PocketSectionLabel: LabelStyle {
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var slot: CGFloat = 20

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .font(.system(size: size, weight: .regular))
                .frame(width: slot)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
