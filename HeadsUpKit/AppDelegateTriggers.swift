import Cocoa
import CoreGraphics
import EventKit

// MARK: - Lifecycle triggers

/// Everything that can make the app re-decide: the system notifications it listens to, and the
/// single path from any of them to `reconcile()`.
extension AppDelegate {
    private static let screenLocked = Notification.Name("com.apple.screenIsLocked")
    private static let screenUnlocked = Notification.Name("com.apple.screenIsUnlocked")

    func registerLifecycleObservers() {
        // After system sleep, Task.sleep continuations can fire late relative to wall-clock.
        // Reconciling on wake decides against the current clock instead of waiting one out.
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake(_:)),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        // NTP or manual clock corrections shift wall time without waking the system, so a
        // separate observer is needed to re-decide after a clock jump.
        observe(.NSSystemClockDidChange, with: #selector(systemClockDidChange(_:)))

        // The only trigger that reports a deletion promptly. Everything else would notice it at
        // the next poll at the earliest, by which time the alert may already have fired.
        observe(.EKEventStoreChanged, with: #selector(eventStoreDidChange(_:)))

        // Both move the fetch windows without moving the clock: midnight rolls the menu's
        // "rest of today" over, and a new time zone re-reads every start time.
        observe(.NSCalendarDayChanged, with: #selector(dayDidChange(_:)))
        observe(.NSSystemTimeZoneDidChange, with: #selector(timeZoneDidChange(_:)))

        // Lock state has no public API and no app-level notification: these two are system-wide
        // events, so they only arrive through the distributed centre.
        observe(Self.screenLocked, with: #selector(screenDidLock(_:)), distributed: true)
        observe(Self.screenUnlocked, with: #selector(screenDidUnlock(_:)), distributed: true)
    }

    func removeLifecycleObservers() {
        NSWorkspace.shared.notificationCenter.removeObserver(self, name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: .NSSystemClockDidChange, object: nil)
        NotificationCenter.default.removeObserver(self, name: .EKEventStoreChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .NSCalendarDayChanged, object: nil)
        NotificationCenter.default.removeObserver(self, name: .NSSystemTimeZoneDidChange, object: nil)
        DistributedNotificationCenter.default().removeObserver(self, name: Self.screenLocked, object: nil)
        DistributedNotificationCenter.default().removeObserver(self, name: Self.screenUnlocked, object: nil)
    }

    /// The shape every trigger takes: pull a fresh snapshot, then let the poll loop decide on it.
    /// The `await` lives here rather than in `reconcile()`, which has to stay suspension-free.
    func refreshAndRearm(_ reason: RefreshReason) async {
        let previousFetch = calendarService.snapshot.fetchedAt
        await calendarService.refresh(reason: reason)
        // A `.poll` refresh that changed nothing must not cut short the wait it just re-entered:
        // the loop would wake, find the snapshot still stale, and spin.
        guard reason != .poll || calendarService.snapshot.fetchedAt != previousFetch else { return }
        reconcileNow()
    }

    /// Whether this session is off the console — locked, or switched away from. An unreadable
    /// session counts as unlocked: never alerting at all is a worse failure than alerting behind
    /// a lock screen.
    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let onConsole = session[kCGSessionOnConsoleKey as String] as? Bool else { return false }
        return !onConsole
    }

    private func observe(_ name: Notification.Name, with selector: Selector, distributed: Bool = false) {
        let center = distributed ? DistributedNotificationCenter.default() : NotificationCenter.default
        center.addObserver(self, selector: selector, name: name, object: nil)
    }

    // MARK: - Handlers

    // Every handler below hops through `Task` only to enter the MainActor — an @objc selector can
    // be invoked from any thread, and distributed notifications in particular make no promise
    // about which one.
    @objc private func systemDidWake(_ notification: Notification) {
        Task { await refreshAndRearm(.wake) }
    }

    @objc private func systemClockDidChange(_ notification: Notification) {
        Task { await refreshAndRearm(.clockChanged) }
    }

    @objc private func eventStoreDidChange(_ notification: Notification) {
        Task { await refreshAndRearm(.storeChanged) }
    }

    @objc private func dayDidChange(_ notification: Notification) {
        Task { await refreshAndRearm(.dayChanged) }
    }

    @objc private func timeZoneDidChange(_ notification: Notification) {
        Task { await refreshAndRearm(.timeZoneChanged) }
    }

    // The gate in `reconcile()` reads the lock state live, so these two only have to make it
    // re-decide at the moment the state changes.
    @objc private func screenDidLock(_ notification: Notification) {
        Task { reconcileNow() }
    }

    @objc private func screenDidUnlock(_ notification: Notification) {
        // PR B's grace window turns this into the catch-up alert for anything that came due
        // while the screen was locked.
        Task { await refreshAndRearm(.unlock) }
    }
}
