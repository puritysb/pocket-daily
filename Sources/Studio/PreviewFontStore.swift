import CryptoKit
import Foundation

/// One immutable font shared by local previews. No reader or remote font fetch.
actor PreviewFontStore {
    static let shared = PreviewFontStore()
    private var cached: Data?
    private let bundle: Bundle
    private struct Manifest: Decodable {
        let schema: Int
        let font: String
        let bytes: Int
        let sha256: String
    }
    init(bundle: Bundle = .main) { self.bundle = bundle }

    func font() throws -> Data {
        if let cached { return cached }
        guard let directory = bundle.url(forResource: "PreviewFont", withExtension: nil) else {
            throw HostRendererBridge.Failure.invalidFont
        }
        let manifest = try JSONDecoder().decode(Manifest.self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        guard manifest.schema == 1, manifest.font == "PocketSansWorld_12.cpfont", manifest.bytes == 10_903_872,
              manifest.sha256 == "a1a15a6e9cdccd114cbaf34adb29fce08ad67d3dcd52b7970a77ab89db9ee753" else {
            throw HostRendererBridge.Failure.invalidFont
        }
        let handle = try FileHandle(forReadingFrom: directory.appendingPathComponent(manifest.font))
        defer { try? handle.close() }
        let bytes = try handle.read(upToCount: manifest.bytes + 1) ?? Data()
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard bytes.count == manifest.bytes, digest == manifest.sha256 else { throw HostRendererBridge.Failure.invalidFont }
        cached = bytes
        return bytes
    }

    func notices() throws -> String {
        guard let directory = bundle.url(forResource: "PreviewFont", withExtension: nil) else {
            throw HostRendererBridge.Failure.invalidFont
        }
        return try ["README.md", "KR-SC-OFL.txt", "JP-OFL.txt", "NotoSans-OFL.txt", "Hebrew-OFL.txt"].map { name in
            name + "\n\n" + (try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
                .replacingOccurrences(of: "\\r\\n", with: "\n")
        }.joined(separator: "\n\n")
    }
}
