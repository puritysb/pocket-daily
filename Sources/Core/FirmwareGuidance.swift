import Foundation

/// Reader version parsing and the one-time version migrations.
enum FirmwareGuidance {
    static let minimumRecommended = "0.1.0"

    /// Versions below 1.0 are the beta series; 1.0.0 is the first stable release
    /// (firmware docs/product-versioning.md).
    static func isBeta(_ version: String) -> Bool {
        version.contains("-") || parse(version)?.0 == 0
    }

    /// The 2026-10 reset renumbered development to 0.x (lineage 2). Readers on the
    /// earlier `1.0.0-beta.*` or `1.0.0-dev-*` builds (lineage 1) are older than
    /// every 0.x release even though their number is higher.
    static func isBeforeVersionReset(_ version: String, lineage: Int?) -> Bool {
        guard lineage == 1, let parsed = parse(version) else { return false }
        return (parsed.0, parsed.1, parsed.2) == (1, 0, 0) && version.contains("-")
    }

    /// Releases published before the reset; never offered again.
    static func isRetiredRelease(_ version: String) -> Bool {
        version.hasPrefix("1.0.0-beta.")
    }

    /// Before the product's first 1.0.0, GitHub carried v1.6.6 and v1.7.0
    /// test images. Their numbers are higher but belong to the old lineage.
    /// New firmware reports lineage 1 so future 1.6.6/1.7.0 are unambiguous.
    static func isPrelaunchVersion(_ version: String, lineage: Int?) -> Bool {
        guard lineage == nil, let parsed = parse(version) else { return false }
        return (parsed.0, parsed.1, parsed.2) == (1, 6, 6)
            || (parsed.0, parsed.1, parsed.2) == (1, 7, 0)
    }

    /// Extracts (major, minor, patch) from a leading `x.y.z` prefix.
    static func parse(_ version: String) -> (Int, Int, Int)? {
        let pattern = /^(\d+)\.(\d+)\.(\d+)/
        guard let match = version.firstMatch(of: pattern) else { return nil }
        return (Int(match.1)!, Int(match.2)!, Int(match.3)!)
    }
}
