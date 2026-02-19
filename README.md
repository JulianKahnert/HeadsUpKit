# HeadsUpKit

A macOS menu bar app that shows a fullscreen overlay when your next calendar event is about to start.

## Features

- **Fullscreen overlay** with event title, description, countdown timer, and optional map
- **Menu bar integration** with calendar selection and configurable lead time
- **Automatic event detection** polling every 20 seconds
- **Location support** with inline map via geocoding

## Requirements

- macOS 26.2+
- Calendar access permission

## Installation

### From source

```bash
git clone https://github.com/JulianKahnert/HeadsUpKit.git
cd HeadsUpKit
open HeadsUpKit.xcodeproj
```

Build and run with Xcode.

## Usage

1. Launch the app — it appears as a calendar icon in the menu bar
2. Select which calendars to monitor from the menu bar dropdown
3. Adjust the lead time (how early to show the overlay) with the slider
4. When an event is approaching, a fullscreen overlay appears with event details and a countdown

Press **Escape** or click **OK** to dismiss the overlay.

## License

MIT
