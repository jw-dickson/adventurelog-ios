// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI
import UIKit

/// Where an item row leads.
struct ItemRoute: Hashable {
    let tripID: String
    let itemID: String
    /// The itinerary day the row sits on, so times read the same as on the day.
    let day: CalendarDate?
}

/// One trip, a day at a time (Design/review-1, 03): a Days / Whole trip / Not on a day switch, a
/// strip of date tiles, and the selected day's timeline. Rows can be reordered and moved to other
/// days; the change shows at once and syncs when the server can be reached.
struct TripView: View {
    enum Scope: String, CaseIterable, Identifiable {
        case days = "Days"
        case wholeTrip = "Whole trip"
        case unscheduled = "Not on a day"
        var id: String { rawValue }
    }

    let tripID: String
    @Environment(AppModel.self) private var model
    @State private var scope = Scope.days
    @State private var selectedDate: CalendarDate?
    @State private var reordering: ReorderTarget?
    @State private var moving: TripPlan.Entry?
    @State private var newNote: NewNoteSheet.Target?

    /// The day (or the trip-wide list) being reordered.
    struct ReorderTarget: Identifiable {
        let date: CalendarDate?
        let title: String
        var id: String { date?.description ?? "trip" }
    }

    var body: some View {
        Group {
            if let loaded = model.trip(tripID) {
                content(loaded.plan, savedAt: loaded.savedAt)
            } else if model.lastError != nil {
                ContentUnavailableView("This trip isn't saved yet",
                                       systemImage: "icloud.slash",
                                       description: Text("Open it once with a connection to keep a copy on this phone."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(ALColor.surface100)
        .navigationTitle(model.trip(tripID)?.plan.collection.name ?? "Trip")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: ItemRoute.self) { route in
            ItemDetailView(route: route)
        }
        .toolbar {
            if let plan = model.trip(tripID)?.plan {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        if scope == .days, !plan.days.isEmpty {
                            let day = currentDay(in: plan)
                            Button("New note on \(DayText.long(day.date))", systemImage: "note.text") {
                                newNote = .init(date: day.date, label: [DayText.long(day.date), day.name].compactMap { $0 }.joined(separator: " · "))
                            }
                        }
                        Button("Trip-wide note", systemImage: "note.text") {
                            newNote = .init(date: nil, label: "Whole trip")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add")
                    .accessibilityIdentifier("trip.add")
                }
            }
            if let plan = model.trip(tripID)?.plan, let target = reorderTarget(in: plan) {
                ToolbarItem(placement: .primaryAction) {
                    Button("Reorder", systemImage: "arrow.up.arrow.down") { reordering = target }
                        .accessibilityIdentifier("trip.reorder")
                }
            }
        }
        .sheet(item: $reordering) { target in
            ReorderSheet(tripID: tripID, date: target.date, title: target.title)
        }
        .sheet(item: $moving) { entry in
            MoveToDaySheet(tripID: tripID, entry: entry)
        }
        .sheet(item: $newNote) { target in
            NewNoteSheet(target: target, tripID: tripID)
        }
        .task(id: tripID) {
            model.selectedTripID = tripID
            await model.loadTrip(id: tripID)
        }
    }

    @ViewBuilder
    private func content(_ plan: TripPlan, savedAt: Date) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ALSpace.space3) {
                Picker("Show", selection: $scope) {
                    ForEach(Scope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("trip.scope")

                switch scope {
                case .days:
                    if plan.days.isEmpty {
                        ContentUnavailableView("No dates yet", systemImage: "calendar",
                                               description: Text("Give this collection start and end dates in AdventureLog to plan it by day."))
                    } else {
                        let day = currentDay(in: plan)
                        DayStrip(days: plan.days, selected: day.date, today: model.today) { selectedDate = $0 }
                        DayView(plan: plan, day: day, tripID: tripID, now: model.now, moving: $moving)
                    }
                case .wholeTrip:
                    if let cover = plan.collection.coverImageURL {
                        TripCover(url: cover)
                    }
                    EntryList(plan: plan, entries: plan.tripWide, tripID: tripID, now: model.now,
                              empty: "Nothing for the whole trip. Notes and checklists that aren't tied to a day go here.",
                              moving: $moving)
                case .unscheduled:
                    UnscheduledList(plan: plan, tripID: tripID, now: model.now)
                }

                if let message = model.lastError {
                    OfflineBanner(message: message)
                }
                SyncStatusLine(tripID: tripID)
                    .padding(.top, ALSpace.space2)
                if !plan.collection.currentUserIsOwner, let owner = plan.collection.owner {
                    Text("Shared by \(owner.displayName). Your changes go to their trip.")
                        .font(ALFont.footnote)
                        .foregroundStyle(ALColor.inkMuted)
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                }
                Text("Saved on this phone \(savedAt.formatted(.relative(presentation: .named)))")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, ALSpace.space1)
            }
            .padding(.horizontal, ALSpace.space4)
            .padding(.bottom, ALSpace.space6)
        }
        .refreshable {
            model.syncNow()
            await model.loadTrip(id: tripID)
        }
        .accessibilityIdentifier("trip.view")
    }

    /// What the Reorder button reorders in the current scope, if anything.
    private func reorderTarget(in plan: TripPlan) -> ReorderTarget? {
        switch scope {
        case .days:
            guard !plan.days.isEmpty else { return nil }
            let day = currentDay(in: plan)
            guard day.entries.count > 1 else { return nil }
            return ReorderTarget(date: day.date, title: day.name ?? "Day \(day.number)")
        case .wholeTrip:
            return plan.tripWide.count > 1 ? ReorderTarget(date: nil, title: "Whole trip") : nil
        case .unscheduled:
            return nil
        }
    }

    /// The chosen day, else today when the trip is on, else the first day.
    private func currentDay(in plan: TripPlan) -> TripPlan.Day {
        if let selectedDate, let day = plan.day(for: selectedDate) { return day }
        if let today = plan.day(for: model.today) { return today }
        return plan.days[0]
    }
}

// MARK: Day strip

private struct DayStrip: View {
    let days: [TripPlan.Day]
    let selected: CalendarDate
    let today: CalendarDate
    let select: (CalendarDate) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: ALSpace.space2) {
                    ForEach(days) { day in
                        Button {
                            select(day.date)
                        } label: {
                            let parts = DayText.tileParts(day.date)
                            DateTile(weekday: parts.weekday, day: parts.day, month: parts.month,
                                     isSelected: day.date == selected, compact: true)
                                .overlay(alignment: .bottom) {
                                    if day.date == today, day.date != selected {
                                        Circle().fill(ALColor.primary).frame(width: 5, height: 5).offset(y: 7)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .id(day.date)
                        .accessibilityIdentifier("day.\(day.date)")
                        .accessibilityValue(Text(day.date == today ? "Today" : ""))
                    }
                }
                .padding(.vertical, ALSpace.space2)
            }
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { _, date in
                withAnimation { proxy.scrollTo(date, anchor: .center) }
            }
        }
    }
}

// MARK: Day

private struct DayView: View {
    let plan: TripPlan
    let day: TripPlan.Day
    let tripID: String
    let now: Date
    @Binding var moving: TripPlan.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(day.name ?? "Day \(day.number)")
                .font(ALFont.title2)
                .foregroundStyle(ALColor.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("day.title")
            Text(meta)
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
            if let description = day.description {
                Text(description)
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.ink)
                    .padding(.top, ALSpace.space1)
            }
        }
        EntryList(plan: plan, entries: day.entries, tripID: tripID, now: now, empty: "Nothing planned for this day.", moving: $moving)
    }

    private var meta: String {
        var parts = [DayText.long(day.date), "Day \(day.number) of \(plan.days.count)"]
        let count = day.entries.count
        if count > 0 { parts.append(count == 1 ? "1 item" : "\(count) items") }
        return parts.joined(separator: " · ")
    }
}

/// Timeline rows for itinerary entries, each leading to the item.
private struct EntryList: View {
    let plan: TripPlan
    let entries: [TripPlan.Entry]
    let tripID: String
    let now: Date
    let empty: String
    @Binding var moving: TripPlan.Entry?

    var body: some View {
        if entries.isEmpty {
            Text(empty)
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alCard()
        } else {
            // A list with no times in it (trip-wide notes) keeps a narrow time column.
            let summaries = entries.map { $0.summary(in: plan) }
            let timed = summaries.contains { $0.start != nil }
            let shifts = ZoneShift.marks(summaries)
            VStack(spacing: 0) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    let summary = summaries[index]
                    if let before = shifts[index].before {
                        ZoneShiftRow(before.text, fitsTimes: timed)
                    }
                    NavigationLink(value: ItemRoute(tripID: tripID, itemID: entry.item.id, day: entry.row.date)) {
                        TimelineRow(summary.timelineContent, state: summary.timelineStatus(at: now),
                                    isFirst: index == 0, isLast: index == entries.count - 1, fitsTimes: timed,
                                    thumbnail: summary.timelineThumbnail)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Move to another day…", systemImage: "calendar") { moving = entry }
                    }
                    if let within = shifts[index].within {
                        ZoneShiftRow(within.text, fitsTimes: timed, continuesRail: index < entries.count - 1)
                    }
                }
            }
        }
    }
}

private struct UnscheduledList: View {
    let plan: TripPlan
    let tripID: String
    let now: Date

    var body: some View {
        if plan.unscheduled.isEmpty {
            Text("Everything in this trip is on a day.")
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .alCard()
        } else {
            VStack(spacing: 0) {
                ForEach(Array(plan.unscheduled.enumerated()), id: \.element.id) { index, item in
                    let summary = ItemSummary(item, day: nil, tripZone: plan.timeZone)
                    NavigationLink(value: ItemRoute(tripID: tripID, itemID: item.id, day: nil)) {
                        TimelineRow(summary.timelineContent, state: summary.timelineStatus(at: now),
                                    isFirst: index == 0, isLast: index == plan.unscheduled.count - 1, fitsTimes: false,
                                    thumbnail: summary.timelineThumbnail)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: Shared text and mapping

extension ItemSummary {
    var timelineContent: TimelineRow.Content {
        TimelineRow.Content(
            time: startText(),
            secondaryTime: secondaryTimeText(),
            symbol: symbol,
            title: title,
            reference: reference,
            detail: detail,
            isBooked: isBooked
        )
    }

    /// The item's photo for its timeline card, from the offline pack; nil when it has none.
    var timelineThumbnail: AnyView? {
        imageURL.map { AnyView(SavedPhoto(url: $0)) }
    }

    func timelineStatus(at now: Date) -> TimelineRow.Status {
        if isPast(at: now) { return .done }
        if let start, let end, !isAllDay, start <= now, now < end { return .now }
        return isBooked ? .booked : .planned
    }
}

enum DayText {
    private static let utc = TimeZone(secondsFromGMT: 0)!

    static func tileParts(_ date: CalendarDate, locale: Locale = .autoupdatingCurrent) -> (weekday: String, day: String, month: String) {
        let instant = date.startOfDay(in: utc)
        let calendar = Calendar(identifier: .gregorian)
        let weekday = instant.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: utc).weekday(.abbreviated))
        let month = instant.formatted(Date.FormatStyle(locale: locale, calendar: calendar, timeZone: utc).month(.abbreviated))
        return (weekday, String(date.day), month)
    }

    /// "Mon 8 Mar".
    static func long(_ date: CalendarDate, locale: Locale = .autoupdatingCurrent) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: utc)
            .weekday(.abbreviated).day().month(.abbreviated)
        return date.startOfDay(in: utc).formatted(style)
    }
}

// MARK: Photos

/// A photo from the offline pack, filling whatever frame it's given. A quiet fill stands in while
/// it loads, or if it was never saved and the server can't be reached.
struct SavedPhoto: View {
    let url: URL
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            ALColor.surface300
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            }
        }
        .task(id: url) {
            // A new URL starts from the fill, so a photo that can't be loaded never leaves the old one up.
            image = nil
            let data = await model.imageData(for: url)
            guard !Task.isCancelled else { return }
            image = data.flatMap { UIImage(data: $0) }
        }
    }
}

/// The trip's cover photo at the top of Whole trip.
private struct TripCover: View {
    let url: URL

    var body: some View {
        // A photo, not text: the same height at every text size, so it doesn't fill the screen at XXL.
        Color.clear
            .frame(height: 180)
            .frame(maxWidth: .infinity)
            .overlay { SavedPhoto(url: url) }
            .clipShape(RoundedRectangle(cornerRadius: ALRadius.box, style: .continuous))
            .accessibilityHidden(true)
    }
}
