import XCTest
@testable import Pocket

final class ReaderTaskPresentationTests: XCTestCase {
    func testInventoryAndTransfersReturnToTheirOwningSurface() {
        XCTAssertEqual(StudioSection.owner(of: .readerInventory), .reader)
        XCTAssertEqual(StudioSection.owner(of: .preparedFiles), .reader)
        XCTAssertNil(StudioSection.owner(of: .bookTransfer(UUID())), "A book task must reopen its exact job rather than an unrelated device menu")
    }

    func testEditorsAndFirmwareHaveDistinctOwners() {
        XCTAssertEqual(StudioSection.owner(of: .screens), .customize)
        XCTAssertEqual(StudioSection.owner(of: .reading), .customize)
        XCTAssertEqual(StudioSection.owner(of: .cards), .customize)
        XCTAssertEqual(StudioSection.owner(of: .weatherCalendar), .customize)
        XCTAssertEqual(StudioSection.owner(of: .firmware), .device)
        XCTAssertEqual(StudioSection.owner(of: .connection), .device)
        XCTAssertEqual(StudioSection.owner(of: .diagnostics), .device)
    }
}
