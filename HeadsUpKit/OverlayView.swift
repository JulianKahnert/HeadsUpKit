import MapKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "de.juliankahnert.HeadsUpKit", category: "OverlayView")

struct OverlayView: View {
    let content: OverlayContent
    let dismiss: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var mapPosition: MapCameraPosition?
    @State private var detailHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 60) {
            iconView

            HStack(alignment: .center, spacing: 32) {
                detailsView
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { height in
                        if abs(detailHeight - height) > 1 {
                            detailHeight = height
                        }
                    }

                mapView
            }

            actionButtons
        }
        .padding(48)
        .background(.black.opacity(0.3), in: .rect(cornerRadius: 26))
        .task {
            if let mapLocation = content.mapLocation {
                await geocode(mapLocation)
            }
        }
    }

    // MARK: - Components

    private var iconView: some View {
        Image(systemName: "calendar.circle")
            .font(.system(size: 112))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(.blue)

    }

    private var detailsView: some View {
        VStack(spacing: 16) {
            Text(content.title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let description = content.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: 360)
            }

            timeView

            if let url = content.url {
                metaLabel(url.host() ?? "Link", systemImage: "link")
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var timeView: some View {
        if let eventDate = content.eventDate {
            if eventDate > .now {
                Text(timerInterval: Date.now...eventDate, countsDown: true, showsHours: false)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            } else {
                // A catch-up overlay can sit on screen for minutes, so the elapsed time keeps
                // counting instead of freezing at the value it had when the overlay appeared.
                VStack(spacing: 4) {
                    Text(eventDate, style: .timer)
                        .font(.system(size: 28, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))

                    metaLabel("Already started", systemImage: "exclamationmark.circle.fill")
                }
            }
        }
    }

    @ViewBuilder
    private var mapView: some View {
        if let mapLocation = content.mapLocation {
            VStack(spacing: 8) {
                if let mapPosition {
                    Map(initialPosition: mapPosition) {
                        Marker(mapLocation, coordinate: mapPosition.region?.center ?? .init())
                    }
                    .mapStyle(.standard)
                    .frame(width: detailHeight, height: detailHeight)
                    .clipShape(.rect(cornerRadius: 16))
                    .allowsHitTesting(false)
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.gray.opacity(0.3))
                        .frame(width: detailHeight, height: detailHeight)
                        .redacted(reason: .placeholder)
                }

                metaLabel(mapLocation, systemImage: "mappin.circle.fill")
                    .lineLimit(3)
                    .frame(maxWidth: detailHeight, alignment: .leading)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 16) {
            if let url = content.url {
                Button {
                    openURL(url)
                    dismiss()
                } label: {
                    buttonLabel("Open")
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }

            Button(action: dismiss) {
                buttonLabel("OK")
            }
            .keyboardShortcut(.cancelAction)
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .padding(.top, 4)
    }

    private func buttonLabel(_ title: String) -> some View {
        Text(title)
            .font(.title3)
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
    }

    private func metaLabel(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 13, design: .rounded))
            .foregroundStyle(.white.opacity(0.6))
    }

    // MARK: - Geocoding

    private func geocode(_ address: String) async {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        let search = MKLocalSearch(request: request)
        guard let response = try? await search.start(),
              let item = response.mapItems.first else {
            logger.warning("Geocoding failed for: \(address, privacy: .public)")
            return
        }
        let coordinate = item.placemark.coordinate
        logger.debug("Geocoded '\(address, privacy: .public)' → \(coordinate.latitude), \(coordinate.longitude)")
        mapPosition = .region(MKCoordinateRegion(
            center: coordinate,
            span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)
        ))
    }
}

#Preview("With Link") {
    OverlayView(
        content: OverlayContent(
            title: "Team Standup",
            description: "Daily sync with the engineering team.",
            location: "https://example.com/j/1234567890",
            eventDate: Date.now.addingTimeInterval(45)
        ),
        dismiss: {}
    )
}

#Preview("With Location") {
    OverlayView(
        content: OverlayContent(
            title: "Team Standup",
            description: "Daily sync with the engineering team.",
            location: "Apple Park, Cupertino",
            eventDate: Date.now.addingTimeInterval(45)
        ),
        dismiss: {}
    )
}

#Preview("Already Started") {
    OverlayView(
        content: OverlayContent(
            title: "Team Standup",
            description: "Daily sync with the engineering team.",
            location: "Apple Park, Cupertino",
            eventDate: Date.now.addingTimeInterval(-125)
        ),
        dismiss: {}
    )
}

#Preview("Without Location") {
    OverlayView(
        content: OverlayContent(
            title: "Team Standup",
            description: "Daily sync with the engineering team.",
            location: nil,
            eventDate: Date.now.addingTimeInterval(30)
        ),
        dismiss: {}
    )
}
