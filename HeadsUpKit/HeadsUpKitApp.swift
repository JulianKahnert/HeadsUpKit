import Cocoa
import EventKit
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
    private var overlayWindows: [NSWindow] = []
    private var calendarService = CalendarService()
    private var pollTask: Task<Void, Never>?
    private var pendingOverlayTask: Task<Void, Never>?
    private var pendingEventID: String?
    private var shownEventIDs: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["leadTimeSeconds": 60.0])
        setupStatusItem()

        pollTask = Task {
            await calendarService.requestAccess()
            while !Task.isCancelled {
                await checkUpcomingEvent()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTask?.cancel()
        pendingOverlayTask?.cancel()
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
        showOverlay(title: "Team Standup", description: "1. Sprint progress & blockers\n2. Code review assignments\n3. Release timeline update", location: "Apple Park, Cupertino", eventDate: Date.now.addingTimeInterval(45))
    }

    @objc private func openEventInCalendar(_ sender: NSMenuItem) {
        guard let eventIdentifier = (sender.representedObject as? EKEvent)?.eventIdentifier,
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
        guard let calendarID = sender.representedObject as? String,
              let calendar = calendarService.allCalendars.first(where: { $0.calendarIdentifier == calendarID }) else { return }
        calendarService.toggleCalendar(calendar)
    }

    // MARK: - Event Check

    private func checkUpcomingEvent() async {
        guard let event = calendarService.nextEvent else {
            logger.debug("No upcoming event found")
            pendingOverlayTask?.cancel()
            pendingOverlayTask = nil
            pendingEventID = nil
            return
        }

        let eventID = event.eventIdentifier ?? UUID().uuidString
        let threshold = UserDefaults.standard.double(forKey: "leadTimeSeconds")
        let timeUntilEvent = event.startDate.timeIntervalSinceNow
        logger.debug("Next event: \(event.title ?? "nil", privacy: .public) in \(Int(timeUntilEvent))s (threshold: \(Int(threshold))s)")

        guard !shownEventIDs.contains(eventID) else {
            logger.debug("Event already shown: \(event.title ?? "nil", privacy: .public)")
            return
        }

        // Already scheduled for this event
        guard pendingEventID != eventID else { return }

        // Cancel previous pending task if event changed
        pendingOverlayTask?.cancel()
        pendingOverlayTask = nil
        pendingEventID = nil

        let sleepDuration = timeUntilEvent - threshold
        let title = event.title ?? "Upcoming Event"
        let notes = event.notes
        let location = event.location
        let startDate = event.startDate

        if sleepDuration <= 0, timeUntilEvent > 0 {
            // Already within threshold window — show immediately
            shownEventIDs.insert(eventID)
            logger.info("Showing overlay for: \(title, privacy: .public)")
            showOverlay(title: title, description: notes, location: location, eventDate: startDate)
        } else if sleepDuration > 0 {
            // Schedule precise wake-up
            pendingEventID = eventID
            logger.info("Scheduling overlay for: \(title, privacy: .public) in \(Int(sleepDuration))s")
            pendingOverlayTask = Task {
                do {
                    try await Task.sleep(for: .seconds(sleepDuration))
                    shownEventIDs.insert(eventID)
                    logger.info("Showing overlay for: \(title, privacy: .public)")
                    showOverlay(title: title, description: notes, location: location, eventDate: startDate)
                } catch {
                    logger.debug("Pending overlay cancelled for: \(title, privacy: .public)")
                }
                pendingEventID = nil
                pendingOverlayTask = nil
            }
        }
    }

    // MARK: - Overlay

    private func dismissOverlay() {
        for window in overlayWindows {
            window.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    private func showOverlay(title: String, description: String?, location: String? = nil, eventDate: Date? = nil) {
        let screens = NSScreen.screens
        guard let mainScreen = screens.first else { return }

        // Main screen: blur + overlay content
        let mainWindow = makeBlurWindow(for: mainScreen)
        let contentView = OverlayView(title: title, description: description, location: location, eventDate: eventDate) { [weak self] in
            self?.dismissOverlay()
        }
        let hostingView = NSHostingView(rootView: contentView
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        )
        hostingView.frame = mainWindow.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        (mainWindow.contentView as? NSVisualEffectView)?.addSubview(hostingView)
        mainWindow.makeKeyAndOrderFront(nil)
        overlayWindows.append(mainWindow)

        // Secondary screens: blur only
        for screen in screens.dropFirst() {
            let window = makeBlurWindow(for: screen)
            window.orderFront(nil)
            overlayWindows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
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

    func menuNeedsUpdate(_ menu: NSMenu) {
        // Remove previous event items
        menu.items.filter { $0.tag == Self.eventItemTag }.forEach { menu.removeItem($0) }

        // Insert upcoming events at the top
        let events = calendarService.upcomingEvents
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full

        var insertIndex = 0
        if events.isEmpty {
            let item = NSMenuItem(title: "No upcoming events", action: nil, keyEquivalent: "")
            item.tag = Self.eventItemTag
            menu.insertItem(item, at: insertIndex)
            insertIndex += 1
        } else {
            for event in events {
                let item = NSMenuItem(title: event.title ?? "Untitled", action: #selector(openEventInCalendar(_:)), keyEquivalent: "")
                item.tag = Self.eventItemTag

                let relativeTime = formatter.localizedString(for: event.startDate, relativeTo: .now)
                let titleStr = NSMutableAttributedString(
                    string: (event.title ?? "Untitled") + "\n",
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

                // Calendar color dot
                let size = CGSize(width: 12, height: 12)
                item.image = NSImage(size: size, flipped: false) { rect in
                    NSColor(cgColor: event.calendar.cgColor)?.setFill()
                    NSBezierPath(ovalIn: rect).fill()
                    return true
                }

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

        for calendar in calendarService.allCalendars.sorted(by: { $0.title < $1.title }) {
            let item = NSMenuItem(title: calendar.title, action: #selector(toggleCalendar(_:)), keyEquivalent: "")
            item.representedObject = calendar.calendarIdentifier
            item.state = calendarService.isSelected(calendar) ? .on : .off

            // Color indicator
            let size = CGSize(width: 12, height: 12)
            let image = NSImage(size: size, flipped: false) { rect in
                NSColor(cgColor: calendar.cgColor)?.setFill()
                NSBezierPath(ovalIn: rect).fill()
                return true
            }
            item.image = image

            submenu.addItem(item)
        }
    }
}
