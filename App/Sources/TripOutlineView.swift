// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI

/// A plain day-by-day outline of one trip. Pre-design scaffold for Stage 0: it shows that the
/// client, the day assembly and the time-zone rules work on real data. The reviewed Trip day
/// screen (DayHeader, TimelineItem) replaces it in Stage 1.
struct TripOutlineView: View {
    let tripID: String
    @Environment(AppModel.self) private var model
    @State private var plan: TripPlan?
    @State private var savedAt: Date?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let plan {
                ForEach(plan.days) { day in
                    Section {
                        if day.entries.isEmpty {
                            Text("Nothing planned")
                                .font(ALFont.subheadline)
                                .foregroundStyle(ALColor.inkMuted)
                        }
                        ForEach(day.entries) { entry in
                            OutlineRow(item: entry.item, day: day.date, tripZone: plan.timeZone)
                        }
                    } header: {
                        DayHeaderText(day: day)
                    }
                    .listRowBackground(ALColor.surface200)
                }
                if !plan.tripWide.isEmpty {
                    Section("Whole trip") {
                        ForEach(plan.tripWide) { entry in
                            OutlineRow(item: entry.item, day: nil, tripZone: plan.timeZone)
                        }
                    }
                    .listRowBackground(ALColor.surface200)
                }
                if !plan.unscheduled.isEmpty {
                    Section("Not on a day") {
                        ForEach(plan.unscheduled, id: \.id) { item in
                            OutlineRow(item: item, day: nil, tripZone: plan.timeZone)
                        }
                    }
                    .listRowBackground(ALColor.surface200)
                }
            } else if let errorMessage {
                ContentUnavailableView("Couldn't load this trip", systemImage: "wifi.exclamationmark", description: Text(errorMessage))
                    .listRowBackground(Color.clear)
            } else {
                ProgressView().frame(maxWidth: .infinity).listRowBackground(Color.clear)
            }
            if let savedAt {
                Text("Saved for offline \(savedAt.formatted(.relative(presentation: .named)))")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(ALColor.surface100)
        .navigationTitle(plan?.collection.name ?? "Trip")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("trip.outline")
        .task { await load() }
        .refreshable { await load() }
    }

    /// Shows a cached plan if needed, then refreshes it when a client is available.
    /// Request errors are displayed only without an existing plan. Snapshot write failures are
    /// ignored; the displayed save time is updated even if persistence fails. Results that arrive
    /// after the session changed are dropped.
    private func load() async {
        if plan == nil, let cached = await model.snapshots.trip(id: tripID) {
            plan = TripPlan(cached.value)
            savedAt = cached.savedAt
        }
        guard let client = model.client else { return }
        do {
            let trip = try await client.collection(id: tripID)
            guard model.isCurrent(client) else { return }
            plan = TripPlan(trip)
            try? await model.snapshots.saveTrip(trip)
            savedAt = .now
            errorMessage = nil
        } catch {
            guard model.isCurrent(client) else { return }
            if plan == nil { errorMessage = error.localizedDescription }
        }
    }
}

private struct DayHeaderText: View {
    let day: TripPlan.Day

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Day \(day.number) · \(dateText)")
                .font(ALFont.overline)
                .textCase(.uppercase)
                .foregroundStyle(ALColor.inkMuted)
            if let name = day.name {
                Text(name)
                    .font(ALFont.headline)
                    .foregroundStyle(ALColor.ink)
                    .textCase(nil)
            }
        }
    }

    private var dateText: String {
        let utc = TimeZone(secondsFromGMT: 0)!
        let style = Date.FormatStyle(timeZone: utc).weekday(.abbreviated).day().month(.abbreviated)
        return day.date.startOfDay(in: utc).formatted(style)
    }
}

private struct OutlineRow: View {
    let item: TripPlan.Item
    let day: CalendarDate?
    let tripZone: TimeZone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: ALSpace.space3) {
            Text(timeText ?? "")
                .font(ALFont.time)
                .monospacedDigit()
                .foregroundStyle(ALColor.ink)
                .frame(width: 64, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Label {
                    Text(item.title).font(ALFont.headline).foregroundStyle(ALColor.ink)
                } icon: {
                    Image(systemName: symbol).foregroundStyle(ALColor.inkMuted)
                }
                if let detail {
                    Text(detail).font(ALFont.subheadline).foregroundStyle(ALColor.inkMuted)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch item {
        case .location: return "mappin.and.ellipse"
        case .transportation(let leg):
            switch leg.type {
            case .plane: return "airplane"
            case .car: return "car.fill"
            case .train: return "tram.fill"
            case .bus: return "bus.fill"
            case .boat: return "ferry.fill"
            case .bike: return "bicycle"
            case .walking: return "figure.walk"
            case .other: return "arrow.triangle.swap"
            }
        case .lodging: return "bed.double.fill"
        case .note: return "note.text"
        case .checklist: return "checklist"
        case .missing: return "questionmark.circle"
        }
    }

    /// Start time in the item's own zone, with "+N" when it ends on a later local date.
    private var timeText: String? {
        switch item {
        case .location(_, let visits):
            guard let visit = visits.first, let start = visit.startDate else { return nil }
            if TripTime.isAllDay(start: start, end: visit.endDate) { return "All day" }
            return TripTime.shortTime(start, in: TripTime.zone(visit.timezone, fallback: tripZone))
        case .transportation(let leg):
            guard let start = leg.date else { return nil }
            return TripTime.shortTime(start, in: TripTime.zone(leg.startTimezone, fallback: tripZone))
        case .lodging(let stay):
            guard let checkIn = stay.checkIn else { return nil }
            return TripTime.shortTime(checkIn, in: TripTime.zone(stay.timezone, fallback: tripZone))
        default:
            return nil
        }
    }

    private var detail: String? {
        switch item {
        case .transportation(let leg):
            var parts: [String] = []
            if let from = leg.startCode ?? leg.fromLocation, let to = leg.endCode ?? leg.toLocation { parts.append("\(from) → \(to)") }
            if let arrive = leg.endDate {
                let zone = TripTime.zone(leg.endTimezone, fallback: tripZone)
                var text = "arrives \(TripTime.shortTime(arrive, in: zone))"
                if let day, let offset = TripTime.offsetLabel(TripTime.dayOffset(of: arrive, in: zone, from: day)) {
                    text += " \(offset)"
                }
                parts.append(text)
            }
            if let number = leg.flightNumber { parts.append(number) }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        case .lodging(let stay):
            return [stay.reservationNumber, stay.location].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case .location(let place, _):
            return [place.category.map { "\($0.displayName) \($0.icon ?? "")".trimmingCharacters(in: .whitespaces) }, place.location]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        case .checklist(let list):
            return "\(list.checkedCount) of \(list.items.count) done"
        case .note(let note):
            return note.content?.split(separator: "\n").first.map(String.init)
        case .missing:
            return "Not in this trip any more"
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
