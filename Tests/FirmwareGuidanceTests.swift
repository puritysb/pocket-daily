import XCTest
@testable import Pocket

final class FirmwareGuidanceTests: XCTestCase {
    func testHistoricalPublishedVersionsNeedMigration() {
        XCTAssertTrue(FirmwareGuidance.isPrelaunchVersion("1.6.6", lineage: nil))
        XCTAssertTrue(FirmwareGuidance.isPrelaunchVersion("1.7.0-beta.4", lineage: nil))
        XCTAssertTrue(FirmwareGuidance.isPrelaunchVersion("1.7.0-dev-main-abcd", lineage: nil))
        XCTAssertFalse(FirmwareGuidance.isPrelaunchVersion("1.6.6", lineage: 1))
        XCTAssertFalse(FirmwareGuidance.isPrelaunchVersion("1.7.0", lineage: 1))
        XCTAssertFalse(FirmwareGuidance.isPrelaunchVersion("1.4.1", lineage: nil))
        XCTAssertFalse(FirmwareGuidance.isPrelaunchVersion("weird", lineage: nil))
    }

    func testParsing() {
        let parsed = FirmwareGuidance.parse("1.6.6")
        XCTAssertEqual(parsed?.0, 1)
        XCTAssertEqual(parsed?.1, 6)
        XCTAssertEqual(parsed?.2, 6)
        let rc = FirmwareGuidance.parse("2.10.3-rc1")
        XCTAssertEqual(rc?.0, 2)
        XCTAssertEqual(rc?.1, 10)
        XCTAssertEqual(rc?.2, 3)
        XCTAssertNil(FirmwareGuidance.parse("v1.2.3"))
    }
}
