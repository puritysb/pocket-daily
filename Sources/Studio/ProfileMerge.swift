import Foundation

/// How app edits and the reader's own settings come together. Each field is
/// merged on its own against the reader state the edits started from:
/// a field you did not touch takes the reader's value, a field the reader did
/// not change keeps yours, and a field both changed keeps yours and is listed,
/// so Apply replacing the reader's value never happens silently.
enum ProfileMerge {
    /// The parts of the Home & Sleep layout and the reading settings, named as on screen.
    enum Field: String, CaseIterable, Codable, Sendable {
        case homeItems, dailyWord, weather, nextEvent, sleepMode, sleepSections
        case startup, sleepCover, sleepTimeout, textSize, sideButtons, frontButtons, wakeCue

        var title: String {
            switch self {
            case .homeItems: "Home pages"
            case .dailyWord: "Daily word"
            case .weather: "Daily panel"
            case .nextEvent: "Next event"
            case .sleepMode: "Sleep screen"
            case .sleepSections: "Sleep sections"
            case .startup: "Open at startup"
            case .sleepCover: "Book cover"
            case .sleepTimeout: "Sleep after"
            case .textSize: "Text size"
            case .sideButtons: "Side buttons"
            case .frontButtons: "Front buttons"
            case .wakeCue: "WAKE on sleep screen"
            }
        }
    }

    /// What a merge did, for the notice beside Apply.
    struct Report: Equatable, Sendable {
        /// Changed on the reader and taken, because you had not edited them.
        var fromReader: [Field] = []
        /// Changed on both; your edit is kept and Apply replaces the reader's.
        var bothChanged: [Field] = []

        var isEmpty: Bool { fromReader.isEmpty && bothChanged.isEmpty }

        mutating func add(_ other: Report) {
            fromReader += other.fromReader
            bothChanged += other.bothChanged
        }
    }

    private static func merge<Value: Equatable>(_ field: Field, base: Value, mine: inout Value, reader: Value,
                                                into report: inout Report) {
        guard reader != base else { return }               // the reader did not change it
        if mine == base { mine = reader; report.fromReader.append(field) }
        else if mine != reader { report.bothChanged.append(field) }
    }

    static func merge(base: PocketProfile, mine: PocketProfile, reader: PocketProfile)
        -> (profile: PocketProfile, report: Report) {
        var merged = mine
        var report = Report()
        merge(.homeItems, base: base.home.items, mine: &merged.home.items, reader: reader.home.items, into: &report)
        merge(.dailyWord, base: base.home.dailyWord, mine: &merged.home.dailyWord, reader: reader.home.dailyWord, into: &report)
        merge(.weather, base: base.home.weather, mine: &merged.home.weather, reader: reader.home.weather, into: &report)
        merge(.nextEvent, base: base.home.nextEvent, mine: &merged.home.nextEvent, reader: reader.home.nextEvent, into: &report)
        merge(.sleepMode, base: base.sleep.mode, mine: &merged.sleep.mode, reader: reader.sleep.mode, into: &report)
        merge(.sleepSections, base: base.sleep.sections, mine: &merged.sleep.sections, reader: reader.sleep.sections,
              into: &report)
        return (merged, report)
    }

    static func merge(base: ReaderPreferences, mine: ReaderPreferences, reader: ReaderPreferences)
        -> (preferences: ReaderPreferences, report: Report) {
        var merged = mine
        var report = Report()
        merge(.startup, base: base.startupApp, mine: &merged.startupApp, reader: reader.startupApp, into: &report)
        merge(.sleepCover, base: base.pocketDailySleepCover, mine: &merged.pocketDailySleepCover,
              reader: reader.pocketDailySleepCover, into: &report)
        merge(.sleepTimeout, base: base.sleepTimeoutMinutes, mine: &merged.sleepTimeoutMinutes,
              reader: reader.sleepTimeoutMinutes, into: &report)
        merge(.textSize, base: base.fontSize, mine: &merged.fontSize, reader: reader.fontSize, into: &report)
        merge(.sideButtons, base: base.sideButtons, mine: &merged.sideButtons, reader: reader.sideButtons, into: &report)
        merge(.frontButtons, base: base.frontButtonsFollowOrientation, mine: &merged.frontButtonsFollowOrientation,
              reader: reader.frontButtonsFollowOrientation, into: &report)
        merge(.wakeCue, base: base.sleepWakeIndicator, mine: &merged.sleepWakeIndicator,
              reader: reader.sleepWakeIndicator, into: &report)
        // A setting the reader does not offer is never sent back.
        if reader.sideButtons == nil { merged.sideButtons = nil }
        if reader.frontButtonsFollowOrientation == nil { merged.frontButtonsFollowOrientation = nil }
        if reader.sleepWakeIndicator == nil { merged.sleepWakeIndicator = nil }
        return (merged, report)
    }

    /// Fields where `mine` differs from `reader`: what Apply would change.
    static func pending(profile mine: PocketProfile, reader: PocketProfile) -> [Field] {
        var fields: [Field] = []
        if mine.home.items != reader.home.items { fields.append(.homeItems) }
        if mine.home.dailyWord != reader.home.dailyWord { fields.append(.dailyWord) }
        if mine.home.weather != reader.home.weather { fields.append(.weather) }
        if mine.home.nextEvent != reader.home.nextEvent { fields.append(.nextEvent) }
        if mine.sleep.mode != reader.sleep.mode { fields.append(.sleepMode) }
        if mine.sleep.sections != reader.sleep.sections { fields.append(.sleepSections) }
        return fields
    }

    static func pending(preferences mine: ReaderPreferences, reader: ReaderPreferences) -> [Field] {
        var fields: [Field] = []
        if mine.startupApp != reader.startupApp { fields.append(.startup) }
        if mine.pocketDailySleepCover != reader.pocketDailySleepCover { fields.append(.sleepCover) }
        if mine.sleepTimeoutMinutes != reader.sleepTimeoutMinutes { fields.append(.sleepTimeout) }
        if mine.fontSize != reader.fontSize { fields.append(.textSize) }
        if mine.sideButtons != reader.sideButtons { fields.append(.sideButtons) }
        if mine.frontButtonsFollowOrientation != reader.frontButtonsFollowOrientation { fields.append(.frontButtons) }
        if mine.sleepWakeIndicator != reader.sleepWakeIndicator { fields.append(.wakeCue) }
        return fields
    }

    /// Puts the reader's value back for `fields` (the notice's "Use the reader's").
    static func take(_ fields: [Field], from reader: PocketProfile, into mine: inout PocketProfile) {
        for field in fields {
            switch field {
            case .homeItems: mine.home.items = reader.home.items
            case .dailyWord: mine.home.dailyWord = reader.home.dailyWord
            case .weather: mine.home.weather = reader.home.weather
            case .nextEvent: mine.home.nextEvent = reader.home.nextEvent
            case .sleepMode: mine.sleep.mode = reader.sleep.mode
            case .sleepSections: mine.sleep.sections = reader.sleep.sections
            default: break
            }
        }
    }

    static func take(_ fields: [Field], from reader: ReaderPreferences, into mine: inout ReaderPreferences) {
        for field in fields {
            switch field {
            case .startup: mine.startupApp = reader.startupApp
            case .sleepCover: mine.pocketDailySleepCover = reader.pocketDailySleepCover
            case .sleepTimeout: mine.sleepTimeoutMinutes = reader.sleepTimeoutMinutes
            case .textSize: mine.fontSize = reader.fontSize
            case .sideButtons: mine.sideButtons = reader.sideButtons
            case .frontButtons: mine.frontButtonsFollowOrientation = reader.frontButtonsFollowOrientation
            case .wakeCue: mine.sleepWakeIndicator = reader.sleepWakeIndicator
            default: break
            }
        }
    }
}

/// Unsent Home & Sleep and reading-setting edits with the reader state they
/// started from, kept on disk so quitting the app does not lose them.
struct ProfileEditSnapshot: Codable, Equatable, Sendable {
    var schema = 1
    var draft: PocketProfile
    var base: PocketProfile
    var baseGeneration: UInt32?
    var reading: ReaderPreferences
    var readingBase: ReaderPreferences
    var savedAt: Date
}

/// `Application Support/Pocket/Studio/profile-edits.json`, beside the card
/// drafts. Off in hosted tests, which share the user's container.
struct ProfileEditStore: Sendable {
    let url: URL?

    static let live = ProfileEditStore(url: ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        ? nil
        : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Pocket/Studio/profile-edits.json"))

    func load() -> ProfileEditSnapshot? {
        guard let url, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ProfileEditSnapshot.self, from: data),
              snapshot.schema == 1 else { return nil }
        return snapshot
    }

    /// Writes the snapshot atomically, or removes the file when nothing is unsent.
    func save(_ snapshot: ProfileEditSnapshot?) throws {
        guard let url else { return }
        guard let snapshot else {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
