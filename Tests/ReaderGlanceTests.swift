import XCTest
@testable import Pocket

/// Weather and events composed for the reader (sibling docs/pocket-glance-v1.md).
final class ReaderGlanceTests: XCTestCase {
    func testCancelledCityLookupDoesNotResolve() async {
        let lookup = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await WeatherSource.place(named: "Seoul")
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }
        let cancelled = await lookup.value
        XCTAssertTrue(cancelled, "Cancellation must stop before requesting a city lookup")
    }

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        return calendar
    }()
    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
    private func snapshot(fetched: Date) -> WeatherSnapshot {
        WeatherSnapshot(
            fetched: fetched, place: "Seoul Special City", currentCode: 3, currentTempC: 18,
            currentSummary: "Mostly Cloudy",
            hours: (0..<24).map { .init(date: at(25, $0), precipitationChance: (14...16).contains($0) ? 60 : 10) },
            days: (24...31).map {
                .init(date: at($0, 0), code: 2, summary: "Partly Cloudy", minC: 12, maxC: 21 + $0 - 25,
                      precipitationChance: 20)
            })
    }

    func testEventsAreTheRestOfTodayAllDayFirstAndCapped() {
        let now = at(25, 10)
        let events = [
            CalendarItem(title: "Earlier", start: at(25, 8), end: at(25, 9), allDay: false),
            CalendarItem(title: "Standup", start: at(25, 9, 30), end: at(25, 10, 30), allDay: false),
            CalendarItem(title: "Lunch with Min", start: at(25, 13), end: at(25, 14), allDay: false),
            CalendarItem(title: "Holiday", start: at(25, 0), end: at(26, 0), allDay: true),
            CalendarItem(title: "Late review", start: at(25, 17), end: at(25, 18), allDay: false),
            CalendarItem(title: "Tomorrow", start: at(26, 9), end: at(26, 10), allDay: false),
        ]
        let glance = ReaderGlance.compose(weather: nil, events: events, now: now, calendar: calendar)
        XCTAssertEqual(glance.events.map(\.title), ["Holiday", "Standup", "Lunch with Min"])
        XCTAssertEqual(glance.events[0].startHm, "", "All-day events have no time")
        XCTAssertEqual(glance.events[1].startHm, "09:30")
        XCTAssertEqual(glance.events[1].endHm, "10:30")
        XCTAssertEqual(glance.syncedHm, "10:00")
        XCTAssertEqual(glance.savedEpoch, Int(now.timeIntervalSince1970))
        XCTAssertNil(glance.weather)
    }

    func testWeatherStartsTodayFindsTheRainWindowAndFitsTheReaderFields() throws {
        let now = at(25, 10)
        let glance = ReaderGlance.compose(weather: snapshot(fetched: at(25, 9)), events: [], now: now, calendar: calendar)
        let weather = try XCTUnwrap(glance.weather)
        XCTAssertEqual(weather.place, "Seoul Special City")
        XCTAssertLessThanOrEqual(weather.place.utf8.count, ReaderGlance.placeBytes)
        XCTAssertEqual(weather.summary, "Cloudy", "A short word fits the reader's field")
        XCTAssertEqual(weather.days.first?.summary, "Part cloudy")
        XCTAssertTrue((0...99).allSatisfy { ReaderGlance.shortSummary(code: $0).utf8.count <= ReaderGlance.summaryBytes })
        XCTAssertEqual(weather.days.count, 5)
        XCTAssertEqual(weather.days.first?.date, "2026-09-25", "Yesterday is dropped")
        XCTAssertEqual(weather.todayMinC, 12)
        XCTAssertEqual(weather.todayMaxC, 21)
        XCTAssertEqual(weather.rainStartHm, "14:00")
        XCTAssertEqual(weather.rainEndHm, "17:00")
        XCTAssertEqual(weather.rainProbability, 60)
    }

    func testOldWeatherIsNotSent() {
        let glance = ReaderGlance.compose(weather: snapshot(fetched: at(24, 20)), events: [], now: at(25, 10),
                                          calendar: calendar)
        XCTAssertNil(glance.weather, "Older than 12 hours")
    }

    func testRequestDocumentShape() throws {
        let glance = ReaderGlance.compose(weather: snapshot(fetched: at(25, 9)),
                                          events: [.init(title: "Standup", start: at(25, 11), end: at(25, 12), allDay: false)],
                                          now: at(25, 10), calendar: calendar)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: glance.requestBody()) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["schema", "savedEpoch", "syncedHm", "utcOffsetMinutes", "weather", "events"])
        XCTAssertEqual(json["utcOffsetMinutes"] as? Int, 540, "Seoul is UTC+9")
        XCTAssertEqual(json["schema"] as? Int, 1)
        let weather = try XCTUnwrap(json["weather"] as? [String: Any])
        XCTAssertEqual(Set(weather.keys), ["place", "code", "tempC", "summary", "todayMinC", "todayMaxC",
                                           "rainStartHm", "rainEndHm", "rainProbability", "days"])
        let empty = ReaderGlance.compose(weather: nil, events: [], now: at(25, 10), calendar: calendar)
        let emptyJSON = try XCTUnwrap(try JSONSerialization.jsonObject(with: empty.requestBody()) as? [String: Any])
        XCTAssertTrue(emptyJSON["weather"] is NSNull, "No city means no weather, stated explicitly")
    }

    func testTitlesBecomeOneLineTheReaderAccepts() {
        let now = at(25, 10)
        let events = [
            CalendarItem(title: "Plan\nreview\t with  Min", start: at(25, 11), end: at(25, 12), allDay: false),
            CalendarItem(title: " \n\t ", start: at(25, 13), end: at(25, 14), allDay: false),
        ]
        let glance = ReaderGlance.compose(weather: nil, events: events, now: now, calendar: calendar)
        XCTAssertEqual(glance.events.map(\.title), ["Plan review with Min"], "Blank titles are left out")
        XCTAssertEqual("A\u{85}B\u{7}C".readerLine, "A B C")
    }

    func testUTF8PrefixKeepsWholeCharacters() {
        XCTAssertEqual("서울특별시".utf8Prefix(11), "서울특")
        XCTAssertEqual("Seoul".utf8Prefix(11), "Seoul")
        XCTAssertEqual("🌧️Rain".utf8Prefix(3), "")
    }

    @MainActor func testSettingsCacheWeatherAndRefreshOnlyWhenStale() async throws {
        let suite = "glance-tests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        final class Counter: @unchecked Sendable { var calls = 0 }
        let counter = Counter()
        let fetched = snapshot(fetched: at(25, 9))
        var clock = at(25, 9)
        let settings = GlanceSettings(defaults: defaults, fetch: { _ in counter.calls += 1; return fetched },
                                      now: { clock })
        XCTAssertFalse(settings.isConfigured)
        settings.setPlace(.init(name: "Seoul Special City", latitude: 37.57, longitude: 126.98))
        await settings.refreshWeatherIfNeeded()
        await settings.refreshWeatherIfNeeded()
        XCTAssertEqual(counter.calls, 1, "Fresh weather is reused")
        clock = at(25, 10)
        await settings.refreshWeatherIfNeeded()
        XCTAssertEqual(counter.calls, 2)
        // The cache survives relaunch for the same city.
        let reopened = GlanceSettings(defaults: defaults, fetch: { _ in throw URLError(.notConnectedToInternet) },
                                      now: { clock })
        XCTAssertEqual(reopened.weather, fetched)
        await reopened.refreshWeatherIfNeeded(force: true)
        XCTAssertEqual(reopened.weather, fetched, "A failed refresh keeps the cache")
        XCTAssertNotNil(reopened.weatherError)
        reopened.setPlace(nil)
        XCTAssertNil(reopened.weather)
    }
}
