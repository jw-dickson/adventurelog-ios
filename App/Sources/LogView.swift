// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import CoreLocation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Log tab (Design/review-1, 07): what actually happened against the plan, from the route
/// this phone recorded. Trip shows every day so far; Today (or a day picked from Trip) shows the
/// plan item by item. The route stays on the phone; GPX shares it.
struct LogView: View {
    enum Scope: Hashable { case trip, day }

    @Environment(AppModel.self) private var model
    @State private var scope = Scope.day
    @State private var pickedDate: CalendarDate?

    private var tripID: String? {
        model.selectedTripID ?? model.sections().current?.id
    }

    var body: some View {
        NavigationStack {
            Group {
                if let tripID, let loaded = model.trip(tripID) {
                    LogContent(tripID: tripID, plan: loaded.plan, scope: $scope, pickedDate: $pickedDate)
                } else if tripID != nil, model.lastError == nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ContentUnavailableView("No trip to log", systemImage: "point.topleft.down.to.point.bottomright.curvepath",
                                           description: Text("When a trip is happening, what you did each day shows up here."))
                }
            }
            .background(ALColor.surface100)
            .navigationTitle("Log")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { AccountMenu() }
            }
            .task(id: tripID) {
                guard let tripID else { return }
                await model.loadTrip(id: tripID)
                await model.loadTrack(tripID: tripID)
            }
            .onChange(of: tripID) { pickedDate = nil }
        }
    }
}

private struct LogContent: View {
    let tripID: String
    let plan: TripPlan
    @Binding var scope: LogView.Scope
    @Binding var pickedDate: CalendarDate?
    @Environment(AppModel.self) private var model

    /// Trip days up to today (all of them once the trip is over).
    private var daysSoFar: [CalendarDate] {
        plan.days.map(\.date).filter { $0 <= model.today }
    }

    /// The day on screen: the one picked from Trip, else today, else the trip's last day so far.
    private var date: CalendarDate? {
        pickedDate ?? (plan.day(for: model.today) != nil ? model.today : daysSoFar.last)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ALSpace.space3) {
                Text(plan.collection.name)
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
                Picker("Show", selection: $scope) {
                    Text("Trip").tag(LogView.Scope.trip)
                    Text(dayLabel).tag(LogView.Scope.day)
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("log.scope")

                TrackingStatus(tripID: tripID)

                switch scope {
                case .trip: tripSection
                case .day: daySection
                }
            }
            .padding(.horizontal, ALSpace.space4)
            .padding(.bottom, ALSpace.space6)
        }
        .refreshable { await model.loadTrip(id: tripID) }
        .accessibilityIdentifier("log.view")
    }

    private var dayLabel: String {
        guard let date, date != model.today else { return "Today" }
        return plan.day(for: date).map { "D\($0.number)" } ?? "Day"
    }

    // MARK: One day

    @ViewBuilder private var daySection: some View {
        if let date, let log = model.dayLog(tripID: tripID, date: date) {
            if pickedDate != nil, let day = plan.day(for: date) {
                Text(DayTitle.text(day))
                    .font(ALFont.headline)
                    .foregroundStyle(ALColor.ink)
            }
            HStack(spacing: ALSpace.space3) {
                StatTile(label: "Driven", value: kilometresText(log.drivenKilometres), unit: "km",
                         progress: log.plannedKilometres.map { min(log.drivenKilometres / max($0, 1), 1) } ?? (log.drivenKilometres > 0 ? 1 : 0))
                    .accessibilityIdentifier("log.driven")
                StatTile(label: "Plan done", value: "\(log.plannedDone)", unit: "/ \(log.plannedCount)",
                         progress: log.plannedCount == 0 ? 0 : Double(log.plannedDone) / Double(log.plannedCount))
                    .accessibilityIdentifier("log.done")
            }
            if log.rows.isEmpty {
                Text("Nothing planned this day.")
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
                    .alCard()
            } else {
                Overline("Plan vs what happened").padding(.top, ALSpace.space2)
                VStack(spacing: 0) {
                    ForEach(Array(log.rows.enumerated()), id: \.element.id) { index, row in
                        LogRowView(row: row)
                        if index < log.rows.count - 1 { Divider().overlay(ALColor.hairline) }
                    }
                }
                .padding(.horizontal, ALSpace.space3)
                .background(ALColor.surface200, in: RoundedRectangle(cornerRadius: ALRadius.box, style: .continuous))
            }
            if log.points.isEmpty {
                Text(log.date == model.today ? "No route recorded yet today." : "No route was recorded this day.")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
            }
            exportSection(days: [date], hasRoute: !log.points.isEmpty)
        } else {
            Text("The trip hasn't started yet.")
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
                .alCard()
        }
    }

    // MARK: Whole trip

    @ViewBuilder private var tripSection: some View {
        let logs = daysSoFar.compactMap { model.dayLog(tripID: tripID, date: $0) }
        let driven = logs.reduce(0) { $0 + $1.drivenKilometres }
        let planned = logs.compactMap(\.plannedKilometres).reduce(0, +)
        let done = logs.reduce(0) { $0 + $1.plannedDone }
        let count = logs.reduce(0) { $0 + $1.plannedCount }
        HStack(spacing: ALSpace.space3) {
            StatTile(label: "Driven", value: kilometresText(driven), unit: "km",
                     progress: planned > 0 ? min(driven / planned, 1) : (driven > 0 ? 1 : 0))
            StatTile(label: "Plan done", value: "\(done)", unit: "/ \(count)",
                     progress: count == 0 ? 0 : Double(done) / Double(count))
        }
        if logs.isEmpty {
            Text("The trip hasn't started yet.")
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
                .alCard()
        } else {
            Overline("Day by day").padding(.top, ALSpace.space2)
            VStack(spacing: 0) {
                ForEach(Array(logs.reversed().enumerated()), id: \.element.date) { index, log in
                    Button {
                        pickedDate = log.date == model.today ? nil : log.date
                        scope = .day
                    } label: {
                        TripDayRow(plan: plan, log: log)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("log.day.\(log.date)")
                    if index < logs.count - 1 { Divider().overlay(ALColor.hairline) }
                }
            }
            .padding(.horizontal, ALSpace.space3)
            .background(ALColor.surface200, in: RoundedRectangle(cornerRadius: ALRadius.box, style: .continuous))
            exportSection(days: daysSoFar, hasRoute: logs.contains { !$0.points.isEmpty })
        }
    }

    @ViewBuilder private func exportSection(days: [CalendarDate], hasRoute: Bool) -> some View {
        if hasRoute {
            Overline("For Lightroom").padding(.top, ALSpace.space2)
            ShareLink(item: GPXExport(model: model, tripID: tripID, days: days),
                      preview: SharePreview(days.count == 1 ? "Route for the day (GPX)" : "Route for the trip (GPX)")) {
                Text("GPX track").frame(maxWidth: .infinity)
            }
            .buttonStyle(ALButtonStyle(.secondary))
            .accessibilityIdentifier("log.gpx")
        }
    }

    private func kilometresText(_ value: Double) -> String {
        value < 10 ? value.formatted(.number.precision(.fractionLength(1))) : Int(value.rounded()).formatted()
    }
}

/// "Mon 8 Mar · D2 · Hobart → Freycinet" (the day's name, else "Day 2").
enum DayTitle {
    static func text(_ day: TripPlan.Day) -> String {
        let name = day.name.flatMap { $0.isEmpty ? nil : $0 } ?? "Day \(day.number)"
        return DayText.long(day.date) + " · " + name
    }
}

private struct StatTile: View {
    let label: String
    let value: String
    let unit: String
    let progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            Text(label.uppercased())
                .font(ALFont.overline)
                .tracking(0.8)
                .foregroundStyle(ALColor.inkMuted)
            HStack(alignment: .firstTextBaseline, spacing: ALSpace.space1) {
                Text(value)
                    .font(.system(.largeTitle, weight: .bold))
                    .foregroundStyle(ALColor.primaryText)
                    .minimumScaleFactor(0.6)
                Text(unit)
                    .font(ALFont.title3)
                    .foregroundStyle(ALColor.inkMuted)
            }
            .lineLimit(1)
            ProgressView(value: max(0, min(progress, 1)))
                .tint(ALColor.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alCard(padding: ALSpace.space4)
        .accessibilityElement(children: .combine)
    }
}

private struct LogRowView: View {
    let row: LogRow

    var body: some View {
        HStack(alignment: .center, spacing: ALSpace.space3) {
            // Wide enough for any time this locale writes, so "10:58 AM" isn't wrapped or cut.
            TimeColumn(alignment: .leading) {
                TimeText(row.actualStart.map { TripTime.shortTime($0, in: row.zone) })
                    .foregroundStyle(ALColor.ink)
                if let planned = row.plannedStart, showsPlanned(planned) {
                    Text(TripTime.shortTime(planned, in: row.zone))
                        .font(ALFont.footnote)
                        .strikethrough(row.actualStart != nil)
                        .foregroundStyle(ALColor.inkMuted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .padding(.top, 2)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(ALFont.headline)
                    .foregroundStyle(ALColor.ink)
                Text(row.detail)
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            badge
        }
        .padding(.vertical, ALSpace.space3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("log.row")
    }

    /// The planned time is shown when it differs from what happened (or nothing happened yet).
    private func showsPlanned(_ planned: Date) -> Bool {
        guard let actual = row.actualStart else { return true }
        return abs(actual.timeIntervalSince(planned)) >= 60
    }

    @ViewBuilder private var badge: some View {
        switch row.status {
        case .done: ALBadge("Done", style: .done)
        case .late: ALBadge("Late", style: .drift)
        case .skipped: ALBadge("Skipped", style: .skipped)
        case .missed: ALBadge("Missed", style: .neutral)
        case .unplanned: ALBadge("New", style: .info)
        case .upcoming: EmptyView()
        }
    }
}

private struct TripDayRow: View {
    let plan: TripPlan
    let log: DayLog

    var body: some View {
        HStack(spacing: ALSpace.space3) {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.day(for: log.date).map(DayTitle.text) ?? log.date.description)
                    .font(ALFont.headline)
                    .foregroundStyle(ALColor.ink)
                Text(summary)
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right")
                .font(ALFont.footnote)
                .foregroundStyle(ALColor.inkMuted)
        }
        .padding(.vertical, ALSpace.space3)
        .contentShape(Rectangle())
    }

    private var summary: String {
        var parts = ["\(log.plannedDone) of \(log.plannedCount) done"]
        if log.drivenKilometres >= 0.1 { parts.append("\(Int(log.drivenKilometres.rounded())) km") }
        let unplanned = log.rows.filter { $0.status == .unplanned }.count
        if unplanned > 0 { parts.append(unplanned == 1 ? "1 unplanned stop" : "\(unplanned) unplanned stops") }
        if log.points.isEmpty { parts.append("no route") }
        return parts.joined(separator: " · ")
    }
}

/// Whether the route is being recorded, with the switch and a way to fix a refused permission.
private struct TrackingStatus: View {
    let tripID: String
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL

    var body: some View {
        let allowed = model.trackingAllowed.contains(tripID)
        let refused = model.tracker.authorization == .denied || model.tracker.authorization == .restricted
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            Toggle(isOn: Binding(get: { allowed }, set: { model.setTracking($0, tripID: tripID) })) {
                Label(statusText(allowed: allowed, refused: refused), systemImage: allowed && model.tracker.isRunning ? "location.fill" : "location")
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.ink)
            }
            .tint(ALColor.primary)
            .accessibilityIdentifier("log.tracking")
            if allowed, refused {
                Button("Allow location in Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                }
                .buttonStyle(ALButtonStyle(.plain, small: true))
            }
        }
        .alCard()
    }

    private func statusText(allowed: Bool, refused: Bool) -> String {
        guard allowed else { return "Record my route on trip days" }
        if refused { return "Location is off for AdventureLog" }
        if model.trackedTripID == tripID, model.tracker.isRunning { return "Recording today's route" }
        return "Records on trip days"
    }
}

/// On Today, once per trip: asks whether to record the route on its days.
struct TrackingOffer: View {
    let tripID: String
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.shouldOfferTracking(tripID) {
            VStack(alignment: .leading, spacing: ALSpace.space2) {
                Label("Log where you actually go", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                    .font(ALFont.headline)
                    .foregroundStyle(ALColor.ink)
                Text("On this trip's days, record your route and stops so the Log can show the day against the plan and you can export a GPX track. It stays on this phone.")
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
                HStack {
                    Button("Record trip days") { model.setTracking(true, tripID: tripID) }
                        .buttonStyle(ALButtonStyle(.primary, small: true))
                        .accessibilityIdentifier("tracking.offer.on")
                    Button("No thanks") { model.setTracking(false, tripID: tripID) }
                        .buttonStyle(ALButtonStyle(.plain, small: true))
                        .accessibilityIdentifier("tracking.offer.off")
                }
            }
            .alCard(padding: ALSpace.space4)
            .accessibilityIdentifier("tracking.offer")
        }
    }
}

/// A GPX file made when the share sheet asks for it, not every time the view draws.
struct GPXExport: Transferable, Sendable {
    let model: AppModel
    let tripID: String
    let days: [CalendarDate]

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .gpx) { export in
            SentTransferredFile(try await export.model.gpxFile(tripID: export.tripID, days: export.days))
        }
    }
}

extension UTType {
    static var gpx: UTType { UTType(filenameExtension: "gpx", conformingTo: .xml) ?? .xml }
}
