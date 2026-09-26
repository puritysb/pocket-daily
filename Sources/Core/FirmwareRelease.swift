import Foundation

/// The latest official Pocket Daily firmware release, fetched only when the
/// user asks to update a connected reader. The app downloads the image and
/// sends it over the existing transfer path; the reader still validates it
/// and installs only after its own confirmation. Nothing here runs in the app.
struct FirmwareRelease: Equatable, Sendable {
    let version: String
    let downloadURL: URL
    let byteCount: Int
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
    static let latestURL = URL(string: "https://api.github.com/repos/puritysb/pocket-daily-firmware/releases/latest")!
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
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
    }

    /// Parses GitHub's latest-release JSON. Deterministic, for tests.
    static func parse(_ data: Data) throws -> FirmwareRelease {
        guard let document = try? JSONDecoder().decode(ReleaseDocument.self, from: data),
              document.draft != true, document.prerelease != true else { throw FirmwareReleaseError.malformed }
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
        return FirmwareRelease(version: version, downloadURL: url, byteCount: asset.size)
    }

    static func latest(session: URLSession = .shared) async throws -> FirmwareRelease {
        var request = URLRequest(url: latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw FirmwareReleaseError.unavailable }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FirmwareReleaseError.unavailable }
        return try parse(data)
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
}
