import Foundation

/// Records of Pocket Reading Sync over BLE v1 (firmware `docs/reading-sync-ble-v1.md`),
/// carried on the bonded Nearby Sync service. Records are newline-free, at most
/// `NearbySyncProtocol.maximumRecordBytes`, with fields separated by one space; a
/// payload chunk is the last field and may itself contain spaces, so records are
/// handled as bytes rather than split as text.
enum ReadingSyncBLE {
    /// Capability the status record carries when the reader supports this contract.
    static let capability = "READ1"
    /// Largest payload chunk in a `D` or `W` record.
    static let maximumChunkBytes = 180
    /// Largest offer body the reader accepts.
    static let maximumOfferBytes = 1024
    /// Offers sent per connection.
    static let maximumOffers = 10

    enum Event: Equatable {
        case data(id: String, seq: Int, chunk: Data)
        case end(id: String, total: Int, crc: UInt32)
        case ok(id: String)
        case error(id: String, code: String)
    }

    // MARK: Commands

    static func readList(requestID: String) -> Data? {
        guard isRequestID(requestID) else { return nil }
        return record(Data("READ_LIST \(requestID)".utf8))
    }

    static func offer(requestID: String, total: Int, crc: UInt32) -> Data? {
        guard isRequestID(requestID), (1...maximumOfferBytes).contains(total) else { return nil }
        return record(Data("OFFER \(requestID) \(total) \(hex(crc))".utf8))
    }

    static func write(requestID: String, seq: Int, chunk: Data) -> Data? {
        guard isRequestID(requestID), seq >= 0, (1...maximumChunkBytes).contains(chunk.count),
              !chunk.contains(0x0A), !chunk.contains(0x0D) else { return nil }
        return record(Data("W \(requestID) \(seq) ".utf8) + chunk)
    }

    /// The records of one offer: `OFFER` followed by its `W` chunks, or nil when
    /// the body cannot be offered (empty, too large or containing a newline).
    static func offerRecords(requestID: String, body: Data) -> [Data]? {
        guard !body.isEmpty, body.count <= maximumOfferBytes,
              let head = offer(requestID: requestID, total: body.count, crc: CRC32.checksum(body)) else { return nil }
        var records = [head]
        for (seq, chunk) in chunks(body).enumerated() {
            guard let record = write(requestID: requestID, seq: seq, chunk: chunk) else { return nil }
            records.append(record)
        }
        return records
    }

    /// Splits a body into chunks of at most `maximumChunkBytes`, never inside a
    /// UTF-8 sequence, so every record stays valid UTF-8.
    static func chunks(_ body: Data, limit: Int = maximumChunkBytes) -> [Data] {
        let bytes = [UInt8](body)
        var result: [Data] = []
        var start = 0
        while start < bytes.count {
            var end = min(start + limit, bytes.count)
            if end < bytes.count {
                var boundary = end
                while boundary > start, bytes[boundary] & 0xC0 == 0x80 { boundary -= 1 }
                if boundary > start { end = boundary }
            }
            result.append(Data(bytes[start..<end]))
            start = end
        }
        return result
    }

    // MARK: Events

    /// Parses a reading-sync event, or returns nil for another Nearby Sync event
    /// (such as `AP`). Throws for a malformed reading-sync record.
    static func parseEvent(_ record: Data) throws -> Event? {
        guard record.count <= NearbySyncProtocol.maximumRecordBytes,
              !record.contains(0x0A), !record.contains(0x0D) else { throw NearbySyncError.malformedRecord }
        let bytes = [UInt8](record)
        guard let first = bytes.firstIndex(of: 0x20) else {
            if ["D", "END", "OK", "ERR"].contains(String(decoding: bytes, as: UTF8.self)) {
                throw NearbySyncError.malformedRecord
            }
            return nil
        }
        let kind = String(decoding: bytes[..<first], as: UTF8.self)
        guard ["D", "END", "OK", "ERR"].contains(kind) else { return nil }

        if kind == "D" {
            // D <id> <seq> <chunk>: the chunk is everything after the third space.
            let fields = split(bytes, into: 4)
            guard fields.count == 4, let id = text(fields[1]), isRequestID(id),
                  let seq = number(fields[2], maximum: 9999),
                  (1...maximumChunkBytes).contains(fields[3].count) else { throw NearbySyncError.malformedRecord }
            return .data(id: id, seq: seq, chunk: Data(fields[3]))
        }

        guard let line = String(bytes: bytes, encoding: .utf8) else { throw NearbySyncError.malformedRecord }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 2, isRequestID(parts[1]) else { throw NearbySyncError.malformedRecord }
        let id = parts[1]
        switch kind {
        case "END":
            guard parts.count == 4, let total = number(Array(parts[2].utf8), maximum: ReaderReadingList.maximumBytes),
                  parts[3].utf8.count == 8, parts[3].allSatisfy(\.isHexDigit), let crc = UInt32(parts[3], radix: 16)
            else { throw NearbySyncError.malformedRecord }
            return .end(id: id, total: total, crc: crc)
        case "OK":
            guard parts.count == 2 else { throw NearbySyncError.malformedRecord }
            return .ok(id: id)
        default:
            guard parts.count == 3, !parts[2].isEmpty,
                  parts[2].allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") })
            else { throw NearbySyncError.malformedRecord }
            return .error(id: id, code: parts[2])
        }
    }

    // MARK: Helpers

    static func isRequestID(_ value: String) -> Bool {
        value.utf8.count == 8 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x46).contains($0) }
    }

    /// Eight uppercase hexadecimal digits.
    static func hex(_ value: UInt32) -> String { String(format: "%08X", value) }

    private static func record(_ data: Data) -> Data? {
        data.count <= NearbySyncProtocol.maximumRecordBytes ? data : nil
    }

    /// Splits on single spaces into at most `count` fields; the last keeps the rest.
    private static func split(_ bytes: [UInt8], into count: Int) -> [ArraySlice<UInt8>] {
        var fields: [ArraySlice<UInt8>] = []
        var start = bytes.startIndex
        var index = start
        while index < bytes.endIndex, fields.count < count - 1 {
            if bytes[index] == 0x20 {
                fields.append(bytes[start..<index])
                start = index + 1
            }
            index += 1
        }
        fields.append(bytes[start...])
        return fields
    }

    private static func text(_ bytes: ArraySlice<UInt8>) -> String? { String(bytes: bytes, encoding: .utf8) }

    /// A plain decimal without sign or leading zeros (except "0"), up to `maximum`.
    private static func number<C: Collection>(_ bytes: C, maximum: Int) -> Int? where C.Element == UInt8 {
        guard !bytes.isEmpty, bytes.count <= 6, bytes.allSatisfy({ (0x30...0x39).contains($0) }),
              bytes.count == 1 || bytes.first != 0x30 else { return nil }
        guard let value = Int(String(decoding: bytes, as: UTF8.self)), value <= maximum else { return nil }
        return value
    }
}

extension CRC32 {
    /// CRC-32 (IEEE) of one buffer, as zlib computes it.
    static func checksum(_ data: Data) -> UInt32 {
        var crc = CRC32()
        crc.update(data)
        return crc.finalized
    }
}

/// Collects the `D` chunks of one `READ_LIST` reply by sequence number and
/// verifies them against `END` before anything is parsed.
struct ReadingListAssembler {
    let requestID: String
    private var chunks: [Int: Data] = [:]
    private(set) var byteCount = 0

    init(requestID: String) {
        self.requestID = requestID
    }

    /// A repeated chunk with the same bytes is ignored (a retried notification);
    /// a repeated sequence number with other bytes means the list is corrupt.
    mutating func add(seq: Int, chunk: Data) throws {
        if let existing = chunks[seq] {
            guard existing == chunk else { throw ReadingSyncBLEError.corruptList }
            return
        }
        guard byteCount + chunk.count <= ReaderReadingList.maximumBytes else { throw ReadingSyncBLEError.corruptList }
        chunks[seq] = chunk
        byteCount += chunk.count
    }

    /// The concatenated body once every chunk from 0 arrived and the length and
    /// CRC-32 match `END`.
    func finish(total: Int, crc: UInt32) throws -> Data {
        var body = Data()
        for seq in 0..<chunks.count {
            guard let chunk = chunks[seq] else { throw ReadingSyncBLEError.corruptList }
            body.append(chunk)
        }
        guard body.count == total, CRC32.checksum(body) == crc else { throw ReadingSyncBLEError.corruptList }
        return body
    }
}

enum ReadingSyncBLEError: LocalizedError, Equatable {
    case corruptList
    case rejected(String)
    case timedOut
    case interrupted

    var errorDescription: String? {
        switch self {
        case .corruptList: "The reading list from the reader arrived incomplete over Bluetooth."
        case let .rejected(code): "The reader declined the Bluetooth exchange (\(code))."
        case .timedOut: "The reader stopped answering over Bluetooth."
        case .interrupted: "The Bluetooth exchange with the reader was interrupted."
        }
    }
}
