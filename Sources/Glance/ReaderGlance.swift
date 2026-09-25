import Foundation

/// Weather and today's events the companion sends to the reader for Pocket
/// Daily Home and the Daily Brief (sibling docs/pocket-glance-v1.md). Built on
/// this device from Apple Weather and the user's calendars; the reader only
/// stores and draws it. Field sizes are the firmware's (PocketDaily::Glance).
struct ReaderGlance: Equatable, Sendable, Encodable {
    struct Day: Equatable, Sendable, Codable {
        var date: String  // YYYY-MM-DD
        var summary: String
        var code: Int  // WMO weather code
        var minC: Int
        var maxC: Int
        var rainProbability: Int  // -1 unknown
    }
    struct Weather: Equatable, Sendable, Codable {
        var place: String
        var code: Int
        var tempC: Int
        var summary: String
        var todayMinC: Int
        var todayMaxC: Int
        var rainStartHm: String
        var rainEndHm: String
        var rainProbability: Int
        var days: [Day]
    }
    struct Event: Equatable, Sendable, Codable {
        var startHm: String  // empty for all-day
        var endHm: String
        var title: String
    }

    static let placeBytes = 23, summaryBytes = 11, titleBytes = 48
    static let dayCap = 5, eventCap = 3

    var savedEpoch: Int
    var syncedHm: String
    /// The app's UTC offset, so the reader can tell local days and times.
    var utcOffsetMinutes: Int
    var weather: Weather?
    var events: [Event]

    private enum CodingKeys: String, CodingKey { case schema, savedEpoch, syncedHm, utcOffsetMinutes, weather, events }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .schema)
        try container.encode(savedEpoch, forKey: .savedEpoch)
        try container.encode(syncedHm, forKey: .syncedHm)
        try container.encode(utcOffsetMinutes, forKey: .utcOffsetMinutes)
        try container.encode(weather, forKey: .weather)  // null when not configured
        try container.encode(events, forKey: .events)
    }

    func requestBody() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(self)
    }
}

/// One calendar event as read from EventKit.
struct CalendarItem: Equatable, Sendable {
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
}

extension ReaderGlance {
    /// Composes what the reader shows at `now`: the rest of today's events and,
    /// when the cached weather is recent enough, the weather from today on.
    static func compose(weather: WeatherSnapshot?, events: [CalendarItem], now: Date,
                        calendar: Calendar = .current) -> ReaderGlance {
        let hm = DateFormatter.pocketHourMinute(calendar)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let upcoming = events
            .filter { $0.end > now && $0.start < startOfTomorrow && !$0.title.readerLine.isEmpty }
            .sorted { ($0.allDay ? 0 : 1, $0.start) < ($1.allDay ? 0 : 1, $1.start) }
            .prefix(eventCap)
            .map { item in
                Event(startHm: item.allDay ? "" : hm.string(from: max(item.start, calendar.startOfDay(for: now))),
                      endHm: item.allDay ? "" : hm.string(from: min(item.end, startOfTomorrow.addingTimeInterval(-60))),
                      title: item.title.readerLine.utf8Prefix(titleBytes))
            }
        return ReaderGlance(savedEpoch: Int(now.timeIntervalSince1970), syncedHm: hm.string(from: now),
                            utcOffsetMinutes: calendar.timeZone.secondsFromGMT(for: now) / 60,
                            weather: weather.flatMap { composeWeather($0, now: now, calendar: calendar) },
                            events: Array(upcoming))
    }

    /// Weather older than this is not sent; the reader keeps its last copy.
    static let weatherMaximumAge: TimeInterval = 12 * 3600

    static func composeWeather(_ snapshot: WeatherSnapshot, now: Date, calendar: Calendar) -> Weather? {
        guard now.timeIntervalSince(snapshot.fetched) <= weatherMaximumAge else { return nil }
        let today = calendar.startOfDay(for: now)
        let days = snapshot.days.filter { $0.date >= today }.prefix(dayCap)
        guard let first = days.first, calendar.isDate(first.date, inSameDayAs: now) else { return nil }
        let dateFormatter = DateFormatter.pocketDay(calendar)
        let hm = DateFormatter.pocketHourMinute(calendar)
        // Rain window: the first run of hours today at 40% or more.
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        let hours = snapshot.hours.filter { $0.date >= now.addingTimeInterval(-3600) && $0.date < endOfToday }
        var rainStart = "", rainEnd = "", rainProbability = -1
        if let startIndex = hours.firstIndex(where: { $0.precipitationChance >= 40 }) {
            let run = hours[startIndex...].prefix { $0.precipitationChance >= 40 }
            rainStart = hm.string(from: run.first!.date)
            rainEnd = hm.string(from: run.last!.date.addingTimeInterval(3600))
            rainProbability = run.map(\.precipitationChance).max() ?? -1
        }
        return Weather(
            place: snapshot.place.readerLine.utf8Prefix(placeBytes), code: snapshot.currentCode,
            tempC: snapshot.currentTempC,
            summary: shortSummary(code: snapshot.currentCode),
            todayMinC: first.minC, todayMaxC: first.maxC,
            rainStartHm: rainStart, rainEndHm: rainEnd, rainProbability: rainProbability,
            days: days.map {
                Day(date: dateFormatter.string(from: $0.date), summary: shortSummary(code: $0.code),
                    code: $0.code, minC: $0.minC, maxC: $0.maxC, rainProbability: $0.precipitationChance)
            })
    }
}

extension ReaderGlance {
    /// A word that fits the reader's 11-byte summary field.
    static func shortSummary(code: Int) -> String {
        switch code {
        case 0: "Clear"
        case 1: "Fair"
        case 2: "Part cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67: "Rain"
        case 71...77: "Snow"
        case 80...82: "Showers"
        case 85, 86: "Snow shower"
        case 95...99: "Storm"
        default: ""
        }
    }
}

extension String {
    /// One line the reader accepts: control characters (line breaks, tabs)
    /// become spaces, runs of spaces collapse, ends are trimmed.
    var readerLine: String {
        let scalars = unicodeScalars.map { scalar -> Character in
            let value = scalar.value
            return value < 0x20 || (0x7F...0x9F).contains(value) ? " " : Character(scalar)
        }
        return String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }

    /// The longest prefix of whole characters that fits `bytes` UTF-8 bytes.
    func utf8Prefix(_ bytes: Int) -> String {
        guard utf8.count > bytes else { return self }
        var result = ""
        for character in self {
            guard result.utf8.count + character.utf8.count <= bytes else { break }
            result.append(character)
        }
        return result
    }
}

extension DateFormatter {
    static func pocketHourMinute(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }

    static func pocketDay(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
