import Foundation
import OSLog

private let logger = Logger(subsystem: "de.juliankahnert.HeadsUpKit", category: "CalendarService")

/// The main actor's view of the calendar: it owns the cached `CalendarSnapshot` every synchronous
/// reader decides on, and it coalesces the triggers that ask for a new one.
@Observable
final class CalendarService {
    private static let selectedCalendarIDsKey = "selectedCalendarIDs"
    /// How old a snapshot may get before the poll loop asks for a new one. Kept below the loop's
    /// 30 s idle sleep so staleness never turns on how far `Task.sleep` overshoots.
    private static let maxSnapshotAge: TimeInterval = 25
    /// A `.poll` tick landing this soon after the last fetch would learn nothing; every
    /// event-driven reason goes through regardless of it.
    private static let minimumPollGap: TimeInterval = 5

    private(set) var snapshot = CalendarSnapshot.empty

    private let store = CalendarStore()
    private var refreshTask: Task<Void, Never>?
    /// Reasons still waiting for a fetch. A trigger arriving mid-flight is not answered with that
    /// fetch's data — its reason survives here and earns a follow-up fetch of its own.
    private var pendingReasons: Set<RefreshReason> = []
    private var lastFetchStart = Date.distantPast

    var selectedCalendarIDs: Set<String> {
        get {
            Set(UserDefaults.standard.stringArray(forKey: Self.selectedCalendarIDsKey) ?? [])
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: Self.selectedCalendarIDsKey)
        }
    }

    var isSnapshotStale: Bool {
        Date.now.timeIntervalSince(snapshot.fetchedAt) >= Self.maxSnapshotAge
    }

    func requestAccess() async {
        await store.requestAccess()
    }

    /// Replaces the snapshot with what the store says now.
    ///
    /// Single-flight, because a wake delivers wake, unlock, clock change and store change at
    /// essentially the same instant and those must cost one fetch rather than four — but the
    /// reasons themselves are never dropped. A trigger that arrives too late to be part of the
    /// running fetch would otherwise be answered with data gathered before it happened: a
    /// deletion judged as a poll, or a calendar toggle read before the click landed.
    func refresh(reason: RefreshReason) async {
        if reason == .poll, Date.now.timeIntervalSince(lastFetchStart) < Self.minimumPollGap {
            return
        }

        pendingReasons.insert(reason)
        if let inFlight = refreshTask {
            await inFlight.value
            return
        }

        while !pendingReasons.isEmpty {
            let reasons = pendingReasons
            pendingReasons = []
            lastFetchStart = .now
            // Read here, not inside the task: a toggle landing after this point belongs to the
            // follow-up fetch, not to this one.
            let selected = selectedCalendarIDs
            let task = Task {
                snapshot = await store.fetch(now: .now, selectedCalendarIDs: selected, reasons: reasons)
            }
            refreshTask = task
            await task.value
            refreshTask = nil
        }
    }

    func isSelected(id: String) -> Bool {
        selectedCalendarIDs.contains(id)
    }

    func toggleCalendar(id: String) {
        var ids = selectedCalendarIDs
        let title = snapshot.calendars.first { $0.id == id }?.title ?? id
        if ids.contains(id) {
            ids.remove(id)
            logger.debug("Deselected calendar: \(title)")
        } else {
            ids.insert(id)
            logger.debug("Selected calendar: \(title)")
        }
        selectedCalendarIDs = ids
    }
}
