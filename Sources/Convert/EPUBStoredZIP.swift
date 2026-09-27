import Foundation
import zlib

/// Deliberately small ZIP32 writer. Only generated ASCII paths and stored entries are supported.
/// Each entry is written immediately; only the central directory remains in memory.
final class EPUBStoredZIP {
    private let handle: FileHandle
    private var directory = Data()
    private var offset: UInt32 = 0
    private var count: UInt16 = 0
    private var finished = false

    init(handle: FileHandle) { self.handle = handle }

    func add(path: String, data: Data) throws {
        guard !finished, count < UInt16.max,
              path.utf8.count <= Int(UInt16.max), !path.isEmpty,
              path.utf8.allSatisfy({ (33...126).contains($0) }),
              !path.contains("\\"), !path.hasPrefix("/"),
              path.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." }),
              data.count <= Int(UInt32.max) else { throw EPUBExportError.archiveLimit }
        let name = Data(path.utf8)
        let size = UInt32(data.count)
        let crc = data.withUnsafeBytes { bytes in
            UInt32(zlib.crc32(0, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count)))
        }
        let entryOffset = offset
        var header = Data()
        header.zip32(0x04034b50)
        header.zip16(20) // version needed
        header.zip16(0) // no flags, encryption, or data descriptor
        header.zip16(0) // stored
        header.zip16(0) // fixed DOS time, 1980-01-01
        header.zip16(33)
        header.zip32(crc)
        header.zip32(size)
        header.zip32(size)
        header.zip16(UInt16(name.count))
        header.zip16(0) // mimetype must have no extra field
        header.append(name)
        try write(header)
        try write(data)

        directory.zip32(0x02014b50)
        directory.zip16(20) // made by DOS, no platform-specific attributes
        directory.zip16(20)
        directory.zip16(0)
        directory.zip16(0)
        directory.zip16(0)
        directory.zip16(33)
        directory.zip32(crc)
        directory.zip32(size)
        directory.zip32(size)
        directory.zip16(UInt16(name.count))
        directory.zip16(0) // extra
        directory.zip16(0) // comment
        directory.zip16(0) // disk
        directory.zip16(0) // internal attributes
        directory.zip32(0) // external attributes
        directory.zip32(entryOffset)
        directory.append(name)
        count += 1
    }

    func finish() throws {
        guard !finished else { throw EPUBExportError.archiveLimit }
        let start = offset
        let length = UInt32(directory.count)
        try write(directory)
        var end = Data()
        end.zip32(0x06054b50)
        end.zip16(0)
        end.zip16(0)
        end.zip16(count)
        end.zip16(count)
        end.zip32(length)
        end.zip32(start)
        end.zip16(0)
        try write(end)
        finished = true
    }

    private func write(_ data: Data) throws {
        guard UInt64(offset) + UInt64(data.count) <= UInt64(UInt32.max) else {
            throw EPUBExportError.archiveLimit
        }
        try handle.write(contentsOf: data)
        offset += UInt32(data.count)
    }
}

private extension Data {
    mutating func zip16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }
    mutating func zip32(_ value: UInt32) {
        zip16(UInt16(truncatingIfNeeded: value))
        zip16(UInt16(truncatingIfNeeded: value >> 16))
    }
}
