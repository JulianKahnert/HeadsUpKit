import EventKit
import OSLog

private let logger = Logger(subsystem: "de.juliankahnert.HeadsUpKit", category: "CalendarService")

@Observable
final class CalendarService {
    private static let selectedCalendarIDsKey = "selectedCalendarIDs"

    private let store = EKEventStore()

    var allCalendars: [EKCalendar] {
        store.calendars(for: .event)
    }

    var selectedCalendarIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: Self.selectedCalendarIDsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.selectedCalendarIDsKey)
        }
    }

    var nextEvent: EKEvent? {
        let now = Date.now
        let end = now.addingTimeInterval(24 * 60 * 60)
        let ids = selectedCalendarIDs
        let filtered = ids.isEmpty ? [] : allCalendars.filter { ids.contains($0.calendarIdentifier) }
        // nil = all calendars, empty array would return nothing
        let calendars: [EKCalendar]? = filtered.isEmpty ? nil : filtered
        let predicate = store.predicateForEvents(withStart: now, end: end, calendars: calendars)
        let events = store.events(matching: predicate)
        // Skip events that already started — only return truly upcoming ones
        return events.first { $0.startDate > now }
    }

    func isSelected(_ calendar: EKCalendar) -> Bool {
        selectedCalendarIDs.contains(calendar.calendarIdentifier)
    }

    func toggleCalendar(_ calendar: EKCalendar) {
        var ids = selectedCalendarIDs
        if ids.contains(calendar.calendarIdentifier) {
            ids.remove(calendar.calendarIdentifier)
            logger.debug("Deselected calendar: \(calendar.title)")
        } else {
            ids.insert(calendar.calendarIdentifier)
            logger.debug("Selected calendar: \(calendar.title)")
        }
        selectedCalendarIDs = ids
    }

    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            logger.info("Calendar access granted: \(granted)")
        } catch {
            logger.error("Calendar access error: \(error)")
        }
    }
}
