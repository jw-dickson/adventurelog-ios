// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import MapKit
import SwiftUI

/// The Map tab (Design/review-1, 05): the selected trip's places as pins, filtered to one day or
/// all days, with that day's planned order as a dashed line and, once recorded, the route
/// actually driven as a solid one, with stops that weren't in the plan as dots.
struct TripMapTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Group {
                if let id = model.selectedTripID, let loaded = model.trip(id) {
                    TripMapView(tripID: id, plan: loaded.plan)
                } else {
                    ContentUnavailableView("No trip open", systemImage: "map",
                                           description: Text("Open a trip in the Trip tab to see it on the map."))
                        .background(ALColor.surface100)
                }
            }
            .navigationDestination(for: ItemRoute.self) { route in
                ItemDetailView(route: route)
            }
        }
    }
}

/// A place on the map: one item, or one end of a transport leg.
struct MapPin: Identifiable, Hashable {
    let id: String
    let itemID: String
    let day: CalendarDate?
    let title: String
    let subtitle: String?
    let symbol: String
    let isBooked: Bool
    let coordinate: ItemSummary.Coordinate
    let summary: ItemSummary

    var location: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    static func == (a: MapPin, b: MapPin) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// Pins for the given day, or for the whole trip when `day` is nil.
    static func pins(in plan: TripPlan, day: CalendarDate?) -> [MapPin] {
        typealias Placed = (item: TripPlan.Item, date: CalendarDate?)
        var entries: [Placed] = []
        if let day {
            for entry in plan.day(for: day)?.entries ?? [] { entries.append((entry.item, entry.row.date)) }
        } else {
            for planned in plan.days {
                for entry in planned.entries { entries.append((entry.item, entry.row.date)) }
            }
            for entry in plan.tripWide { entries.append((entry.item, nil)) }
            for item in plan.unscheduled { entries.append((item, nil)) }
        }
        var pins: [MapPin] = []
        var seen = Set<String>()
        for (item, date) in entries {
            let summary = ItemSummary(item, day: date, tripZone: plan.timeZone)
            func add(_ suffix: String, _ coordinate: ItemSummary.Coordinate?, title: String, subtitle: String?) {
                guard let coordinate else { return }
                let id = "\(item.id)\(suffix)-\(date?.description ?? "trip")"
                guard seen.insert(id).inserted else { return }
                pins.append(MapPin(id: id, itemID: item.id, day: date, title: title, subtitle: subtitle,
                                   symbol: summary.symbol, isBooked: summary.isBooked, coordinate: coordinate, summary: summary))
            }
            if case .transportation(let leg) = item {
                add(".from", summary.coordinate, title: leg.startCode ?? leg.fromLocation ?? summary.title, subtitle: summary.title)
                add(".to", summary.destination, title: leg.endCode ?? leg.toLocation ?? summary.title, subtitle: summary.title)
            } else {
                add("", summary.coordinate, title: summary.title, subtitle: summary.detail)
            }
        }
        return pins
    }
}

struct TripMapView: View {
    let tripID: String
    let plan: TripPlan
    @Environment(AppModel.self) private var model
    @State private var day: CalendarDate?
    @State private var dayChosen = false
    @State private var selection: String?
    @State private var position = MapCameraPosition.automatic

    var body: some View {
        let pins = MapPin.pins(in: plan, day: day)
        let log = day.flatMap { model.dayLog(tripID: tripID, date: $0) }
        let route = (log?.points ?? []).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        let unplanned = (log?.rows ?? []).filter { $0.status == .unplanned }
        Map(position: $position, selection: $selection) {
            if day != nil, pins.count > 1 {
                MapPolyline(coordinates: pins.map(\.location))
                    .stroke(ALColor.routePlanned, style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [6, 6]))
            }
            if route.count > 1 {
                MapPolyline(coordinates: route)
                    .stroke(ALColor.routeActual, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            ForEach(unplanned) { row in
                if let point = row.coordinate {
                    Annotation(row.detail, coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)) {
                        Circle()
                            .fill(ALColor.routeActual)
                            .stroke(ALColor.surface100, lineWidth: 2)
                            .frame(width: 12, height: 12)
                            .accessibilityLabel(row.detail)
                    }
                }
            }
            ForEach(pins) { pin in
                Marker(pin.title, systemImage: pin.symbol, coordinate: pin.location)
                    .tint(pin.isBooked ? ALColor.itemFixed : ALColor.secondary)
                    .tag(pin.id)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
        .safeAreaInset(edge: .top) { dayPicker }
        .safeAreaInset(edge: .bottom) {
            if let pin = pins.first(where: { $0.id == selection }) {
                PinCard(pin: pin, tripID: tripID)
            }
        }
        .overlay {
            if pins.isEmpty, route.isEmpty {
                ContentUnavailableView("Nothing to map", systemImage: "mappin.slash",
                                       description: Text("Items on this day have no location."))
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ALRadius.box))
                    .padding(ALSpace.space8)
            }
        }
        .navigationTitle(plan.collection.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.visible, for: .navigationBar)
        .accessibilityIdentifier("trip.map")
        .task(id: tripID) { await model.loadTrack(tripID: tripID) }
        .onAppear {
            // Start on today when the trip is on, else the whole trip.
            if !dayChosen { day = plan.day(for: model.today)?.date }
        }
        .onChange(of: day) { _, _ in
            selection = nil
            withAnimation { position = .automatic }
        }
    }

    private var dayPicker: some View {
        HStack(spacing: ALSpace.space2) {
            Menu {
                Button("All days") { choose(nil) }
                ForEach(plan.days) { d in
                    Button("\(DayText.long(d.date)) · \(d.name ?? "Day \(d.number)")") { choose(d.date) }
                }
            } label: {
                Label(day.map { "Day \(plan.day(for: $0)?.number ?? 0) · \(DayText.long($0))" } ?? "All days",
                      systemImage: "calendar")
                    .font(ALFont.subheadline.weight(.semibold))
                    .foregroundStyle(ALColor.ink)
                    .padding(.horizontal, ALSpace.space3)
                    .padding(.vertical, ALSpace.space2)
                    .background(ALColor.surface100, in: Capsule())
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)
            }
            .accessibilityIdentifier("map.day")
            Spacer()
        }
        .padding(.horizontal, ALSpace.space4)
        .padding(.top, ALSpace.space2)
    }

    private func choose(_ date: CalendarDate?) {
        dayChosen = true
        day = date
    }
}

private struct PinCard: View {
    let pin: MapPin
    let tripID: String
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: ALSpace.space3) {
            NavigationLink(value: ItemRoute(tripID: tripID, itemID: pin.itemID, day: pin.day)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(pin.summary.title)
                        .font(ALFont.headline)
                        .foregroundStyle(ALColor.ink)
                        .multilineTextAlignment(.leading)
                    if let detail = pin.summary.whenText() ?? pin.subtitle {
                        Text(detail)
                            .font(ALFont.footnote)
                            .foregroundStyle(ALColor.inkMuted)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let url = ItemDetailContentHelpers.directions(to: pin) {
                Button("Go") { openURL(url) }
                    .buttonStyle(ALButtonStyle(.primary, small: true))
            }
        }
        .padding(ALSpace.space4)
        .background(ALColor.surface100, in: RoundedRectangle(cornerRadius: ALRadius.box, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 10, y: -2)
        .padding(.horizontal, ALSpace.space3)
        .padding(.bottom, ALSpace.space2)
    }
}

enum ItemDetailContentHelpers {
    static func directions(to pin: MapPin) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [
            URLQueryItem(name: "daddr", value: "\(pin.coordinate.latitude),\(pin.coordinate.longitude)"),
            URLQueryItem(name: "q", value: pin.title),
        ]
        return components?.url
    }
}
