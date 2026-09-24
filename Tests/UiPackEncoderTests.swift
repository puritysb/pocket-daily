import XCTest
@testable import Pocket

/// M3: .uipack encoding must match the firmware container contract
/// (`UiPack.h` in the sibling firmware repository).
final class UiPackEncoderTests: XCTestCase {
    func testMixedTypesMatchFirmwareGolden() throws {
        // Same fixture is parsed/applied by firmware test/live_studio/UiPackTest.cpp.
        let golden = "504455490100000073747564696f0000000000000000000000000000000000000000000000000000312e300000000000000000000000000000000000000000000000000000000000030000000000000015000000cb099a5fb2ce69981565f3640b239a91fcce4b10cc9a5a44396e3b7963afb513259b61210400012a000000330002010000002e00030000003f"
        let data = try UiPackEncoder.encodeValues(name: "studio", version: "1.0", theme: [
            "headerHeight": .integer(42), "popupTextBold": .bool(true), "popupTopOffsetRatio": .float(0.5)
        ])
        XCTAssertEqual(data.map { String(format: "%02x", $0) }.joined(), golden)
    }

    func testIntegerEditorEncodesBooleanType() throws {
        let data = try UiPackEncoder.encode(name: "studio", version: "1", theme: ["popupTextBold": 1])
        XCTAssertEqual(Array(data[120...]), [51, 0, 2, 1, 0, 0, 0])
        let off = try UiPackEncoder.encode(name: "studio", version: "1", theme: ["popupTextBold": 0])
        XCTAssertEqual(Array(off[120...]), [51, 0, 2, 0, 0, 0, 0])
    }

    func testInvalidValuesAreNotSilentlyClampedOrReinterpreted() {
        for theme in [["popupTextBold": 2], ["headerHeight": Int.max]] {
            XCTAssertThrowsError(try UiPackEncoder.encode(name: "studio", version: "1", theme: theme))
        }
        for value in [Float.nan, .infinity, -.infinity] {
            XCTAssertThrowsError(try UiPackEncoder.encodeValues(name: "studio", version: "1",
                theme: ["popupTopOffsetRatio": .float(value)]))
        }
        XCTAssertThrowsError(try UiPackEncoder.encodeValues(name: "studio", version: "1",
            theme: ["popupTextBold": .integer(1)]))
    }

    func testMetadataCannotBeTruncatedOrContainNul() {
        for name in ["", String(repeating: "a", count: 25), String(repeating: "한", count: 11), "a\0b", "../bad", "a.b"] {
            XCTAssertThrowsError(try UiPackEncoder.encode(name: name, version: "1", theme: [:]))
        }
        XCTAssertThrowsError(try UiPackEncoder.encode(name: "studio", version: String(repeating: "1", count: 17), theme: [:]))
    }

    func testCoverHeightDomainMatchesFirmware() {
        for value in [Int(Int32.min), -1, 0, 2049, Int(Int32.max)] {
            XCTAssertThrowsError(try UiPackEncoder.encode(name: "studio", version: "1",
                theme: ["homeCoverHeight": value]))
        }
        for value in [1, 226, 300, 400, 2048] {
            XCTAssertNoThrow(try UiPackEncoder.encode(name: "studio", version: "1",
                theme: ["homeCoverHeight": value]))
        }
    }

    func testPopupRatioDomainMatchesFirmware() throws {
        for bits: UInt32 in [0x3F800001, 0x80000001, 0x7F7FFFFF, 0xFF7FFFFF] {
            XCTAssertThrowsError(try UiPackEncoder.encodeValues(name: "studio", version: "1",
                theme: ["popupTopOffsetRatio": .float(Float(bitPattern: bits))]))
        }
        for bits: UInt32 in [0, 0x80000000, 1, 0x3F000000, 0x3F800000] {
            let pack = try UiPackEncoder.encodeValues(name: "studio", version: "1",
                theme: ["popupTopOffsetRatio": .float(Float(bitPattern: bits))])
            XCTAssertEqual(Array(pack[123...126]), (0..<4).map { UInt8(truncatingIfNeeded: bits >> ($0 * 8)) })
        }
        XCTAssertThrowsError(try UiPackEncoder.encode(name: "studio", version: "1",
            theme: ["popupTopOffsetRatio": 2]))
    }

    func testActivationRequiresExactIdentityAndRevision() throws {
        let json = """
        {"version":"test","ip":"192.0.2.1","mode":"STA","rssi":-40,"freeHeap":20000,
         "uptime":100,"device":"X3","deviceID":"test-reader",
         "liveStudio":{"mode":"poll","uiPacks":true,"activePack":"studio","activePackVersion":"revision1"}}
        """
        var status = try JSONDecoder().decode(CrossPointStatus.self, from: Data(json.utf8))
        XCTAssertNoThrow(try UiPackVerification.validate(status, expectedDeviceID: "test-reader", name: "studio", version: "revision1"))
        XCTAssertThrowsError(try UiPackVerification.validate(status, expectedDeviceID: "other", name: "studio", version: "revision1"))
        XCTAssertThrowsError(try UiPackVerification.validate(status, expectedDeviceID: "test-reader", name: "studio", version: "revision2"))
        XCTAssertThrowsError(try UiPackVerification.validate(status, expectedDeviceID: "test-reader", name: nil, version: nil))
        status.liveStudio = LiveStudioAdvertisement(wsPort: nil, mode: "poll", frameStream: false,
                                                    uiPacks: true, activePack: nil, activePackVersion: nil)
        XCTAssertNoThrow(try UiPackVerification.validate(status, expectedDeviceID: "test-reader", name: nil, version: nil))
        status.liveStudio = nil
        XCTAssertThrowsError(try UiPackVerification.validate(status, expectedDeviceID: "test-reader", name: nil, version: nil))
        for identity in [nil, "", " "] as [String?] {
            XCTAssertThrowsError(try UiPackVerification.identity(identity))
        }
    }

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
