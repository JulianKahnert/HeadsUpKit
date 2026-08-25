import EventKit
import OSLog

private nonisolated let logger = Logger(subsystem: "de.juliankahnert.HeadsUpKit", category: "CalendarStore")

// MARK: - Snapshot

/// Everything the app knows about the calendar, as plain values.
///
/// `EKEvent` and `EKCalendar` never leave `CalendarStore`: the SDK declares every held instance
/// invalid on `EKEventStoreChanged`, and only `Sendable` values can cross out of the actor.
nonisolated struct CalendarSnapshot: Sendable {
    /// The occurrences an overlay may be shown for, in chronological order.
    let candidates: [OverlayCandidate]
    /// What the menu lists, including the all-day and declined events `candidates` filters out.
    let menuEvents: [MenuEvent]
    let calendars: [CalendarInfo]
    let fetchedAt: Date
    let isAuthorized: Bool

    /// Dated `distantPast`, so the first poll tick treats it as stale and refreshes at once.
    static let empty = CalendarSnapshot(
        candidates: [],
        menuEvents: [],
        calendars: [],
        fetchedAt: .distantPast,
        isAuthorized: false
    )
}

/// One entry in the menu's list of upcoming events.
nonisolated struct MenuEvent: Sendable {
    /// nil for an event EventKit cannot address by URL; the menu then offers no click target.
    let eventIdentifier: String?
    let title: String
    let startDate: Date
    let color: CalendarColor

    /// Fails without a start date — it imports as an implicitly unwrapped optional, and binding
    /// it is what keeps a broken record from crashing a menu bar app nobody sees crash.
    init?(event: EKEvent) {
        guard let startDate = event.startDate else { return nil }
        eventIdentifier = event.eventIdentifier
        title = event.title ?? "Untitled"
        self.startDate = startDate
        color = CalendarColor(cgColor: event.calendar?.cgColor)
    }
}

/// One calendar in the Calendars submenu.
nonisolated struct CalendarInfo: Sendable {
    let id: String
    let title: String
    let color: CalendarColor

    init(calendar: EKCalendar) {
        id = calendar.calendarIdentifier
        title = calendar.title
        color = CalendarColor(cgColor: calendar.cgColor)
    }
}

/// A calendar's colour as sRGB components, because neither `CGColor` nor `NSColor` is `Sendable`
/// and the fetch that reads them runs off the main actor.
nonisolated struct CalendarColor: Sendable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(cgColor: CGColor?) {
        guard let cgColor,
              let srgb = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = cgColor.converted(to: srgb, intent: .defaultIntent, options: nil),
              let components = converted.components, components.count >= 4 else {
            // A calendar whose colour will not convert still deserves a visible dot.
            red = 0.5
            green = 0.5
            blue = 0.5
            alpha = 1
            return
        }
        red = components[0]
        green = components[1]
        blue = components[2]
        alpha = components[3]
    }
}

// MARK: - Store

/// Why a refresh was asked for. Two reasons steer the fetch itself: `.launch` and `.wake` pull
/// the remote sources first, and `.storeChanged` is the one trigger whose empty result is
/// trustworthy. Triggers that coalesce are carried as a set, so no reason is lost on the way in.
nonisolated enum RefreshReason: String, Sendable {
    case launch
    case poll
    case wake
    case unlock
    case clockChanged
    case storeChanged
    case dayChanged
    case timeZoneChanged
    case calendarSelection
    case menuOpened
}

/// The app's only owner of an `EKEventStore`.
///
/// Everything EventKit-shaped happens in here, off the main actor, so `AppDelegate.reconcile()`
/// can stay synchronous and decide on a snapshot of plain values.
actor CalendarStore {
    private var store = EKEventStore()
    /// The last snapshot handed out. An unexplained empty fetch is answered with it rather than
    /// blanking an alert that is already armed.
    private var accepted = CalendarSnapshot.empty
    private var suspectEmptyFetches = 0

    /// Requests calendar access and, once granted, replaces the store: an `EKEventStore` created
    /// before the grant can stay blind to every calendar.
    func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            logger.info("Calendar access granted: \(granted, privacy: .public)")
            guard granted else { return }
            rebuild()
        } catch {
            logger.error("Calendar access error: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Fetches a snapshot for every reason that has accumulated, applying whatever store hygiene
    /// the situation calls for.
    func fetch(now: Date, selectedCalendarIDs: Set<String>, reasons: Set<RefreshReason>) -> CalendarSnapshot {
        // Remote pushes are missed while the Mac sleeps and before it launches, so an event
        // created elsewhere only becomes visible once the sources have been pulled.
        if !reasons.isDisjoint(with: [.launch, .wake]) {
            store.refreshSourcesIfNecessary()
        }

        var snapshot = makeSnapshot(now: now, selectedCalendarIDs: selectedCalendarIDs)

        switch Self.verdict(
            fetchedCalendars: snapshot.calendars.count,
            previousCandidates: accepted.candidates.count,
            reasons: reasons,
            isAuthorized: snapshot.isAuthorized,
            priorSuspectCount: suspectEmptyFetches
        ) {
        case .accept:
            suspectEmptyFetches = 0
        case .keepPrevious:
            suspectEmptyFetches += 1
            let attempt = suspectEmptyFetches
            let known = accepted.candidates.count
            logger.warning("""
                Event store lists no calendars (\(Self.describe(reasons), privacy: .public), \
                \(attempt, privacy: .public) in a row), keeping \
                \(known, privacy: .public) known candidates
                """)
            // Carries the previous `fetchedAt` on purpose: the data really is that old, and
            // stamping it now would stop the poll loop retrying it.
            snapshot = accepted
        case .rebuildAndRefetch:
            // A new instance, not `reset()`: the SDK calls the two equivalent, but the forum
            // evidence attributes recovery specifically to a store that was never blind.
            logger.warning("Event store has listed no calendars three times, replacing it")
            rebuild()
            store.refreshSourcesIfNecessary()
            suspectEmptyFetches = 0
            snapshot = makeSnapshot(now: now, selectedCalendarIDs: selectedCalendarIDs)
            if snapshot.calendars.isEmpty {
                logger.error("Event store still lists no calendars after being replaced")
            }
        }

        accepted = snapshot
        return snapshot
    }

    // MARK: - Private

    /// What a fetch result is allowed to do to the previous snapshot.
    ///
    /// Apple Developer Forums thread 116840 documents an `EKEventStore` that silently loses its
    /// calendars for up to 40 minutes, so a store that lists none of them is treated as suspect
    /// rather than as truth.
    private enum FetchVerdict {
        case accept
        case keepPrevious
        case rebuildAndRefetch
    }

    /// Pure policy, so the rule can be read and reasoned about without an event store.
    ///
    /// The suspicion is about the store losing its *calendars*, never about a low event count:
    /// a deselected calendar, a quiet day and an event leaving the 24 h window all legitimately
    /// produce no candidates, and none of them may hold back the new snapshot.
    private static func verdict(
        fetchedCalendars: Int,
        previousCandidates: Int,
        reasons: Set<RefreshReason>,
        isAuthorized: Bool,
        priorSuspectCount: Int
    ) -> FetchVerdict {
        // Emptiness with an explanation is the truth:
        // - the store still lists calendars: it is answering, there is simply nothing to show
        // - nothing was known before either
        // - no access: there is nothing to see
        // - `storeChanged`: a genuine deletion arrives exactly this way
        guard fetchedCalendars == 0, previousCandidates > 0,
              isAuthorized, !reasons.contains(.storeChanged) else { return .accept }

        return priorSuspectCount >= 2 ? .rebuildAndRefetch : .keepPrevious
    }

    private func rebuild() {
        store = EKEventStore()
    }

    private static func describe(_ reasons: Set<RefreshReason>) -> String {
        reasons.map(\.rawValue).sorted().joined(separator: "+")
    }

    private func makeSnapshot(now: Date, selectedCalendarIDs: Set<String>) -> CalendarSnapshot {
        let calendars = store.calendars(for: .event)
        let selected = calendars.filter { selectedCalendarIDs.contains($0.calendarIdentifier) }
        // nil = all calendars; an empty array would match nothing.
        let filter: [EKCalendar]? = selected.isEmpty ? nil : selected

        // The overlay window reaches into the past so an event that already started stays a
        // candidate for its grace window.
        let overlayWindow = store.predicateForEvents(
            withStart: now.addingTimeInterval(-OverlaySchedule.graceWindow),
            end: now.addingTimeInterval(24 * 60 * 60),
            calendars: filter
        )
        let candidates = store.events(matching: overlayWindow)
            .filter { Self.isOverlayEligible($0) }
            .compactMap { OverlayCandidate(event: $0) }
            .sorted { $0.startDate < $1.startDate }

        let menuWindow = store.predicateForEvents(
            withStart: now,
            end: Calendar.current.startOfDay(for: now).addingTimeInterval(24 * 60 * 60),
            calendars: filter
        )
        let menuEvents = store.events(matching: menuWindow)
            .compactMap { MenuEvent(event: $0) }
            .filter { $0.startDate > now }
            .sorted { $0.startDate < $1.startDate }

        return CalendarSnapshot(
            candidates: candidates,
            menuEvents: menuEvents,
            calendars: calendars.map { CalendarInfo(calendar: $0) },
            fetchedAt: now,
            isAuthorized: EKEventStore.authorizationStatus(for: .event) == .fullAccess
        )
    }

    /// Excludes what an overlay must never interrupt for:
    /// - all-day: starts at 00:00, so today's would fire a pointless 23:59 overlay
    /// - cancelled: the meeting is off
    /// - declined: only where the user is an attendee — a personal entry has no participant
    ///   record and must still alert
    private static func isOverlayEligible(_ event: EKEvent) -> Bool {
        guard !event.isAllDay, event.status != .canceled else { return false }
        return event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
    }
}
