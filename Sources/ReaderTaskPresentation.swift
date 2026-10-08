import Foundation

extension StudioSection {
    /// A real operation's owner, independent of generic working/message state.
    static func owner(of task: ReaderTaskDestination) -> StudioSection? {
        switch task {
        case .bookTransfer: nil
        case .readerInventory, .preparedFiles: .reader
        case .screens, .reading, .cards, .weatherCalendar: .customize
        case .firmware, .connection, .diagnostics: .device
        }
    }
}

extension ReaderTaskDestination {
    var title: String {
        switch self {
        case .bookTransfer: "Book transfer"
        case .readerInventory: "Reader files"
        case .screens: "Screen changes"
        case .reading: "Reading settings"
        case .cards: "My cards"
        case .weatherCalendar: "Weather & calendar"
        case .firmware: "Firmware update"
        case .connection: "Reader connection"
        case .diagnostics: "Device details"
        case .preparedFiles: "File transfer"
        }
    }
}
