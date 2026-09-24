import CryptoKit
import Foundation

/// Read-only artifact check using the shipping app validator, not a second
/// implementation of the ESP image format. Never opens a device connection.
@main
struct FirmwareArtifactCheck {
    static func main() {
        guard CommandLine.arguments.count == 3 else {
            fail("Usage: validate_firmware.sh IMAGE EXPECTED_VERSION")
        }
        do {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            let image = try Data(contentsOf: url, options: .mappedIfSafe)
            let metadata = try FirmwareImageValidator.validate(image)
            guard let version = metadata.version, version == CommandLine.arguments[2] else {
                fail("Embedded version does not match EXPECTED_VERSION (found: \(metadata.version ?? "missing")).")
            }
            let report: [String: Any] = [
                "version": version,
                "bytes": metadata.byteCount,
                "sha256": SHA256.hash(data: image).map { String(format: "%02x", $0) }.joined(),
                "validatedBy": "Sources/FirmwareImageValidator.swift",
                "installed": false
            ]
            let json = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            FileHandle.standardOutput.write(json)
            FileHandle.standardOutput.write(Data([10]))
        } catch {
            fail(error.localizedDescription)
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }
}
