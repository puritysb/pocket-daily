import Foundation

/// Reader firmware guidance aligned with the reader's built-in OTA path
/// (Settings → System → Update pulls the latest GitHub release). Dev builds
/// (`-dev-` version strings) never trigger the hint: they are ahead of or
/// beside the release lineage by design.
enum FirmwareGuidance {
    /// Bump when a reader release matters for the companion experience.
    static let minimumRecommended = "1.6.6"

    enum Advice: Equatable {
        case upToDate
        case updateAvailable(current: String, minimum: String)
        case developmentBuild
        case unknownFormat
    }

    static func advise(readerVersion: String) -> Advice {
        let version = readerVersion.trimmingCharacters(in: .whitespaces)
        if version.contains("-dev-") || version.hasPrefix("DEMO") {
            return .developmentBuild
        }
        guard let running = parse(version), let minimum = parse(minimumRecommended) else {
            return .unknownFormat
        }
        return running < minimum
            ? .updateAvailable(current: version, minimum: minimumRecommended)
            : .upToDate
    }

    /// Extracts (major, minor, patch) from a leading `x.y.z` prefix.
    static func parse(_ version: String) -> (Int, Int, Int)? {
        let pattern = /^(\d+)\.(\d+)\.(\d+)/
        guard let match = version.firstMatch(of: pattern) else { return nil }
        return (Int(match.1)!, Int(match.2)!, Int(match.3)!)
    }
}
