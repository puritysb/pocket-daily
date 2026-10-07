import XCTest
@testable import Pocket

final class ReaderTaskPresentationTests: XCTestCase {
    func testInventoryAndTransfersReturnToTheirOwningSurface() {
        XCTAssertEqual(StudioSection.owner(of: .readerInventory), .files)
        XCTAssertEqual(StudioSection.owner(of: .preparedFiles), .files)
        XCTAssertNil(StudioSection.owner(of: .bookTransfer(UUID())), "A book task must reopen its exact job rather than an unrelated device menu")
    }

    func testEditorsAndFirmwareHaveDistinctOwners() {
        XCTAssertEqual(StudioSection.owner(of: .screens), .layout)
        XCTAssertEqual(StudioSection.owner(of: .reading), .reading)
        XCTAssertEqual(StudioSection.owner(of: .cards), .layout)
        XCTAssertEqual(StudioSection.owner(of: .weatherCalendar), .layout)
        XCTAssertEqual(StudioSection.owner(of: .firmware), .device)
        XCTAssertEqual(StudioSection.owner(of: .connection), .device)
        XCTAssertEqual(StudioSection.owner(of: .diagnostics), .device)
    }
}
