import Foundation

/// The latest official Pocket Daily firmware release, checked once per launch.
/// Only an explicit update action downloads the image and
/// sends it over the existing transfer path; the reader still validates it
/// and installs only after its own confirmation. Nothing here runs in the app.
struct FirmwareRelease: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let byteCount: Int
    /// A GitHub pre-release (for example `v1.7.0-beta.1`); only the beta
    /// channel of development builds ever sees one.
    var isPrerelease = false
    var publishedAt: Date? = nil
}

enum FirmwareReleaseError: LocalizedError, Equatable {
    case unavailable
    case malformed
    case untrustedLocation
    case tooLarge(Int)
    case versionMismatch(expected: String, found: String?)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Couldn't reach the Pocket Daily firmware releases. Check the internet connection and try again."
        case .malformed:
            return "The latest firmware release could not be read. Try again later."
        case .untrustedLocation:
            return "The latest release points outside the official Pocket Daily firmware repository, so it was not downloaded."
        case let .tooLarge(bytes):
            return "The latest firmware image (\(bytes) bytes) is larger than a reader can hold, so it was not downloaded."
        case let .versionMismatch(expected, found):
            return "The downloaded firmware reports \(found ?? "no version") instead of \(expected), so it was discarded."
        }
    }
}

enum FirmwareReleaseSource {
    /// Which releases Update reader may offer. Store builds use `stable`, the
    /// release GitHub marks latest. Development builds use `beta`: the newest
    /// published release including pre-releases, so a firmware beta can be
    /// installed from the app without choosing a file.
    enum Channel: Sendable {
        case stable, beta
#if DEBUG
        static let current = Channel.beta
#else
        static let current = Channel.stable
#endif
    }

    static let latestURL = URL(string: "https://api.github.com/repos/puritysb/pocket-daily-firmware/releases/latest")!
    /// Newest first; drafts are only visible to the repository owner.
    static let releasesURL = URL(string: "https://api.github.com/repos/puritysb/pocket-daily-firmware/releases?per_page=10")!
    /// Release assets must come from this repository's own download path.
    static let downloadPrefix = "https://github.com/puritysb/pocket-daily-firmware/releases/download/"
    /// The reader's OTA partition is 6.25 MiB; anything larger cannot install.
    static let maximumBytes = 6_553_600

    private struct ReleaseDocument: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int
            let browser_download_url: String
        }
        let published_at: String?
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Parses GitHub's latest-release JSON. Deterministic, for tests.
    static func parse(_ data: Data, allowingPrerelease: Bool = false) throws -> FirmwareRelease {
        guard let document = try? JSONDecoder().decode(ReleaseDocument.self, from: data) else {
            throw FirmwareReleaseError.malformed
        }
        return try release(from: document, allowingPrerelease: allowingPrerelease)
    }

    /// Parses GitHub's release list (newest first) and returns the newest
    /// usable release, pre-releases included. Entries without a valid official
    /// image are skipped; with none usable, the newest entry's error is thrown.
    static func parseNewest(_ data: Data) throws -> FirmwareRelease {
        guard let documents = try? JSONDecoder().decode([ReleaseDocument].self, from: data) else {
            throw FirmwareReleaseError.malformed
        }
        var firstError: Error?
        for document in documents where document.draft != true {
            do { return try release(from: document, allowingPrerelease: true) }
            catch { firstError = firstError ?? error }
        }
        throw firstError ?? FirmwareReleaseError.malformed
    }

    private static func release(from document: ReleaseDocument, allowingPrerelease: Bool) throws -> FirmwareRelease {
        let prerelease = document.prerelease == true
        guard document.draft != true, allowingPrerelease || !prerelease else { throw FirmwareReleaseError.malformed }
        var version = document.tag_name.trimmingCharacters(in: .whitespaces)
        if version.hasPrefix("v") || version.hasPrefix("V") { version.removeFirst() }
        guard FirmwareGuidance.parse(version) != nil,
              let asset = document.assets.first(where: { $0.name == "firmware.bin" }) else {
            throw FirmwareReleaseError.malformed
        }
        guard asset.browser_download_url.hasPrefix(downloadPrefix),
              let url = URL(string: asset.browser_download_url), url.scheme == "https" else {
            throw FirmwareReleaseError.untrustedLocation
        }
        guard asset.size > 0 else { throw FirmwareReleaseError.malformed }
        guard asset.size <= maximumBytes else { throw FirmwareReleaseError.tooLarge(asset.size) }
        return FirmwareRelease(version: version, downloadURL: url, byteCount: asset.size, isPrerelease: prerelease,
                               publishedAt: document.published_at.flatMap { ISO8601DateFormatter().date(from: $0) })
    }

    static func latest(channel: Channel = .current, session: URLSession = .shared) async throws -> FirmwareRelease {
        let url = channel == .beta ? releasesURL : latestURL
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw FirmwareReleaseError.unavailable }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FirmwareReleaseError.unavailable }
        return channel == .beta ? try parseNewest(data) : try parse(data)
    }

    /// Downloads the image into its own folder as `firmware.bin` (the name the
    /// transfer path recognizes) and validates it before returning.
    static func download(_ release: FirmwareRelease, into directory: URL,
                         session: URLSession = .shared) async throws -> URL {
        let temporary: URL
        let response: URLResponse
        do { (temporary, response) = try await session.download(from: release.downloadURL) }
        catch { throw FirmwareReleaseError.unavailable }
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FirmwareReleaseError.unavailable }
        let bytes = (try? FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? Int) ?? 0
        guard bytes == release.byteCount else { throw FirmwareReleaseError.malformed }

        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent("firmware.bin")
        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
            let metadata = try FirmwareImageValidator.validate(fileURL: destination)
            guard metadata.version == release.version else {
                throw FirmwareReleaseError.versionMismatch(expected: release.version, found: metadata.version)
            }
            return destination
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    /// True when `latest` is newer than what the reader runs. Development
    /// builds compare by their x.y.z prefix, so a dev build of the current
    /// release is not offered the same release again.
    static func isNewer(_ latest: String, than running: String) -> Bool {
        guard let new = FirmwareGuidance.parse(latest), let old = FirmwareGuidance.parse(running) else { return false }
        return new > old
    }

    /// Whether Update reader offers `release` to a reader running `running`.
    /// Stable offers only a newer x.y.z. Beta also offers any other build of
    /// the same x.y.z (a beta over a dev build, the final release over its
    /// beta) but never the exact version the reader runs or an older series.
    static func shouldOffer(_ release: String, to running: String, channel: Channel) -> Bool {
        switch channel {
        case .stable:
            return isNewer(release, than: running)
        case .beta:
            guard let new = FirmwareGuidance.parse(release), let old = FirmwareGuidance.parse(running) else { return false }
            return new > old || (new == old && release != running)
        }
    }
}
