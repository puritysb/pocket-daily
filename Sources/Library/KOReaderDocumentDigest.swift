import CryptoKit
import Foundation

/// KOReader document identities shared by the app, the reader firmware
/// (`lib/KOReaderSync/KOReaderDocumentId.cpp`), and KOReader itself.
enum KOReaderDocumentDigest {
    static let sampleSize = 1_024

    /// Sample offsets in KOReader's `util.partialMD5` order: 0, then
    /// `1024 << (2 * i)` for `i` in 0...10. LuaJIT masks the shift count, so
    /// the `i = -1` step reads from offset 0.
    static let sampleOffsets: [UInt64] = (-1 ... 10).map { index in
        index < 0 ? 0 : UInt64(sampleSize) << UInt64(2 * index)
    }

    /// Matches KOReader's partial MD5 without loading the whole file.
    static func partialMD5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()

        var hasher = Insecure.MD5()
        for offset in sampleOffsets {
            guard offset < fileSize else { break }
            try handle.seek(toOffset: offset)
            guard let sample = try handle.read(upToCount: sampleSize), !sample.isEmpty else { break }
            hasher.update(data: sample)
        }
        return hex(hasher.finalize())
    }

    static func partialMD5(of data: Data) -> String {
        var hasher = Insecure.MD5()
        for offset in sampleOffsets {
            guard offset < UInt64(data.count) else { break }
            let start = data.startIndex + Int(offset)
            let end = min(start + sampleSize, data.endIndex)
            hasher.update(data: data[start ..< end])
        }
        return hex(hasher.finalize())
    }

    /// KOReader's filename checksum mode: MD5 of the last path component.
    static func filenameMD5(_ fileName: String) -> String {
        let name = (fileName as NSString).lastPathComponent
        return md5Hex(Data(name.utf8))
    }

    static func md5Hex(_ data: Data) -> String {
        hex(Insecure.MD5.hash(data: data))
    }

    static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { byte in
            (UInt8(ascii: "0") ... UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a") ... UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A") ... UInt8(ascii: "F")).contains(byte)
        }
    }

    private static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
