// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import MapKit
import SwiftUI

/// The Today tab (Design/review-1, 02 and 10): the day's header, a Next up card with the
/// leave-by time and Navigate / Notes / Skip, then the rest of the day as a timeline.
struct TodayView: View {
    @Environment(AppModel.self) private var model

    /// The trip on screen in the other tabs, else the one happening now.
    private var tripID: String? {
        model.selectedTripID ?? model.sections().current?.id
    }

    var body: some View {
        NavigationStack {
            Group {
                if let tripID, let loaded = model.trip(tripID) {
                    if let today = TodayPlan(plan: loaded.plan, today: model.today, now: model.now,
                                             skipped: model.skipped[tripID] ?? []) {
                        TodayContent(tripID: tripID, plan: loaded.plan, today: today)
                    } else {
                        NotToday(plan: loaded.plan)
                    }
                } else if tripID != nil, model.lastError == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No trip today", systemImage: "sun.max",
                                           description: Text("When a trip is happening, its day shows up here."))
                }
            }
            .background(ALColor.surface100)
            .navigationTitle("Today")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { AccountMenu() }
            }
            .navigationDestination(for: ItemRoute.self) { route in
                ItemDetailView(route: route)
            }
            .task(id: tripID) {
                if let tripID { await model.loadTrip(id: tripID) }
            }
        }
    }
}

/// The trip doesn't include today: say when it runs, and offer the trip that is on now.
private struct NotToday: View {
    let plan: TripPlan
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: ALSpace.space4) {
            ContentUnavailableView {
                Label("Nothing planned today", systemImage: "sun.max")
            } description: {
                if let start = plan.collection.startDate, let end = plan.collection.endDate {
                    Text("\(plan.collection.name) runs \(DateRangeText.text(start, end)).")
                } else {
                    Text("\(plan.collection.name) has no dates yet.")
                }
            }
            if let current = model.sections().current, current.id != plan.collection.id {
                Button("Show \(current.name)") { model.selectedTripID = current.id }
                    .buttonStyle(ALButtonStyle(.primary))
            }
        }
        .padding(ALSpace.space4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("today.none")
    }
}

private struct TodayContent: View {
    let tripID: String
    let plan: TripPlan
    let today: TodayPlan
    @Environment(AppModel.self) private var model
    @State private var moving: TripPlan.Entry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ALSpace.space3) {
                Text(plan.collection.name)
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
                    .accessibilityIdentifier("today.trip")
                DayHeader(today: today)
                if let next = today.next {
                    NextCard(tripID: tripID, today: today, next: next)
                }
                if !today.later.isEmpty {
                    Overline(today.next == nil ? "Today" : "Later today").padding(.top, ALSpace.space2)
                    rows(today.later)
                }
                if !today.earlier.isEmpty {
                    Overline("Earlier").padding(.top, ALSpace.space2)
                    rows(today.earlier)
                }
                if today.entries.isEmpty {
                    Text("Nothing planned for today.")
                        .font(ALFont.subheadline)
                        .foregroundStyle(ALColor.inkMuted)
                        .alCard()
                }
                if let message = model.lastError {
                    OfflineBanner(message: message)
                }
                SyncStatusLine(tripID: tripID)
                    .padding(.top, ALSpace.space2)
            }
            .padding(.horizontal, ALSpace.space4)
            .padding(.bottom, ALSpace.space6)
        }
        .refreshable {
            model.syncNow()
            await model.loadTrip(id: tripID)
        }
        .sheet(item: $moving) { entry in
            MoveToDaySheet(tripID: tripID, entry: entry)
        }
        .accessibilityIdentifier("today.view")
    }

    private func rows(_ entries: [TodayPlan.Entry]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                NavigationLink(value: ItemRoute(tripID: tripID, itemID: entry.entry.item.id, day: entry.entry.row.date)) {
                    TimelineRow(entry.summary.timelineContent, state: entry.timelineState,
                                isFirst: index == 0, isLast: index == entries.count - 1)
                }
                .buttonStyle(.plain)
                .contextMenu {
                    if entry.status == .skipped {
                        Button("Undo skip", systemImage: "arrow.uturn.backward") {
                            model.setSkipped(false, rowID: entry.rowID, tripID: tripID)
                        }
                    } else if TodayPlan.isPlace(entry.summary.kind) {
                        Button("Skip", systemImage: "forward") {
                            model.setSkipped(true, rowID: entry.rowID, tripID: tripID)
                        }
                    }
                    Button("Move to another day…", systemImage: "calendar") { moving = entry.entry }
                }
            }
        }
    }
}

private struct DayHeader: View {
    let today: TodayPlan

    var body: some View {
        HStack(alignment: .top, spacing: ALSpace.space3) {
            let parts = DayText.tileParts(today.day.date)
            DateTile(weekday: parts.weekday, day: parts.day, month: parts.month, isSelected: true)
            VStack(alignment: .leading, spacing: ALSpace.space1) {
                Text(today.day.name ?? "Day \(today.day.number)")
                    .font(ALFont.title2)
                    .foregroundStyle(ALColor.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("today.title")
                Text(today.metaText)
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
                if today.hasOvernight || today.bookedCount > 0 {
                    HStack(spacing: 6) {
                        if today.hasOvernight { ALBadge("Overnight", style: .info) }
                        if today.bookedCount > 0 { ALBadge.booked("\(today.bookedCount) booked") }
                    }
                    .padding(.top, 2)
                }
            }
        }
        .padding(.top, ALSpace.space1)
    }
}

/// The card for what's next: when, when to leave, and Navigate / Notes / Skip.
private struct NextCard: View {
    let tripID: String
    let today: TodayPlan
    let next: TodayPlan.Entry
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    /// A routed drive time from Apple Maps, when one could be fetched.
    @State private var routedMinutes: Int?

    var body: some View {
        let summary = next.summary
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            Text(TodayPlan.nextLabel(for: next, now: model.now))
                .font(ALFont.overline)
                .textCase(.uppercase)
                .kerning(0.6)
                .foregroundStyle(ALColor.primaryText)
                .accessibilityIdentifier("today.next.label")
            Text(summary.title)
                .font(ALFont.title2)
                .foregroundStyle(ALColor.ink)
                .accessibilityIdentifier("today.next.title")
            if let line = leaveLine {
                line
                    .font(ALFont.body)
                    .foregroundStyle(ALColor.ink)
                    .accessibilityIdentifier("today.next.leave")
            } else if let detail = summary.detail {
                Text(detail).font(ALFont.subheadline).foregroundStyle(ALColor.inkMuted)
            }
            if let reference = summary.reference {
                Text(reference).font(ALFont.reference).foregroundStyle(ALColor.accentText)
            }
            HStack(spacing: ALSpace.space2) {
                if let url = summary.directionsURL {
                    Button("Navigate") { openURL(url) }
                        .buttonStyle(ALButtonStyle(.primary))
                        .accessibilityIdentifier("today.navigate")
                }
                NavigationLink("Notes", value: ItemRoute(tripID: tripID, itemID: next.entry.item.id, day: next.entry.row.date))
                    .buttonStyle(ALButtonStyle(.secondary))
                    .accessibilityIdentifier("today.notes")
                Button("Skip") {
                    withAnimation { model.setSkipped(true, rowID: next.rowID, tripID: tripID) }
                }
                .buttonStyle(ALButtonStyle(.plain))
                .accessibilityIdentifier("today.skip")
            }
            .padding(.top, ALSpace.space1)
        }
        .alCard(padding: ALSpace.space4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("today.next")
        // Skipping an earlier stop changes where you leave from, so the route is redone.
        .task(id: RouteKey(item: next.id, from: origin, to: next.summary.coordinate)) { await route() }
    }

    private var origin: ItemSummary.Coordinate? { LeaveBy.origin(before: next, in: today) }

    private struct RouteKey: Hashable {
        let item: String
        let from: ItemSummary.Coordinate?
        let to: ItemSummary.Coordinate?
    }

    /// "Leave by 18:15 · ~10 min drive", or `nil` when there is nowhere to leave from or no start time.
    private var leaveLine: Text? {
        let summary = next.summary
        guard next.status == .upcoming, let start = summary.start, !summary.isAllDay,
              let origin, let destination = summary.coordinate
        else { return nil }
        let minutes = routedMinutes ?? LeaveBy.estimatedMinutes(from: origin, to: destination)
        let leave = LeaveBy.time(start: start, travelMinutes: minutes)
        let drive = routedMinutes == nil ? "~\(ItemSummary.durationText(minutes: minutes)) drive" : "\(ItemSummary.durationText(minutes: minutes)) drive"
        let time = Text(TripTime.shortTime(leave, in: summary.startZone)).bold()
        return Text("Leave by \(time) · \(drive)")
    }

    /// Asks Apple Maps for the drive time from the previous stop. Skipped in UI tests so their
    /// screenshots don't depend on the network.
    private func route() async {
        routedMinutes = nil
        guard !LaunchOptions.current.offlineSeed, let origin, let destination = next.summary.coordinate else { return }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: origin.latitude, longitude: origin.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: destination.latitude, longitude: destination.longitude)))
        request.transportType = .automobile
        guard let eta = try? await MKDirections(request: request).calculateETA(), !Task.isCancelled else { return }
        routedMinutes = max(1, Int((eta.expectedTravelTime / 60).rounded(.up)))
    }
}

extension TodayPlan.Entry {
    var timelineState: TimelineRow.Status {
        switch status {
        case .done, .ongoing: return .done
        case .skipped: return .skipped
        case .now: return .now
        case .upcoming: return summary.isBooked ? .booked : .planned
        }
    }
}
