import CryptoKit
import Foundation

/// Encodes `.uipack` theme-override packs (`docs/live-studio-v1.md`, mirrored
/// by `UiPack.h` in the firmware repository). The layout is the wire
/// contract: 120-byte header + seven-byte theme records, little-endian.
enum UiPackEncoder {
    /// Field ids from the generated registry (`scripts/gen_theme_fields.py`
    /// in the firmware repository emits `theme_fields.json`; this list mirrors
    /// it and a unit test pins the count). Ids are stable once shipped.
    static let fields: [String: Int] = Dictionary(
        uniqueKeysWithValues: registry.enumerated().map { entry in (entry.element.name, entry.offset) }
    )

    private struct Field: Equatable {
        let name: String
        let type: Int
    }

    private static let registry: [Field] = [
        .init(name: "batteryWidth", type: 1), .init(name: "batteryHeight", type: 1),
        .init(name: "topPadding", type: 1), .init(name: "batteryBarHeight", type: 1),
        .init(name: "headerHeight", type: 1), .init(name: "verticalSpacing", type: 1),
        .init(name: "previewPadding", type: 1), .init(name: "previewHeightPercent", type: 1),
        .init(name: "contentSidePadding", type: 1), .init(name: "listRowHeight", type: 1),
        .init(name: "listWithSubtitleRowHeight", type: 1), .init(name: "menuRowHeight", type: 1),
        .init(name: "menuSpacing", type: 1), .init(name: "tabSpacing", type: 1),
        .init(name: "tabBarHeight", type: 1), .init(name: "scrollBarWidth", type: 1),
        .init(name: "scrollBarRightOffset", type: 1), .init(name: "homeTopPadding", type: 1),
        .init(name: "homeCoverHeight", type: 1), .init(name: "homeCoverTileHeight", type: 1),
        .init(name: "homeRecentBooksCount", type: 1), .init(name: "homeContinueReadingInMenu", type: 2),
        .init(name: "homeMenuTopOffset", type: 1), .init(name: "buttonHintsHeight", type: 1),
        .init(name: "sideButtonHintsWidth", type: 1), .init(name: "progressBarHeight", type: 1),
        .init(name: "progressBarMarginTop", type: 1), .init(name: "statusBarHorizontalMargin", type: 1),
        .init(name: "statusBarVerticalMargin", type: 1), .init(name: "keyboardKeyWidth", type: 1),
        .init(name: "keyboardKeyHeight", type: 1), .init(name: "keyboardKeySpacing", type: 1),
        .init(name: "keyboardBottomKeyHeight", type: 1), .init(name: "keyboardBottomKeySpacing", type: 1),
        .init(name: "keyboardBottomAligned", type: 2), .init(name: "keyboardCenteredText", type: 2),
        .init(name: "keyboardVerticalOffset", type: 1), .init(name: "keyboardTextFieldWidthPercent", type: 1),
        .init(name: "keyboardWidthPercent", type: 1), .init(name: "keyboardKeyCornerRadius", type: 1),
        .init(name: "keyboardFillUnselected", type: 2), .init(name: "keyboardOutlineAllUnselected", type: 2),
        .init(name: "keyboardDrawSpecialOutlineWhenUnselected", type: 2),
        .init(name: "keyboardSecondaryLabelRightPadding", type: 1),
        .init(name: "keyboardSecondaryLabelTopPadding", type: 1), .init(name: "keyboardMinArrowHeadSize", type: 1),
        .init(name: "popupTopOffsetRatio", type: 3), .init(name: "popupMarginX", type: 1),
        .init(name: "popupMarginY", type: 1), .init(name: "popupFrameThickness", type: 1),
        .init(name: "popupCornerRadius", type: 1), .init(name: "popupTextBold", type: 2),
        .init(name: "popupTextInverted", type: 2), .init(name: "popupTextBaselineOffsetY", type: 1),
        .init(name: "popupProgressBarHeight", type: 1), .init(name: "popupProgressDrawOutline", type: 2),
        .init(name: "popupProgressClampPercent", type: 2), .init(name: "popupProgressFillInverted", type: 2),
        .init(name: "popupProgressOutlineInverted", type: 2), .init(name: "textFieldHorizontalPadding", type: 1),
        .init(name: "textFieldNormalThickness", type: 1), .init(name: "textFieldCursorThickness", type: 1),
        .init(name: "textFieldLineEndOffset", type: 1),
    ]

    enum EncodeError: LocalizedError {
        case unknownField(String)
        case invalidValue(String)
        case invalidMetadata

        var errorDescription: String? {
            switch self {
            case let .unknownField(name): "The reader firmware does not know the theme field '\(name)'."
            case let .invalidValue(name): "The value for '\(name)' does not match the reader's field type."
            case .invalidMetadata: "Use a pack name of 1–24 ASCII letters, digits, hyphens or underscores, and a version of 1–16 such characters or dots."
            }
        }
    }

    static func encode(name: String, version: String, theme: [String: Int]) throws -> Data {
        var values: [String: Value] = [:]
        for (key, value) in theme {
            guard let field = fields[key] else { throw EncodeError.unknownField(key) }
            switch registry[field].type {
            case 2:
                guard value == 0 || value == 1 else { throw EncodeError.invalidValue(key) }
                values[key] = .bool(value == 1)
            case 3: values[key] = .float(Float(value))
            default: values[key] = .integer(value)
            }
        }
        return try encodeValues(name: name, version: version, theme: values)
    }

    enum Value {
        case integer(Int)
        case bool(Bool)
        case float(Float)
    }

    static func encodeValues(name: String, version: String, theme: [String: Value]) throws -> Data {
        let nameCharacters = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".utf8)
        guard !name.isEmpty, !version.isEmpty, name.utf8.count <= 24, version.utf8.count <= 16,
              name.utf8.allSatisfy({ nameCharacters.contains($0) }),
              version.utf8.allSatisfy({ nameCharacters.contains($0) || $0 == 46 }) else {
            throw EncodeError.invalidMetadata
        }
        var payload = Data()
        let ordered = theme.sorted { $0.key < $1.key }
        for (fieldName, value) in ordered {
            guard let field = fields[fieldName] else { throw EncodeError.unknownField(fieldName) }
            let type = registry[field].type
            let raw: UInt32
            switch (type, value) {
            case (1, let .integer(number)):
                guard let number = Int32(exactly: number) else { throw EncodeError.invalidValue(fieldName) }
                // Mirrored by firmware UiPack.cpp: divisor and resource budget,
                // independent of the selected panel or its orientation.
                if fieldName == "homeCoverHeight", !(1...2048).contains(number) {
                    throw EncodeError.invalidValue(fieldName)
                }
                raw = UInt32(bitPattern: number)
            case (2, let .bool(flag)): raw = flag ? 1 : 0
            case (3, let .float(number)):
                guard number.isFinite else { throw EncodeError.invalidValue(fieldName) }
                if fieldName == "popupTopOffsetRatio", !(0...1).contains(number) {
                    throw EncodeError.invalidValue(fieldName)
                }
                raw = number.bitPattern
            default: throw EncodeError.invalidValue(fieldName)
            }
            var id = UInt16(field).littleEndian
            payload.append(contentsOf: withUnsafeBytes(of: &id) { Array($0) })
            payload.append(UInt8(type))
            var bits = raw.littleEndian
            payload.append(contentsOf: withUnsafeBytes(of: &bits) { Array($0) })
        }

        var header = Data(repeating: 0, count: 120)
        header.replaceSubrange(0..<4, with: Data("PDUI".utf8))
        header[4] = 1
        header.replaceSubrange(8..<8 + min(name.utf8.count, 32), with: Data(name.utf8.prefix(32)))
        header.replaceSubrange(40..<40 + min(version.utf8.count, 16), with: Data(version.utf8.prefix(16)))
        var count = UInt16(theme.count).littleEndian
        header.replaceSubrange(72..<74, with: withUnsafeBytes(of: &count) { Data($0) })
        var payloadLen = UInt32(payload.count).littleEndian
        header.replaceSubrange(80..<84, with: withUnsafeBytes(of: &payloadLen) { Data($0) })
        var digest = CRC32()
        digest.update(payload)
        var crc = digest.finalized.littleEndian
        header.replaceSubrange(84..<88, with: withUnsafeBytes(of: &crc) { Data($0) })
        header.replaceSubrange(88..<120, with: Data(SHA256.hash(data: payload)))

        return header + payload
    }
}
