import Foundation
#if os(iOS)
import UIKit
#endif

/// One device's place in one book: the record iCloud and the reader exchange
/// (docs/READING_PROGRESS.md). `progress` is an XPointer such as
/// `/body/DocFragment[3]/body/p[12]/text().40`, the format the reader shares.
struct PositionRecord: Codable, Equatable, Sendable {
    var document: String
    var progress: String
    /// Whole-book progress from 0 to 1, at the start of the page.
    var percentage: Double
    var device: String
    var deviceID: String
    /// Unix seconds when known; readers without a trusted clock leave it nil.
    var timestamp: Int?
    var readerSeq: UInt32? = nil

    enum CodingKeys: String, CodingKey {
        case document, progress, percentage, device
        case deviceID = "device_id"
        case timestamp, readerSeq
    }
}

/// This installation's name and random identifier in position records.
@MainActor
enum SyncDevice {
    private static let key = "sync.deviceID"

    static var name: String {
#if os(macOS)
        "Pocket Daily Mac"
#else
        UIDevice.current.userInterfaceIdiom == .pad ? "Pocket Daily iPad" : "Pocket Daily iPhone"
#endif
    }

    static func identifier(_ defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: key), KOReaderDocumentDigest.isDigest(stored) { return stored }
        var generator = SystemRandomNumberGenerator()
        let created = (0..<16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
        defaults.set(created, forKey: key)
        return created
    }
}
