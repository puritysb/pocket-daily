import EventKit
import Foundation

/// Today's events from the calendars on this device. Access is requested only
/// when the user turns calendar events on; nothing leaves the device except to
/// the user's reader.
enum CalendarSource {
    struct Choice: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let source: String
    }

    static func availableCalendars() -> [Choice] {
        guard isAuthorized else { return [] }
        return EKEventStore().calendars(for: .event)
            .map { Choice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title) }
            .sorted { ($0.source, $0.title, $0.id) < ($1.source, $1.title, $1.id) }
    }

    /// A missing selected calendar stays missing; never fall back to all.
    static func selectedIDs(available: [String], selection: [String]?) -> [String] {
        guard let selection else { return available }
        let chosen = Set(selection)
        return available.filter { chosen.contains($0) }
    }

    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// Events overlapping the rest of today, from every calendar.
    static func today(now: Date = Date(), calendar: Calendar = .current, selectedCalendarIDs: [String]? = nil) -> [CalendarItem] {
        guard isAuthorized else { return [] }
        let store = EKEventStore()
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let calendars = store.calendars(for: .event)
        let ids = Set(selectedIDs(available: calendars.map(\.calendarIdentifier), selection: selectedCalendarIDs))
        let selected = calendars.filter { ids.contains($0.calendarIdentifier) }
        guard !selected.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: calendar.startOfDay(for: now), end: end, calendars: selected)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { CalendarItem(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay) }
            .filter { !$0.title.isEmpty }
    }
}
