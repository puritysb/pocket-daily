import Foundation

/// Reader firmware guidance. An older reader gets a note with Update reader,
/// which downloads the latest official release only when tapped
/// (FirmwareReleaseSource); the bundled minimum needs no network. Dev builds
/// (`-dev-` version strings) never trigger the hint: they are ahead of or
/// beside the release lineage by design.
enum FirmwareGuidance {
    /// Bump when a reader release matters for the companion experience.
    static let minimumRecommended = "1.7.0"
    static let releasesPage = URL(string: "https://github.com/puritysb/pocket-daily-firmware/releases/latest")!

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
