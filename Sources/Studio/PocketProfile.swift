import Foundation

/// Pocket Daily profile v1 (sibling docs/pocket-profile-v1.md): Home item order
/// and visibility, the weather panel and next-event line, and the sleep frame.
/// The reader stores it; the app edits a copy and sends the whole document.
struct PocketProfile: Equatable, Sendable, Codable {
    enum HomeItem: String, CaseIterable, Codable, Sendable {
        case reading, study, provider, monitor
        var title: String {
            switch self {
            case .reading: "Continue Reading"
            case .study: "Study cards"
            case .provider: "Provider cards"
            case .monitor: "Monitoring"
            }
        }
        var detail: String {
            switch self {
            case .reading: "The open book, when there is one"
            case .study: "Your app cards, or the daily word"
            case .provider: "Cards carried from an optional provider"
            case .monitor: "Read-only usage summary, when data was carried"
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
        case reading, study, weather, today
        var title: String {
            switch self {
            case .reading: "Continue Reading"
            case .study: "Study card"
            case .weather: "Weather"
            case .today: "Today's schedule"
            }
        }
    }
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

    /// Exactly the reader's behaviour before profiles existed.
    static let defaults = PocketProfile(
        home: .init(items: [.reading, .study, .provider], dailyWord: true, weather: .bottom, nextEvent: true),
        sleep: .init(mode: .brief, sections: [.reading, .study, .weather, .today]))

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

    enum Failure: Error, Equatable { case malformed, identity, unsupportedSchema, unknownValue }

    private struct Wire: Decodable {
        struct Capabilities: Decodable { let maxHomeItems: Int? }
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
        return .init(deviceID: wire.deviceID, generation: wire.generation, profile: profile,
                     maxHomeItems: wire.capabilities?.maxHomeItems ?? PocketProfile.maxHomeItems)
    }
}
