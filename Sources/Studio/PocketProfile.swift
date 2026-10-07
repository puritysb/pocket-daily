import Foundation

/// Pocket Daily profile v1 (sibling docs/pocket-profile-v1.md): Home item order
/// and visibility, the weather panel and next-event line, and the sleep frame.
/// The reader stores it; the app edits a copy and sends the whole document.
struct PocketProfile: Equatable, Sendable, Codable {
    /// Wire IDs are the firmware's; `study` is the companion's own cards.
    enum HomeItem: String, CaseIterable, Codable, Sendable {
        case reading, study, word, provider, monitor
        var title: String {
            switch self {
            case .reading: "Continue Reading"
            case .study: "My cards"
            case .word: "Daily word"
            case .provider: "Provider cards"
            case .monitor: "Monitoring"
            }
        }
        var detail: String {
            switch self {
            case .reading: "The open book, when there is one"
            case .study: "Your shared cards, with their images"
            case .word: "A new word each day from the reader or an SD learning pack"
            case .provider: "Retired: cards from the AgentDeck daemon"
            case .monitor: "Retired: agent usage from the AgentDeck daemon"
            }
        }
    }
    enum WeatherPanel: String, CaseIterable, Codable, Sendable {
        case bottom, top, off
        var title: String { rawValue.capitalized }
    }
    enum SleepMode: String, CaseIterable, Codable, Sendable {
        case brief, reader
        var title: String { self == .brief ? "Daily Brief" : "Reader's sleep screen" }
    }
    enum SleepSection: String, CaseIterable, Codable, Sendable {
        case reading, card, study, weather, today
        var title: String {
            switch self {
            case .reading: "Continue Reading"
            case .card: "My first card"
            case .study: "Card or daily word"
            case .weather: "Weather"
            case .today: "Today's schedule"
            }
        }
        var detail: String {
            switch self {
            case .reading: "The open book and its cover"
            case .card: "Always shown, with its image (for example, contact details)"
            case .study: "Shown only when no book is open"
            case .weather: "Apple Weather for your city, sent by this app"
            case .today: "Today's events from your calendars, sent by this app"
            }
        }
    }

    /// IDs every profile-capable reader accepts (firmware before `word`/`card`).
    static let baseHomeItems: Set<HomeItem> = [.reading, .study, .provider, .monitor]
    /// Items whose data came only from the retired AgentDeck daemon. Readers
    /// still parse them; the app neither offers nor keeps them.
    static let retiredHomeItems: Set<HomeItem> = [.provider, .monitor]
    static let baseSleepSections: Set<SleepSection> = [.reading, .study, .weather, .today]
    struct Home: Equatable, Sendable, Codable {
        var items: [HomeItem]
        var dailyWord: Bool
        var weather: WeatherPanel
        var nextEvent: Bool
    }
    struct Sleep: Equatable, Sendable, Codable {
        var mode: SleepMode
        var sections: [SleepSection]
    }

    var home: Home
    var sleep: Sleep

    static let maxHomeItems = 4

    /// What a reader without a stored profile shows (its provider item, fed
    /// only by the retired daemon, never appears).
    static let defaults = PocketProfile(
        home: .init(items: [.reading, .study], dailyWord: true, weather: .bottom, nextEvent: true),
        sleep: .init(mode: .brief, sections: [.reading, .study, .weather, .today]))

    /// Without the retired daemon items; never empty.
    var withoutRetiredItems: PocketProfile {
        var profile = self
        profile.home.items.removeAll { Self.retiredHomeItems.contains($0) }
        if profile.home.items.isEmpty { profile.home.items = [.reading] }
        return profile
    }

    /// Same rules the firmware enforces; nil when the document is sendable.
    var validationError: String? {
        if home.items.isEmpty { return "Show at least one Home item." }
        if home.items.count > Self.maxHomeItems { return "Home shows at most \(Self.maxHomeItems) items." }
        if Set(home.items).count != home.items.count { return "Each Home item can appear once." }
        if sleep.sections.isEmpty { return "Show at least one sleep section." }
        if Set(sleep.sections).count != sleep.sections.count { return "Each sleep section can appear once." }
        return nil
    }

    /// The request document: schema plus exactly `home` and `sleep`.
    func requestBody() throws -> Data {
        struct Document: Encodable {
            let schema = 1
            let home: Home
            let sleep: Sleep
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(Document(home: home, sleep: sleep))
    }
}

/// A reader's stored profile with its compare-and-swap generation.
struct ReaderProfileState: Equatable, Sendable {
    let deviceID: String
    let generation: UInt32
    let profile: PocketProfile
    let maxHomeItems: Int
    /// What this reader accepts; the editor offers nothing else.
    var homeItems: Set<PocketProfile.HomeItem> = PocketProfile.baseHomeItems
    var sleepSections: Set<PocketProfile.SleepSection> = PocketProfile.baseSleepSections

    enum Failure: Error, Equatable { case malformed, identity, unsupportedSchema, unknownValue }

    private struct Wire: Decodable {
        struct Capabilities: Decodable {
            let maxHomeItems: Int?
            let homeItems: [String]?
            let sleepSections: [String]?
        }
        let schema: Int
        let deviceID: String
        let generation: UInt32
        let home: PocketProfile.Home
        let sleep: PocketProfile.Sleep
        let capabilities: Capabilities?
    }

    /// Unknown IDs from a newer reader are refused instead of silently dropped,
    /// so the app never sends back a document that loses the reader's choices.
    static func decode(_ data: Data, deviceID expected: String) throws -> ReaderProfileState {
        guard data.count <= 4096 else { throw Failure.malformed }
        let wire: Wire
        do { wire = try JSONDecoder().decode(Wire.self, from: data) } catch let error as DecodingError {
            if case .dataCorrupted = error { throw Failure.unknownValue }
            throw Failure.malformed
        }
        guard wire.schema == 1 else { throw Failure.unsupportedSchema }
        guard wire.deviceID == expected else { throw Failure.identity }
        let profile = PocketProfile(home: wire.home, sleep: wire.sleep)
        guard profile.validationError == nil else { throw Failure.malformed }
        // Capability names this app does not know yet are ignored; the document
        // itself may only use known IDs (checked above).
        let homeItems = wire.capabilities?.homeItems.map { Set($0.compactMap(PocketProfile.HomeItem.init(rawValue:))) }
        let sleepSections = wire.capabilities?.sleepSections
            .map { Set($0.compactMap(PocketProfile.SleepSection.init(rawValue:))) }
        return .init(deviceID: wire.deviceID, generation: wire.generation, profile: profile,
                     maxHomeItems: wire.capabilities?.maxHomeItems ?? PocketProfile.maxHomeItems,
                     homeItems: homeItems ?? PocketProfile.baseHomeItems,
                     sleepSections: sleepSections ?? PocketProfile.baseSleepSections)
    }
}
