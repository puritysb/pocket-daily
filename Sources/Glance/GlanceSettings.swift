import Foundation

/// The weather city and calendar choice, and the cached Apple Weather, kept on
/// this device. The reader receives only the composed ReaderGlance.
@MainActor
final class GlanceSettings: ObservableObject {
    @Published private(set) var place: WeatherPlace?
    @Published private(set) var includeEvents: Bool
    /// Nil means all calendars (the previous default); [] deliberately means none.
    @Published private(set) var selectedCalendarIDs: [String]?
    @Published private(set) var hasUnappliedSourceChanges: Bool
    @Published private(set) var weather: WeatherSnapshot?
    @Published private(set) var weatherError: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var sourceRevision: Int
    private var weatherWork: Task<WeatherSnapshot, Error>?
    private var weatherRequestID: UUID?
    private let defaults: UserDefaults
    private let fetch: @Sendable (WeatherPlace) async throws -> WeatherSnapshot
    private let now: @Sendable () -> Date

    private enum Key {
        static let place = "glance.weatherPlace"
        static let events = "glance.includeEvents"
        static let calendars = "glance.selectedCalendarIDs"
        static let revision = "glance.sourceRevision"
        static let pending = "glance.sourcesPendingApply"
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
        selectedCalendarIDs = defaults.stringArray(forKey: Key.calendars)
        hasUnappliedSourceChanges = defaults.bool(forKey: Key.pending)
        sourceRevision = defaults.integer(forKey: Key.revision)
        weather = defaults.data(forKey: Key.weather).flatMap { try? decoder.decode(WeatherSnapshot.self, from: $0) }
        if weather?.place != place?.name { weather = nil }
    }

    /// Something to send: a city or calendar events.
    var isConfigured: Bool { place != nil || includeEvents }

    func setPlace(_ place: WeatherPlace?) {
        guard self.place != place else { return }
        markSourcesChanged()
        weatherWork?.cancel()
        weatherWork = nil
        weatherRequestID = nil
        isRefreshing = false
        self.place = place
        weather = nil
        weatherError = nil
        defaults.set(place.flatMap { try? JSONEncoder().encode($0) }, forKey: Key.place)
        defaults.removeObject(forKey: Key.weather)
    }

    func setIncludeEvents(_ include: Bool) {
        guard includeEvents != include else { return }
        markSourcesChanged()
        includeEvents = include
        defaults.set(include, forKey: Key.events)
    }

    func setSelectedCalendarIDs(_ ids: [String]?) {
        let normalized = ids.map { Array(Set($0)).sorted() }
        guard normalized != selectedCalendarIDs else { return }
        selectedCalendarIDs = normalized
        defaults.set(normalized, forKey: Key.calendars)
        markSourcesChanged()
    }

    private func markSourcesChanged() {
        sourceRevision += 1
        defaults.set(sourceRevision, forKey: Key.revision)
        hasUnappliedSourceChanges = true
        defaults.set(true, forKey: Key.pending)
    }

    /// Called only after explicit content Apply has succeeded.
    func markSourcesApplied(ifRevision revision: Int) {
        guard revision == sourceRevision else { return }
        hasUnappliedSourceChanges = false
        defaults.set(false, forKey: Key.pending)
    }

    /// Fetches Apple Weather when the cache is missing or older than the
    /// refresh interval. Failures keep the cache and say why.
    func refreshWeatherIfNeeded(force: Bool = false) async {
        guard let place, !isRefreshing else { return }
        if !force, let weather, now().timeIntervalSince(weather.fetched) < Self.refreshInterval { return }
        let requestID = UUID()
        let request = Task { try await fetch(place) }
        weatherRequestID = requestID
        weatherWork = request
        isRefreshing = true
        defer {
            if weatherRequestID == requestID {
                isRefreshing = false
                weatherWork = nil
                weatherRequestID = nil
            }
        }
        do {
            let snapshot = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: { request.cancel() }
            guard weatherRequestID == requestID, place == self.place, !Task.isCancelled else { return }
            weather = snapshot
            weatherError = nil
            defaults.set(try? JSONEncoder().encode(snapshot), forKey: Key.weather)
        } catch {
            guard weatherRequestID == requestID, place == self.place,
                  !Task.isCancelled, !(error is CancellationError) else { return }
            weatherError = error.localizedDescription
        }
    }

    /// What the reader should show now.
    func glance(events: [CalendarItem]) -> ReaderGlance {
        ReaderGlance.compose(weather: place == nil ? nil : weather, events: includeEvents ? events : [], now: now())
    }
}
