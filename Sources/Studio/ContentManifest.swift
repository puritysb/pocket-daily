import CryptoKit
import Foundation

/// Companion half of firmware docs/content-manifest-v1.md. This does not
/// activate content; the device must validate referenced files before commit.
enum ContentManifest {
    enum Kind: UInt8 { case card = 1, monoImage = 2 }
    struct File: Equatable {
        let path: String
        let kind: Kind
        let bytes: UInt32
        let sha256: Data

        init(path: String, kind: Kind, content: Data) throws {
            guard let size = UInt32(exactly: content.count) else { throw ValidationError.size }
            self.init(path: path, kind: kind, bytes: size, sha256: Data(SHA256.hash(data: content)))
        }

        init(path: String, kind: Kind, bytes: UInt32, sha256: Data) {
            self.path = path
            self.kind = kind
            self.bytes = bytes
            self.sha256 = sha256
        }
    }
    enum ValidationError: Error { case count, path, duplicate, size, digest }

    static func encode(_ files: [File], cardLayout: Bool = false) throws -> Data {
        guard files.count <= 16, files.filter({ $0.kind == .card }).count <= 3 else {
            throw ValidationError.count
        }
        let sorted = files.sorted { $0.path < $1.path }
        var names = Set<String>()
        var total: UInt64 = 0
        for file in sorted {
            guard validPath(file.path, kind: file.kind) else { throw ValidationError.path }
            guard names.insert(file.path).inserted else { throw ValidationError.duplicate }
            guard file.sha256.count == 32 else { throw ValidationError.digest }
            let limit: UInt32 = file.kind == .card ? 16 * 1024 : 64 * 1024
            guard file.bytes > 0, file.bytes <= limit else { throw ValidationError.size }
            total += UInt64(file.bytes)
            guard total <= 256 * 1024 else { throw ValidationError.size }
        }
        var data = Data("PDCM".utf8)
        append(1, bytes: 2, to: &data)
        append(16, bytes: 2, to: &data)
        append(UInt32(sorted.count), bytes: 2, to: &data)
        let capabilities: UInt32 = (sorted.contains(where: { $0.kind == .monoImage }) ? 3 : 1) | (cardLayout ? 4 : 0)
        append(capabilities, bytes: 2, to: &data)
        append(UInt32(20 + 104 * sorted.count), bytes: 4, to: &data)
        for file in sorted {
            data.append(contentsOf: [file.kind.rawValue, 0, 0, 0])
            append(file.bytes, bytes: 4, to: &data)
            data.append(file.sha256)
            data.append(contentsOf: file.path.utf8)
            data.append(Data(repeating: 0, count: 64 - file.path.utf8.count))
        }
        append(crc32(data), bytes: 4, to: &data)
        return data
    }

    struct Decoded: Equatable {
        let files: [File]
        let requiredCapabilities: UInt16
    }

    /// Strict reader for manifests read back from a reader. Accepts only the
    /// canonical bytes `encode` would produce for the same files, which covers
    /// shape, CRC, limits, names, order and the capability bits at once.
    static func decode(_ data: Data) throws -> Decoded {
        let bytes = [UInt8](data)
        func u16(_ at: Int) -> UInt16 { UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8 }
        func u32(_ at: Int) -> UInt32 { UInt32(u16(at)) | UInt32(u16(at + 2)) << 16 }
        guard bytes.count >= 20, bytes.count <= 20 + 104 * 16, bytes.starts(with: Array("PDCM".utf8)),
              u16(4) == 1, u16(6) == 16 else { throw ValidationError.size }
        let count = Int(u16(8))
        guard count <= 16, bytes.count == 20 + 104 * count, u32(12) == UInt32(bytes.count) else {
            throw ValidationError.count
        }
        let capabilities = u16(10)
        var files: [File] = []
        for index in 0..<count {
            let entry = 16 + 104 * index
            guard let kind = Kind(rawValue: bytes[entry]) else { throw ValidationError.path }
            let field = bytes[(entry + 40)..<(entry + 104)]
            guard let end = field.firstIndex(of: 0),
                  let path = String(bytes: field[field.startIndex..<end], encoding: .utf8) else {
                throw ValidationError.path
            }
            files.append(.init(path: path, kind: kind, bytes: u32(entry + 4),
                               sha256: Data(bytes[(entry + 8)..<(entry + 40)])))
        }
        guard try encode(files, cardLayout: capabilities & 4 != 0) == data else { throw ValidationError.digest }
        return .init(files: files, requiredCapabilities: capabilities)
    }

    static func revision(of manifest: Data) -> String {
        SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
    }

    static func validPath(_ path: String, kind: Kind) -> Bool {
        let suffix = kind == .card ? ".card" : ".pbm"
        let bytes = Array(path.utf8)
        guard bytes.count < 64, path.hasSuffix(suffix), bytes.count > suffix.utf8.count else { return false }
        return bytes.dropLast(suffix.utf8.count).enumerated().allSatisfy { index, byte in
            (97...122).contains(byte) || (48...57).contains(byte) || (index > 0 && (byte == 45 || byte == 95))
        }
    }

    private static func append(_ value: UInt32, bytes: Int, to data: inout Data) {
        for index in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0) }
        }
        return crc ^ UInt32.max
    }
}
