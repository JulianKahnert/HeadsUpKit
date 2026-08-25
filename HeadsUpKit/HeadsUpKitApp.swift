import Cocoa
import OSLog
import ServiceManagement
import SwiftUI

private let logger = Logger(subsystem: "de.juliankahnert.HeadsUpKit", category: "AppDelegate")

@main
struct HeadsUpKitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var overlayHostingView: NSHostingView<AnyView>?
    private var overlayWindows: [NSWindow] = []
    var calendarService = CalendarService()
    private var pollTask: Task<Void, Never>?
    private var pollSleepTask: Task<Void, Never>?
    private var firedOccurrences = FiredOccurrenceStore()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["leadTimeSeconds": 60.0])
        setupStatusItem()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        registerLifecycleObservers()

        pollTask = Task {
            await calendarService.requestAccess()
            await calendarService.refresh(reason: .launch)
            while !Task.isCancelled {
                // Deliberately not awaited: `reconcile()` decides on the snapshot it already has,
                // so in the final 90 s it may act on data up to 25 s old. `EKEventStoreChanged` is
                // what keeps a genuine deletion from reaching that window in the first place.
                if calendarService.isSnapshotStale {
                    Task { await refreshAndRearm(.poll) }
                }
                // The wait is a task of its own so a trigger can cut it short: the loop then
                // re-decides at once instead of arming a new event up to 30 s late.
                let interval = reconcile()
                let sleep = Task<Void, Never> { try? await Task.sleep(for: interval) }
                pollSleepTask = sleep
                await sleep.value
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        NotificationCenter.default.removeObserver(
            self,
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        removeLifecycleObservers()
        pollSleepTask?.cancel()
        pollTask?.cancel()
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "calendar",
            accessibilityDescription: "Upcoming Event"
        )

        let menu = NSMenu()
        menu.delegate = self
        #if DEBUG
        menu.addItem(NSMenuItem(title: "Test Overlay", action: #selector(triggerTestOverlay), keyEquivalent: "t"))
        menu.addItem(.separator())
        #endif

        let sliderItem = NSMenuItem()
        let sliderHosting = NSHostingView(rootView: LeadTimeSlider())
        sliderHosting.frame.size = sliderHosting.fittingSize
        sliderItem.view = sliderHosting
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        let calendarsItem = NSMenuItem(title: "Calendars", action: nil, keyEquivalent: "")
        calendarsItem.submenu = NSMenu(title: "Calendars")
        menu.addItem(calendarsItem)

        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func triggerTestOverlay() {
        logger.debug("Triggering test overlay")
        // A link-only location, so the debug path exercises the real derivation in OverlayContent.
        showOverlay(OverlayContent(
            title: "Team Standup",
            description: "1. Sprint progress & blockers\n2. Code review assignments\n3. Release timeline update",
            location: "https://example.com/j/1234567890",
            eventDate: Date.now.addingTimeInterval(45)
        ))
    }

    @objc private func openEventInCalendar(_ sender: NSMenuItem) {
        guard let eventIdentifier = sender.representedObject as? String,
              let url = URL(string: "ical://ekevent/\(eventIdentifier)?method=show&options=more") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            logger.error("Failed to toggle launch at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        guard let calendarID = sender.representedObject as? String else { return }
        calendarService.toggleCalendar(id: calendarID)
        Task { await refreshAndRearm(.calendarSelection) }
    }

    // MARK: - Reconcile

    /// Decides from scratch what the app should show right now and returns how long the poll loop
    /// should wait before asking again.
    ///
    /// Synchronous and free of suspension points on purpose: the MainActor then serializes the
    /// poll, wake, unlock and clock-change triggers — which after a wake all arrive at the same
    /// instant — so none of them can interleave and act on half-applied state. That is why it
    /// decides on the cached `CalendarSnapshot` and never awaits a refresh; an `await` in here
    /// re-opens the race.
    @discardableResult
    func reconcile() -> Duration {
        let now = Date.now
        firedOccurrences.prune(now: now)

        // Read live rather than cached: a fast user switch moves the session off the console
        // while posting `com.apple.sessionDidMoveOffConsole`, never `com.apple.screenIsLocked`.
        // Deliberately without a record either way: an occurrence resolved behind the lock screen
        // would be consumed invisibly, and the unlock handler could never catch it up.
        guard !Self.screenIsLocked() else {
            logger.debug("Screen locked, deferring any overlay")
            return .seconds(30)
        }

        let candidates = calendarService.snapshot.candidates
        guard !candidates.isEmpty else {
            // Normal before the first refresh lands, and by now genuinely empty otherwise:
            // `CalendarStore` has already vetoed the empty fetches nothing explains.
            logger.debug("No overlay candidates in the fetch window")
            return .seconds(30)
        }

        let leadTime = UserDefaults.standard.double(forKey: "leadTimeSeconds")
        let decision = OverlaySchedule.decide(
            candidates: candidates,
            fired: firedOccurrences.records,
            leadTime: leadTime,
            now: now
        )

        switch decision {
        case .fire(let candidate, let superseded):
            // Resolved without an overlay: the one being shown covers them.
            for occurrence in superseded {
                firedOccurrences.insert(occurrence)
            }
            let delta = now.timeIntervalSince(candidate.startDate.addingTimeInterval(-leadTime))
            logger.info("""
                Showing overlay for: \(candidate.content.title, privacy: .public) \
                (start: \(candidate.startDate, privacy: .public), \
                delta: \(delta, format: .fixed(precision: 2), privacy: .public)s, \
                superseded: \(superseded.count, privacy: .public))
                """)
            firedOccurrences.insert(candidate)
            showOverlay(candidate.content)
        case .armed(let candidate, let fireDate):
            logger.debug("""
                Next overlay: \(candidate.content.title, privacy: .public) \
                at \(fireDate, privacy: .public)
                """)
        case .idle:
            logger.debug("No candidate left to alert for")
        }

        return OverlaySchedule.pollInterval(after: decision, now: now)
    }

    /// Cuts the poll loop's wait short so it reconciles now, against the current snapshot and
    /// the current lock state.
    func reconcileNow() {
        pollSleepTask?.cancel()
    }

    // MARK: - Overlay

    @objc private func screenParametersDidChange(_ notification: Notification) {
        guard overlayHostingView != nil else { return }
        logger.debug("Screen parameters changed, updating overlay windows")
        layoutOverlayWindows()
    }

    private func showOverlay(_ content: OverlayContent) {
        let contentView = OverlayView(content: content) { [weak self] in
            self?.dismissOverlay()
        }
        let hostingView = NSHostingView(rootView: AnyView(contentView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        ))
        hostingView.autoresizingMask = [.width, .height]
        overlayHostingView = hostingView

        layoutOverlayWindows()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Tears down all overlay windows and rebuilds one per screen.
    /// The first screen gets the `overlayHostingView` with the UI content, all others are blur-only.
    private func layoutOverlayWindows() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()

        let screens = NSScreen.screens
        for (index, screen) in screens.enumerated() {
            let window = makeBlurWindow(for: screen)

            if index == 0, let hostingView = overlayHostingView {
                hostingView.frame = window.contentView?.bounds ?? .zero
                (window.contentView as? NSVisualEffectView)?.addSubview(hostingView)
                window.makeKeyAndOrderFront(nil)
            } else {
                window.orderFront(nil)
            }

            overlayWindows.append(window)
        }
    }

    private func dismissOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
        overlayHostingView = nil
    }

    private func makeBlurWindow(for screen: NSScreen) -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let visualEffect = NSVisualEffectView()
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.material = .hudWindow
        visualEffect.autoresizingMask = [.width, .height]

        window.contentView = visualEffect
        window.setFrame(screen.frame, display: true)
        return window
    }
}

// MARK: - Lead Time Slider

struct LeadTimeSlider: View {
    @AppStorage("leadTimeSeconds") private var leadTime: Double = 60

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Remind \(Int(leadTime))s before")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Slider(value: $leadTime, in: 0...300, step: 15)
                .frame(width: 200)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

// MARK: - NSMenuDelegate

extension AppDelegate: NSMenuDelegate {
    private static let eventItemTag = 999

    /// The menu is built from the cached snapshot, so an open shows what the last refresh found —
    /// up to 25 s old. This fetch is what makes the next open current.
    func menuWillOpen(_ menu: NSMenu) {
        Task { await refreshAndRearm(.menuOpened) }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Remove previous event items
        menu.items.filter { $0.tag == Self.eventItemTag }.forEach { menu.removeItem($0) }

        // Insert upcoming events at the top
        let snapshot = calendarService.snapshot
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        var insertIndex = 0
        if snapshot.menuEvents.isEmpty {
            let item = NSMenuItem(title: "No upcoming events", action: nil, keyEquivalent: "")
            item.tag = Self.eventItemTag
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
        } else {
            for event in snapshot.menuEvents {
                // Without an identifier there is no `ical://` URL to open, so the item stays inert
                // rather than carrying an action that silently does nothing.
                let action = event.eventIdentifier == nil ? nil : #selector(openEventInCalendar(_:))
                let item = NSMenuItem(title: event.title, action: action, keyEquivalent: "")
                item.tag = Self.eventItemTag
                item.representedObject = event.eventIdentifier

                let relativeTime = formatter.localizedString(for: event.startDate, relativeTo: .now)
                let titleStr = NSMutableAttributedString(
                    string: event.title + "\n",
                    attributes: [.font: NSFont.menuFont(ofSize: 0)]
                )
                titleStr.append(NSAttributedString(
                    string: relativeTime,
                    attributes: [
                        .font: NSFont.menuFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor
                    ]
                ))
                item.attributedTitle = titleStr
                item.image = Self.colorDot(event.color)

                menu.insertItem(item, at: insertIndex)
                insertIndex += 1
            }
        }

        let separator = NSMenuItem.separator()
        separator.tag = Self.eventItemTag
        menu.insertItem(separator, at: insertIndex)

        // Update launch at login state
        if let launchItem = menu.items.first(where: { $0.action == #selector(toggleLaunchAtLogin(_:)) }) {
            launchItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        }

        // Update calendar submenu
        guard let calendarsItem = menu.items.first(where: { $0.title == "Calendars" }),
              let submenu = calendarsItem.submenu else { return }
        submenu.removeAllItems()

        for calendar in snapshot.calendars.sorted(by: { $0.title < $1.title }) {
            let item = NSMenuItem(title: calendar.title, action: #selector(toggleCalendar(_:)), keyEquivalent: "")
            item.representedObject = calendar.id
            item.state = calendarService.isSelected(id: calendar.id) ? .on : .off
            item.image = Self.colorDot(calendar.color)
            submenu.addItem(item)
        }
    }

    private static func colorDot(_ color: CalendarColor) -> NSImage {
        NSImage(size: CGSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(srgbRed: color.red, green: color.green, blue: color.blue, alpha: color.alpha).setFill()
            NSBezierPath(ovalIn: rect).fill()
            return true
        }
    }
}
