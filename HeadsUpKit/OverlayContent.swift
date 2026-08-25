import Foundation

/// The plain values the overlay presents, derived once from the event's raw fields — the view
/// layer must never depend on EventKit or link detection.
nonisolated struct OverlayContent {
    let title: String
    let description: String?
    /// The event's location, or nil when it is empty or nothing but a link — a URL is no
    /// physical place, and geocoding it would only ever leave the map's redacted placeholder
    /// on screen.
    let mapLocation: String?
    let eventDate: Date?
    /// Link to open for the event; an explicit event URL wins over links found in the location
    /// (where conference links usually arrive) or in the notes.
    let url: URL?

    init(title: String, description: String?, location: String?, eventDate: Date?, eventURL: URL? = nil) {
        self.title = title
        self.description = description
        self.eventDate = eventDate

        let locationLink = Self.firstLink(in: location)
        self.url = eventURL ?? locationLink?.url ?? Self.firstLink(in: description)?.url
        self.mapLocation = (location?.isEmpty == false && locationLink?.spansWholeText != true) ? location : nil
    }

    // MARK: - Link detection

    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    private static func firstLink(in text: String?) -> (url: URL, spansWholeText: Bool)? {
        guard let detector,
              let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        let fullRange = NSRange(text.startIndex..., in: text)
        var link: (url: URL, spansWholeText: Bool)?
        detector.enumerateMatches(in: text, range: fullRange) { match, _, stop in
            // The detector also reports mailto: and similar; only web links are openable here.
            guard let match, let url = match.url,
                  url.scheme == "http" || url.scheme == "https" else { return }
            link = (url, match.range == fullRange)
            stop.pointee = true
        }
        return link
    }
}
