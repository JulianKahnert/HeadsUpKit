import EventKit
import Foundation
import OSLog

private let logger = Logger(subsystem: "de.juliankahnert.HeadsUpKit", category: "OverlayScheduling")

// MARK: - Candidate

/// One occurrence of a calendar event, reduced to the values the fire decision needs, so the
/// policy in `OverlaySchedule` stays independent of EventKit and of the current time.
nonisolated struct OverlayCandidate {
    /// Identifies a single occurrence, not the series it belongs to.
    let key: String
    let startDate: Date
    let endDate: Date
    let lastModified: Date?
    let content: OverlayContent

    /// Fails when EventKit hands over an event without the dates the decision needs — both
    /// `startDate` and `endDate` import as implicitly unwrapped optionals.
    init?(event: EKEvent) {
        guard let startDate = event.startDate, let endDate = event.endDate else { return nil }

        // All occurrences of a recurring series share one `eventIdentifier`, so keying on it
        // alone silences every occurrence after the first; `occurrenceDate` is nil outside a series.
        let base = event.eventIdentifier ?? event.calendarItemIdentifier
        let occurrence = event.occurrenceDate ?? startDate
        key = "\(base):\(Int(occurrence.timeIntervalSince1970))"

        self.startDate = startDate
        self.endDate = endDate
        lastModified = event.lastModifiedDate
        content = OverlayContent(
            title: event.title ?? "Upcoming Event",
            description: event.notes,
            location: event.location,
            eventDate: startDate,
            eventURL: event.url
        )
    }
}

// MARK: - Fire policy

/// The rules deciding which occurrence gets an overlay right now, and how soon the app has to
/// look again. Pure functions taking `now` as a parameter — the caller owns the clock.
nonisolated enum OverlaySchedule {
    /// How long after its start an occurrence is still worth alerting for: a lid opened two
    /// minutes into a meeting deserves a catch-up overlay, half an hour later does not.
    static let graceWindow: TimeInterval = 5 * 60

    enum Decision {
        /// Show `OverlayCandidate`; `superseded` are the earlier occurrences the same catch-up
        /// covers, which the caller resolves without an overlay of their own.
        case fire(OverlayCandidate, superseded: [OverlayCandidate])
        case armed(OverlayCandidate, fireDate: Date)
        case idle
    }

    /// Walks chronologically sorted `candidates` and returns what to do at `now`.
    ///
    /// A skipped candidate must not stop the walk, or a declined-then-expired event would shadow
    /// the real next meeting.
    static func decide(
        candidates: [OverlayCandidate],
        fired: [String: FiredRecord],
        leadTime: TimeInterval,
        now: Date
    ) -> Decision {
        var fireable: [OverlayCandidate] = []

        for candidate in candidates {
            // A record whose start time no longer matches means the occurrence was rescheduled
            // after it was resolved, which re-arms it.
            if let record = fired[candidate.key], record.startDate == candidate.startDate { continue }

            // Too late to be worth interrupting for — whichever comes first, the grace window
            // running out or the meeting itself ending. Deliberately never recorded: it never
            // fired, and it drops out of the fetch window on its own.
            if now >= min(candidate.startDate.addingTimeInterval(graceWindow), candidate.endDate) { continue }

            let fireDate = candidate.startDate.addingTimeInterval(-leadTime)
            if fireDate <= now {
                fireable.append(candidate)
                continue
            }
            // Sorted by start, so the first candidate still ahead of its fire date ends the walk.
            if fireable.isEmpty { return .armed(candidate, fireDate: fireDate) }
            break
        }

        guard let current = fireable.last else { return .idle }
        // Several occurrences can come due at once after a long sleep. Only the latest-starting
        // one is the meeting the user is in, and showing the others first would flash each of
        // them for one poll interval before the next replaced it.
        return .fire(current, superseded: Array(fireable.dropLast()))
    }

    /// How long the poll loop should sleep before reconciling again.
    static func pollInterval(after decision: Decision, now: Date) -> Duration {
        switch decision {
        case .fire:
            // Reconcile straight away so an event close behind the one just shown is armed
            // against the real clock instead of up to 30 s late.
            return .seconds(1)
        case .armed(_, let fireDate):
            let remaining = fireDate.timeIntervalSince(now)
            guard remaining < 90 else { return .seconds(30) }
            // Inside the final approach, cap the sleep at the time actually left so the last tick
            // lands on `fireDate` instead of accumulating every iteration's work as drift.
            return .seconds(min(1, remaining))
        case .idle:
            return .seconds(30)
        }
    }
}

// MARK: - Fired records

/// What the app knew about an occurrence when it resolved it. Resolved, not shown: a catch-up
/// that supersedes earlier occurrences records those too, so they cannot come back a tick later.
nonisolated struct FiredRecord: Codable {
    let startDate: Date
    let endDate: Date
    /// Recorded but deliberately never compared: any edit bumps `lastModifiedDate`, so re-alerting
    /// on it would fire again for a typo in the notes. Only a moved `startDate` re-arms.
    let lastModified: Date?
}

/// The occurrences an overlay was already shown for, persisted so a restart between the overlay
/// and the event's start does not produce a second alert.
struct FiredOccurrenceStore {
    private static let defaultsKey = "firedOccurrences"

    private(set) var records: [String: FiredRecord]

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else {
            records = [:]
            return
        }
        do {
            records = try JSONDecoder().decode([String: FiredRecord].self, from: data)
        } catch {
            logger.error("Discarding unreadable fired records: \(error.localizedDescription, privacy: .public)")
            records = [:]
        }
    }

    mutating func insert(_ candidate: OverlayCandidate) {
        records[candidate.key] = FiredRecord(
            startDate: candidate.startDate,
            endDate: candidate.endDate,
            lastModified: candidate.lastModified
        )
        save()
    }

    /// Forgets every occurrence that can no longer fire, keeping the store from growing forever.
    mutating func prune(now: Date) {
        let kept = Self.pruning(records, now: now)
        let dropped = records.count - kept.count
        guard dropped > 0 else { return }
        records = kept
        save()
        logger.debug("Pruned \(dropped) fired records")
    }

    /// A record outlives its event by the grace window: dropping a 10:00–10:02 meeting at 10:02
    /// would let its catch-up window fire a second overlay at 10:04.
    static func pruning(_ records: [String: FiredRecord], now: Date) -> [String: FiredRecord] {
        records.filter { _, record in
            let expiry = max(record.endDate, record.startDate.addingTimeInterval(OverlaySchedule.graceWindow))
            return expiry >= now
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(records)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            logger.error("Failed to persist fired records: \(error.localizedDescription, privacy: .public)")
        }
    }
}
