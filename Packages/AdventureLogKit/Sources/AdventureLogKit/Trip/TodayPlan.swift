// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Today on a trip (Design/review-1, 02): what's next, what's later, what's behind you.
///
/// Built from the day's itinerary rows in their planned order, the clock, and the rows the person
/// skipped on this phone.
public struct TodayPlan: Sendable {
    public enum Status: Sendable, Hashable {
        /// Over: ended, or a checklist with every item ticked.
        case done
        /// Skipped on this phone.
        case skipped
        /// Started and still going, and short enough to be the thing you're doing.
        case now
        /// Started earlier and runs past today, like a car hire or a stay: not "next".
        case ongoing
        /// Still ahead, or untimed.
        case upcoming
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public let entry: TripPlan.Entry
        public let summary: ItemSummary
        public let status: Status
        public var id: String { entry.id }
        public var rowID: String { entry.row.id }
    }

    public let day: TripPlan.Day
    public let dayCount: Int
    /// Every row of the day, in order.
    public let entries: [Entry]
    /// The first row in order that is happening now or still ahead and is somewhere to be
    /// (not a note or checklist).
    public let next: Entry?
    /// Rows after `next`, or every row still ahead when there is no `next`.
    public let later: [Entry]
    /// Rows that are done, skipped or already under way.
    public let earlier: [Entry]
    /// Places, legs and stays that are over, skipped or under way, out of all of them.
    public let doneCount: Int
    public let countable: Int
    /// Ground travel planned today, in whole kilometres; `nil` when there is none.
    public let groundKilometres: Int?
    public let bookedCount: Int
    /// A stay checks in today.
    public let hasOvernight: Bool

    /// - Returns: `nil` when `today` is not a day of the trip.
    public init?(plan: TripPlan, today: CalendarDate, now: Date, skipped: Set<String> = []) {
        guard let day = plan.day(for: today) else { return nil }
        self.day = day
        self.dayCount = plan.days.count

        let entries = day.entries.map { entry -> Entry in
            let summary = entry.summary(in: plan)
            return Entry(entry: entry, summary: summary, status: Self.status(of: entry, summary: summary, now: now, skipped: skipped))
        }
        self.entries = entries

        let next = entries.first { candidate in
            Self.isPlace(candidate.summary.kind) && (candidate.status == .now || candidate.status == .upcoming)
        }
        self.next = next
        let rest = entries.filter { $0.id != next?.id }
        let behind: Set<Status> = [.done, .skipped, .ongoing]
        self.earlier = rest.filter { behind.contains($0.status) }
        self.later = rest.filter { !behind.contains($0.status) }

        let places = entries.filter { Self.isPlace($0.summary.kind) }
        self.countable = places.count
        self.doneCount = places.filter { behind.contains($0.status) }.count
        self.bookedCount = entries.filter(\.summary.isBooked).count
        self.hasOvernight = entries.contains { $0.summary.kind == .lodging }

        var kilometres = 0.0
        for entry in entries {
            if case .transportation(let leg) = entry.entry.item, leg.type != .plane, let distance = leg.distance {
                kilometres += distance
            }
        }
        self.groundKilometres = kilometres >= 1 ? Int(kilometres.rounded()) : nil
    }

    /// Notes and checklists are things to read or tick, not places to be.
    public static func isPlace(_ kind: ItemKind) -> Bool {
        kind != .note && kind != .checklist
    }

    static func status(of entry: TripPlan.Entry, summary: ItemSummary, now: Date, skipped: Set<String>) -> Status {
        if skipped.contains(entry.row.id) { return .skipped }
        if case .checklist(let list) = entry.item {
            return !list.items.isEmpty && list.items.allSatisfy(\.isChecked) ? .done : .upcoming
        }
        if summary.isPast(at: now) { return .done }
        guard let start = summary.start, !summary.isAllDay, start <= now else { return .upcoming }
        guard let end = summary.end else { return .upcoming }
        // Started: the thing you're at, unless it runs on past today.
        return summary.spanDays > 0 || end.timeIntervalSince(start) > 18 * 3600 ? .ongoing : .now
    }

    // MARK: Text

    /// "Next · in 25 min", "Next · in 2 h 10 min", "Now · until 20:30", or "Next".
    public static func nextLabel(for entry: Entry, now: Date, locale: Locale = .autoupdatingCurrent) -> String {
        let summary = entry.summary
        if entry.status == .now, let end = summary.end {
            return "Now · until " + TripTime.shortTime(end, in: summary.endZone, locale: locale)
        }
        guard let start = summary.start, !summary.isAllDay, start > now else { return "Next" }
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return "Next · in " + ItemSummary.durationText(minutes: max(minutes, 1))
    }

    /// "Day 4 of 19 · 115 km · 3 of 7 done".
    public var metaText: String {
        var parts = ["Day \(day.number) of \(dayCount)"]
        if let km = groundKilometres { parts.append("\(km) km") }
        if countable > 0 { parts.append("\(doneCount) of \(countable) done") }
        return parts.joined(separator: " · ")
    }
}

/// When to set off for the next item.
///
/// Stage 2 measures from the previous stop in the plan; Stage 3 swaps in the phone's position.
public enum LeaveBy {
    /// The last place before `next` today with a known position (a leg counts from where it ends),
    /// skipping rows the person skipped.
    public static func origin(before next: TodayPlan.Entry, in today: TodayPlan) -> ItemSummary.Coordinate? {
        guard let index = today.entries.firstIndex(where: { $0.id == next.id }) else { return nil }
        for entry in today.entries[..<index].reversed() where entry.status != .skipped {
            let summary = entry.summary
            if summary.kind == .transportation, let point = summary.destination ?? summary.coordinate { return point }
            if let point = summary.coordinate { return point }
        }
        return nil
    }

    /// A rough drive time from the straight-line distance: 1.3× the distance at 50 km/h, rounded up
    /// to 5 minutes, at least 5. Used offline and until a routed estimate arrives.
    public static func estimatedMinutes(from a: ItemSummary.Coordinate, to b: ItemSummary.Coordinate) -> Int {
        let km = kilometres(from: a, to: b) * 1.3
        let minutes = km / 50 * 60
        return max(5, Int((minutes / 5).rounded(.up)) * 5)
    }

    /// Great-circle distance.
    public static func kilometres(from a: ItemSummary.Coordinate, to b: ItemSummary.Coordinate) -> Double {
        let r = 6371.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }

    /// The start minus the travel time and a buffer, rounded down to 5 minutes.
    public static func time(start: Date, travelMinutes: Int, bufferMinutes: Int = 5) -> Date {
        let leave = start.addingTimeInterval(-Double((travelMinutes + bufferMinutes) * 60))
        let seconds = leave.timeIntervalSinceReferenceDate
        return Date(timeIntervalSinceReferenceDate: (seconds / 300).rounded(.down) * 300)
    }
}
