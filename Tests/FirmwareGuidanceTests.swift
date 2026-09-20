import XCTest
@testable import Pocket

/// Reader firmware guidance aligned with the reader's OTA update path.
final class FirmwareGuidanceTests: XCTestCase {
    func testOlderReleaseTriggersUpdateAdvice() {
        XCTAssertEqual(FirmwareGuidance.advise(readerVersion: "1.6.5"),
                       .updateAvailable(current: "1.6.5", minimum: "1.6.6"))
        XCTAssertEqual(FirmwareGuidance.advise(readerVersion: "1.4.1"),
                       .updateAvailable(current: "1.4.1", minimum: "1.6.6"))
    }

    func testCurrentAndNewerAreUpToDate() {
        XCTAssertEqual(FirmwareGuidance.advise(readerVersion: "1.6.6"), .upToDate)
        XCTAssertEqual(FirmwareGuidance.advise(readerVersion: "1.7.0"), .upToDate)
        XCTAssertEqual(FirmwareGuidance.advise(readerVersion: "1.6.6-something"), .upToDate)
    }

    func testDevelopmentBuildsNeverNag() {
        XCTAssertEqual(FirmwareGuidance.advise(readerVersion: "1.4.1-dev-main-a1b2c3d-w1234"), .developmentBuild)
        XCTAssertEqual(FirmwareGuidance.advise(readerVersion: "DEMO 1.0"), .developmentBuild)
    }

    func testUnparseableVersionIsUnknown() {
        XCTAssertEqual(FirmwareGuidance.advise(readerVersion: "weird"), .unknownFormat)
        XCTAssertEqual(FirmwareGuidance.advise(readerVersion: ""), .unknownFormat)
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
