import CryptoKit
import Foundation

struct FirmwareImageMetadata: Equatable, Sendable {
    let byteCount: Int
    let version: String?
}

enum FirmwareValidationError: LocalizedError, Equatable {
    case tooSmall
    case tooLarge
    case invalidHeader
    case unsupportedChip
    case malformedSegments
    case checksumMismatch
    case digestMismatch
    case incompatibleProduct
    case unsupportedReader(String)

    var errorDescription: String? {
        switch self {
        case .tooSmall:
            "This firmware image is too small to be a supported Pocket Daily image."
        case .tooLarge:
            "This firmware image is larger than the reader's update partition."
        case .invalidHeader:
            "This file is not a valid ESP32 application image."
        case .unsupportedChip:
            "This firmware targets a different chip. Select an ESP32-C3 Pocket Daily build for X3/X4 readers."
        case .malformedSegments:
            "This firmware has an invalid or truncated segment table. Download or build it again."
        case .checksumMismatch:
            "This firmware failed its ESP image checksum. The file may be damaged."
        case .digestMismatch:
            "This firmware failed its SHA-256 integrity check. The file may be damaged or incomplete."
        case .incompatibleProduct:
            "This ESP32-C3 image does not identify itself as Pocket Daily firmware with Nearby Sync support."
        case let .unsupportedReader(device):
            "Firmware staging is disabled for the unrecognized reader profile \(device). Connect an X3/X4-compatible reader."
        }
    }
}

enum FirmwareImageValidator {
    static let minimumSize = 64 * 1_024
    static let maximumSize = 0x64_0000

    private static let headerSize = 24
    private static let segmentHeaderSize = 8
    private static let maximumSegments = 16
    private static let espImageMagic: UInt8 = 0xE9
    private static let espAppDescriptorMagic: UInt32 = 0xABCD_5432
    private static let esp32C3ChipID: UInt16 = 5
    private static let checksumSeed: UInt8 = 0xEF
    private static let shaTrailerSize = 32
    private static let productMarkers = ["CrossPoint version:", "PocketNearbySync"]

    static func validate(fileURL: URL) throws -> FirmwareImageMetadata {
        let scoped = fileURL.startAccessingSecurityScopedResource()
        defer { if scoped { fileURL.stopAccessingSecurityScopedResource() } }
        return try validate(Data(contentsOf: fileURL, options: .mappedIfSafe))
    }

    static func validate(_ image: Data) throws -> FirmwareImageMetadata {
        guard image.count >= minimumSize else { throw FirmwareValidationError.tooSmall }
        guard image.count <= maximumSize else { throw FirmwareValidationError.tooLarge }
        guard image.count >= headerSize,
              image[0] == espImageMagic,
              readUInt32(in: image, at: headerSize + segmentHeaderSize) == espAppDescriptorMagic else {
            throw FirmwareValidationError.invalidHeader
        }

        guard readUInt16(in: image, at: 12) == esp32C3ChipID else {
            throw FirmwareValidationError.unsupportedChip
        }

        let segmentCount = Int(image[1])
        guard (1 ... maximumSegments).contains(segmentCount) else {
            throw FirmwareValidationError.malformedSegments
        }

        var position = headerSize
        var checksum = checksumSeed
        for _ in 0 ..< segmentCount {
            guard position <= image.count - segmentHeaderSize else {
                throw FirmwareValidationError.malformedSegments
            }
            let dataLength = Int(readUInt32(in: image, at: position + 4))
            position += segmentHeaderSize
            guard dataLength <= image.count - position else {
                throw FirmwareValidationError.malformedSegments
            }
            for byte in image[position ..< position + dataLength] {
                checksum ^= byte
            }
            position += dataLength
        }

        let paddedEnd = (position + 16) & ~15
        let hashAppended = image[23] != 0
        let expectedSize = paddedEnd + (hashAppended ? shaTrailerSize : 0)
        guard paddedEnd > position, expectedSize == image.count else {
            throw FirmwareValidationError.malformedSegments
        }
        guard image[paddedEnd - 1] == checksum else {
            throw FirmwareValidationError.checksumMismatch
        }

        if hashAppended {
            let computed = Data(SHA256.hash(data: image.prefix(paddedEnd)))
            let stored = image.subdata(in: paddedEnd ..< expectedSize)
            guard computed == stored else { throw FirmwareValidationError.digestMismatch }
        }

        guard productMarkers.allSatisfy({ marker in
            image.range(of: Data(marker.utf8)) != nil
        }) else {
            throw FirmwareValidationError.incompatibleProduct
        }

        return FirmwareImageMetadata(
            byteCount: image.count,
            version: string(after: "CrossPoint version:", in: image)
        )
    }

    private static func readUInt16(in data: Data, at offset: Int) -> UInt16 {
        guard offset >= 0, offset <= data.count - 2 else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(in data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }

    private static func string(after marker: String, in data: Data) -> String? {
        guard let markerRange = data.range(of: Data(marker.utf8)) else { return nil }
        let start = markerRange.upperBound
        let limit = min(start + 64, data.endIndex)
        let end = data[start ..< limit].firstIndex(where: { $0 == 0 || $0 == 10 || $0 == 13 }) ?? limit
        let value = String(decoding: data[start ..< end], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
