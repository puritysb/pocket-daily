import Foundation

/// The weather city and calendar choice, and the cached Apple Weather, kept on
/// this device. The reader receives only the composed ReaderGlance.
@MainActor
final class GlanceSettings: ObservableObject {
    @Published private(set) var place: WeatherPlace?
    @Published private(set) var includeEvents: Bool
    @Published private(set) var weather: WeatherSnapshot?
    @Published private(set) var weatherError: String?
    @Published private(set) var isRefreshing = false
    private let defaults: UserDefaults
    private let fetch: @Sendable (WeatherPlace) async throws -> WeatherSnapshot
    private let now: @Sendable () -> Date

    private enum Key {
        static let place = "glance.weatherPlace"
        static let events = "glance.includeEvents"
        static let weather = "glance.weatherCache"
    }

    /// Weather newer than this is not fetched again.
    static let refreshInterval: TimeInterval = 30 * 60

    init(defaults: UserDefaults = .standard,
         fetch: @escaping @Sendable (WeatherPlace) async throws -> WeatherSnapshot = { try await WeatherSource.fetch(for: $0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.defaults = defaults
        self.fetch = fetch
        self.now = now
        let decoder = JSONDecoder()
        place = defaults.data(forKey: Key.place).flatMap { try? decoder.decode(WeatherPlace.self, from: $0) }
        includeEvents = defaults.bool(forKey: Key.events)
        weather = defaults.data(forKey: Key.weather).flatMap { try? decoder.decode(WeatherSnapshot.self, from: $0) }
        if weather?.place != place?.name { weather = nil }
    }

    /// Something to send: a city or calendar events.
    var isConfigured: Bool { place != nil || includeEvents }

    func setPlace(_ place: WeatherPlace?) {
        self.place = place
        weather = nil
        weatherError = nil
        defaults.set(place.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.place)
        defaults.removeObject(forKey: Key.weather)
    }

    func setIncludeEvents(_ include: Bool) {
        includeEvents = include
        defaults.set(include, forKey: Key.events)
    }

    /// Fetches Apple Weather when the cache is missing or older than the
    /// refresh interval. Failures keep the cache and say why.
    func refreshWeatherIfNeeded(force: Bool = false) async {
        guard let place, !isRefreshing else { return }
        if !force, let weather, now().timeIntervalSince(weather.fetched) < Self.refreshInterval { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            let snapshot = try await fetch(place)
            guard place == self.place else { return }
            weather = snapshot
            weatherError = nil
            defaults.set(try? JSONEncoder().encode(snapshot), forKey: Key.weather)
        } catch {
            weatherError = error.localizedDescription
        }
    }

    /// What the reader should show now.
    func glance(events: [CalendarItem]) -> ReaderGlance {
        ReaderGlance.compose(weather: place == nil ? nil : weather, events: includeEvents ? events : [], now: now())
    }
}
