import EventKit
import Foundation

/// Today's events from the calendars on this device. Access is requested only
/// when the user turns calendar events on; nothing leaves the device except to
/// the user's reader.
enum CalendarSource {
    static var isAuthorized: Bool { EKEventStore.authorizationStatus(for: .event) == .fullAccess }
    static var isDenied: Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        return status == .denied || status == .restricted
    }

    static func requestAccess() async -> Bool {
        (try? await EKEventStore().requestFullAccessToEvents()) ?? false
    }

    /// Events overlapping the rest of today, from every calendar.
    static func today(now: Date = Date(), calendar: Calendar = .current) -> [CalendarItem] {
        guard isAuthorized else { return [] }
        let store = EKEventStore()
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let predicate = store.predicateForEvents(withStart: calendar.startOfDay(for: now), end: end, calendars: nil)
        return store.events(matching: predicate)
            .filter { $0.status != .canceled }
            .map { CalendarItem(title: $0.title ?? "", start: $0.startDate, end: $0.endDate, allDay: $0.isAllDay) }
            .filter { !$0.title.isEmpty }
    }
}
