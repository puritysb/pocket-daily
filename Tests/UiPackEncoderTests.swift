import XCTest
@testable import Pocket

/// M3: .uipack encoding must match the firmware container contract
/// (`UiPack.h` in the sibling firmware repository).
final class UiPackEncoderTests: XCTestCase {
    func testRegistryMirrorsFirmware() {
        // scripts/gen_theme_fields.py emits 63 fields for the current
        // BaseTheme.h; the app registry must track it exactly.
        XCTAssertEqual(UiPackEncoder.fields.count, 63)
        XCTAssertEqual(UiPackEncoder.fields["listRowHeight"], 9)
        XCTAssertEqual(UiPackEncoder.fields["popupTopOffsetRatio"], 46)
        XCTAssertEqual(UiPackEncoder.fields["textFieldLineEndOffset"], 62)
    }

    func testEncodeProducesValidHeaderAndRecords() throws {
        let data = try UiPackEncoder.encode(
            name: "studio", version: "1.0",
            theme: ["listRowHeight": 64, "headerHeight": 42, "popupTextBold": 1]
        )
        let bytes = [UInt8](data)
        XCTAssertGreaterThan(bytes.count, 120)
        XCTAssertEqual(Array(bytes[0..<4]), Array("PDUI".utf8))
        XCTAssertEqual(bytes[4], 1)
        XCTAssertEqual(Array(bytes[8..<14]), Array("studio".utf8))
        // 3 theme overrides, no strings/assets
        let count = UInt16(bytes[72]) | (UInt16(bytes[73]) << 8)
        XCTAssertEqual(count, 3)
        let payloadLen = UInt32(bytes[80]) | (UInt32(bytes[81]) << 8) | (UInt32(bytes[82]) << 16)
            | (UInt32(bytes[83]) << 24)
        XCTAssertEqual(Int(payloadLen), 3 * 7)
        XCTAssertEqual(bytes.count, 120 + Int(payloadLen))

        // CRC over payload must match a local recompute.
        let payload = Data(bytes[120...])
        var crc = CRC32()
        crc.update(payload)
        let stored = UInt32(bytes[84]) | (UInt32(bytes[85]) << 8) | (UInt32(bytes[86]) << 16)
            | (UInt32(bytes[87]) << 24)
        XCTAssertEqual(stored, crc.finalized)

        // First record (fields sorted by name): headerHeight = id 4, type 1.
        XCTAssertEqual(UInt16(bytes[120]) | (UInt16(bytes[121]) << 8), 4)
        XCTAssertEqual(bytes[122], 1)
        let value = Int32(bytes[123]) | (Int32(bytes[124]) << 8)
        XCTAssertEqual(value, 42)
    }

    func testUnknownFieldThrows() {
        XCTAssertThrowsError(try UiPackEncoder.encode(name: "x", version: "1", theme: ["notAField": 1])) { error in
            guard case UiPackEncoder.EncodeError.unknownField = error else {
                return XCTFail("expected unknownField, got \(error)")
            }
        }
    }
}
