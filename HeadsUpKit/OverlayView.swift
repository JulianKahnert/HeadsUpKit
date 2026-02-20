import MapKit
import OSLog
import SwiftUI

private let logger = Logger(subsystem: "de.juliankahnert.HeadsUpKit", category: "OverlayView")

struct OverlayView: View {
    let title: String
    let description: String?
    let location: String?
    let eventDate: Date?
    let dismiss: () -> Void

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

            dismissButton
        }
        .padding(48)
        .background(.black.opacity(0.3), in: .rect(cornerRadius: 26))
        .task {
            if let location, !location.isEmpty {
                await geocode(location)
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
            Text(title)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 18, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: 360)
            }

            if let eventDate, eventDate > .now {
                Text(timerInterval: Date.now...eventDate, countsDown: true, showsHours: false)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private var hasLocation: Bool {
        location?.isEmpty == false
    }

    @ViewBuilder
    private var mapView: some View {
        if hasLocation {
            VStack(spacing: 8) {
                if let mapPosition {
                    Map(initialPosition: mapPosition) {
                        Marker(location ?? title, coordinate: mapPosition.region?.center ?? .init())
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

                if let location, !location.isEmpty {
                    Label(location, systemImage: "mappin.circle.fill")
                        .font(.system(size: 13, design: .rounded))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(3)
                        .frame(maxWidth: detailHeight, alignment: .leading)
                }
            }
        }
    }

    private var dismissButton: some View {
        Button(action: dismiss) {
            Text("OK")
                .font(.title3)
                .padding(.horizontal, 32)
                .padding(.vertical, 8)
        }
        .keyboardShortcut(.escape, modifiers: [])
        .buttonStyle(.bordered)
        .controlSize(.large)
        .padding(.top, 4)
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

#Preview("With Location") {
    OverlayView(
        title: "Team Standup",
        description: "Daily sync with the engineering team.",
        location: "Apple Park, Cupertino",
        eventDate: Date.now.addingTimeInterval(45),
        dismiss: {}
    )
}

#Preview("Without Location") {
    OverlayView(
        title: "Team Standup",
        description: "Daily sync with the engineering team.",
        location: nil,
        eventDate: Date.now.addingTimeInterval(30),
        dismiss: {}
    )
}
