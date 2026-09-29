import Foundation

/// Reader version parsing and the one-time pre-launch version migration.
enum FirmwareGuidance {
    static let minimumRecommended = "1.0.0"

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
