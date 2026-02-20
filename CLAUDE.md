# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

Build via Xcode (open `HeadsUpKit.xcodeproj`) or via command line:

```bash
xcodebuild -project HeadsUpKit.xcodeproj -scheme HeadsUpKit -configuration Debug build
```

There are no automated tests in this project currently.

## Architecture

This is a macOS menu bar app (minimum deployment target: macOS 15) using SwiftUI with AppKit integration.

**Key settings:**
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` — all types are implicitly `@MainActor`
- `SWIFT_APPROACHABLE_CONCURRENCY = YES` — Swift 6 concurrency strictness
- App Sandbox and Hardened Runtime are enabled

**Flow:**
1. `HeadsUpKitApp` (entry point) uses `@NSApplicationDelegateAdaptor` for an `AppDelegate` that manages the menu bar and overlay
2. `CalendarService` polls EventKit for the next upcoming event from selected calendars
3. A 20s timer checks if the next event is within the user-configured lead time (default 60s)
4. When triggered, `showOverlay()` creates a borderless `NSWindow` at `.screenSaver` level with `NSVisualEffectView` blur
5. `OverlayView` shows event title, description, countdown timer, and optional map with location
6. Menu bar provides: test overlay (debug only), lead time slider, calendar selection submenu, quit

## CI/CD

- **PR checks** (`.github/workflows/pr.yml`): Builds on every PR with `xcodebuild` on `macos-26`
- **Release** (`.github/workflows/release.yml`): Triggered by tags (`*.*.*`), creates GitHub Release with auto-generated notes, signs and notarizes the app with Developer ID, uploads ZIP to release, and opens a version bump PR
- Team ID: `87KNVHZ8C7`

## Distribution

- **Homebrew**: `brew tap juliankahnert/tap && brew install --cask headsupkit`
  - Cask definition lives in [JulianKahnert/homebrew-tap](https://github.com/JulianKahnert/homebrew-tap)
- **License**: CC BY-NC-SA 4.0
