import Cocoa
import EventKit
import OSLog
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
    private var overlayWindow: NSWindow?
    private var calendarService = CalendarService()
    private var checkTimer: Timer?
    private var shownEventIDs: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["leadTimeSeconds": 60.0])
        setupStatusItem()

        Task {
            await calendarService.requestAccess()
            checkUpcomingEvent()
        }

        checkTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            self?.checkUpcomingEvent()
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "calendar.badge.clock",
            accessibilityDescription: "Upcoming Event"
        )

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(NSMenuItem(title: "Test Overlay", action: #selector(triggerTestOverlay), keyEquivalent: "t"))
        menu.addItem(.separator())

        let sliderItem = NSMenuItem()
        let sliderHosting = NSHostingView(rootView: LeadTimeSlider())
        sliderHosting.frame.size = sliderHosting.fittingSize
        sliderItem.view = sliderHosting
        menu.addItem(sliderItem)

        menu.addItem(.separator())

        let calendarsItem = NSMenuItem(title: "Calendars", action: nil, keyEquivalent: "")
        calendarsItem.submenu = NSMenu(title: "Calendars")
        menu.addItem(calendarsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func triggerTestOverlay() {
        logger.debug("Triggering test overlay")
        showOverlay(title: "Team Standup", description: "1. Sprint progress & blockers\n2. Code review assignments\n3. Release timeline update", location: "Apple Park, Cupertino", eventDate: Date.now.addingTimeInterval(45))
    }

    @objc private func toggleCalendar(_ sender: NSMenuItem) {
        guard let calendarID = sender.representedObject as? String,
              let calendar = calendarService.allCalendars.first(where: { $0.calendarIdentifier == calendarID }) else { return }
        calendarService.toggleCalendar(calendar)
    }

    // MARK: - Event Check

    private func checkUpcomingEvent() {
        guard let event = calendarService.nextEvent else {
            logger.debug("No upcoming event found")
            return
        }

        let threshold = UserDefaults.standard.double(forKey: "leadTimeSeconds")
        let timeUntilEvent = event.startDate.timeIntervalSinceNow
        logger.debug("Next event: \(event.title ?? "nil", privacy: .public) in \(Int(timeUntilEvent))s (threshold: \(Int(threshold))s)")

        guard timeUntilEvent <= threshold, timeUntilEvent > 0 else { return }

        let eventID = event.eventIdentifier ?? UUID().uuidString
        guard !shownEventIDs.contains(eventID) else {
            logger.debug("Event already shown: \(event.title ?? "nil", privacy: .public)")
            return
        }

        shownEventIDs.insert(eventID)
        logger.info("Showing overlay for: \(event.title ?? "nil", privacy: .public)")
        showOverlay(title: event.title ?? "Upcoming Event", description: event.notes, location: event.location, eventDate: event.startDate)
    }

    // MARK: - Overlay

    private func showOverlay(title: String, description: String?, location: String? = nil, eventDate: Date? = nil) {
        guard let screen = NSScreen.main else { return }

        let window = NSWindow(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        window.level = .screenSaver
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.ignoresMouseEvents = false

        // Native macOS blur background
        let visualEffect = NSVisualEffectView(frame: screen.frame)
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.material = .hudWindow

        let contentView = OverlayView(title: title, description: description, location: location, eventDate: eventDate) { [weak self] in
            self?.overlayWindow?.orderOut(nil)
            self?.overlayWindow = nil
        }

        let hostingView = NSHostingView(rootView: contentView)
        hostingView.frame = screen.frame
        visualEffect.addSubview(hostingView)
        window.contentView = visualEffect
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        overlayWindow = window
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
    func menuNeedsUpdate(_ menu: NSMenu) {
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
