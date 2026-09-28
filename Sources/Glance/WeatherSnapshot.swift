import CoreLocation
import Foundation
import WeatherKit

/// Apple Weather for the city the user chose, cached so the reader can still
/// get it later (for example over a direct connection without internet).
struct WeatherSnapshot: Codable, Equatable, Sendable {
    struct Hour: Codable, Equatable, Sendable {
        var date: Date
        var precipitationChance: Int  // percent
    }
    struct Day: Codable, Equatable, Sendable {
        var date: Date
        var code: Int
        var summary: String
        var minC: Int
        var maxC: Int
        var precipitationChance: Int
    }
    var fetched: Date
    var place: String
    var currentCode: Int
    var currentTempC: Int
    var currentSummary: String
    var hours: [Hour]
    var days: [Day]
}

/// The city whose weather is shown. Its coordinates come from the Apple
/// geocoder for the name the user typed; the device's own location is never
/// read for weather.
struct WeatherPlace: Codable, Equatable, Sendable {
    var name: String
    var latitude: Double
    var longitude: Double
}

enum WeatherSource {
    enum Failure: LocalizedError, Equatable {
        case notFound, lookupUnavailable, unavailable(String)
        var errorDescription: String? {
            switch self {
            case .notFound: "No city matched that name. Try a nearby larger city or add the country."
            case .lookupUnavailable: "The city could not be looked up right now. Check the internet connection and try again; the current city is kept."
            case let .unavailable(reason): "Apple Weather is unavailable right now (\(reason)). The reader keeps its last weather."
            }
        }
    }

    /// Resolves a typed city name; only the city's coordinates are kept.
    @MainActor static func place(named name: String) async throws -> WeatherPlace {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw Failure.notFound }
        let geocoder = CLGeocoder()
        let marks: [CLPlacemark]
        do {
            marks = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await geocoder.geocodeAddressString(query)
            } onCancel: {
                Task { @MainActor in geocoder.cancelGeocode() }
            }
        } catch {
            try Task.checkCancellation()
            if error is CancellationError { throw error }
            if (error as? CLError)?.code == .geocodeFoundNoResult { throw Failure.notFound }
            throw Failure.lookupUnavailable
        }
        try Task.checkCancellation()
        guard let mark = marks.first, let location = mark.location else { throw Failure.notFound }
        let label = mark.locality ?? mark.name ?? query
        return WeatherPlace(name: label, latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
    }

    static func fetch(for place: WeatherPlace, now: Date = Date()) async throws -> WeatherSnapshot {
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        do {
            let (current, hourly, daily) = try await WeatherService.shared.weather(
                for: location, including: .current, .hourly, .daily)
            return WeatherSnapshot(
                fetched: now, place: place.name,
                currentCode: wmoCode(current.condition),
                currentTempC: Int(current.temperature.converted(to: .celsius).value.rounded()),
                currentSummary: current.condition.description,
                hours: hourly.forecast.prefix(36).map {
                    .init(date: $0.date, precipitationChance: Int(($0.precipitationChance * 100).rounded()))
                },
                days: daily.forecast.prefix(7).map {
                    .init(date: $0.date, code: wmoCode($0.condition), summary: $0.condition.description,
                          minC: Int($0.lowTemperature.converted(to: .celsius).value.rounded()),
                          maxC: Int($0.highTemperature.converted(to: .celsius).value.rounded()),
                          precipitationChance: Int(($0.precipitationChance * 100).rounded()))
                })
        } catch {
            throw Failure.unavailable(error.localizedDescription)
        }
    }

    /// The legal attribution Apple requires wherever its weather is shown.
    static func attribution() async -> (mark: URL, markDark: URL, legal: URL)? {
        guard let attribution = try? await WeatherService.shared.attribution else { return nil }
        return (attribution.combinedMarkLightURL, attribution.combinedMarkDarkURL, attribution.legalPageURL)
    }

    /// Apple Weather conditions as the WMO codes the reader's glyphs use.
    static func wmoCode(_ condition: WeatherCondition) -> Int {
        switch condition {
        case .clear, .hot, .frigid: 0
        case .mostlyClear: 1
        case .partlyCloudy: 2
        case .mostlyCloudy, .cloudy, .breezy, .windy: 3
        case .foggy, .haze, .smoky, .blowingDust: 45
        case .drizzle: 51
        case .freezingDrizzle: 56
        case .sunShowers: 80
        case .rain: 63
        case .heavyRain: 65
        case .freezingRain: 66
        case .sleet, .wintryMix: 67
        case .flurries, .sunFlurries: 71
        case .snow, .blowingSnow: 73
        case .heavySnow, .blizzard: 75
        case .hail: 96
        case .isolatedThunderstorms, .scatteredThunderstorms, .thunderstorms, .strongStorms: 95
        case .tropicalStorm, .hurricane: 99
        @unknown default: 3
        }
    }
}
