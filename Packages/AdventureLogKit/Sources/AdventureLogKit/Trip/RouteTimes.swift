// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Drive times looked up along real roads (#42), kept on the phone so leave-by reminders, Today
/// and replan use them offline too. The app asks Apple Maps for each leg of the plan at the time
/// it's planned to set off; anything not looked up yet falls back to `LeaveBy.estimatedMinutes`.
///
/// Legs are keyed by their two ends, rounded to about 100 m, so a stop that moves a few metres
/// keeps its time and two rows at the same place share one.
public struct RouteTimes: Codable, Sendable, Hashable {
    public struct Key: Codable, Sendable, Hashable, Comparable {
        /// Thousandths of a degree.
        public let fromLatitude: Int
        public let fromLongitude: Int
        public let toLatitude: Int
        public let toLongitude: Int

        public init(from a: ItemSummary.Coordinate, to b: ItemSummary.Coordinate) {
            fromLatitude = Self.round(a.latitude)
            fromLongitude = Self.round(a.longitude)
            toLatitude = Self.round(b.latitude)
            toLongitude = Self.round(b.longitude)
        }

        static func round(_ degrees: Double) -> Int { Int((degrees * 1000).rounded()) }

        public static func < (a: Key, b: Key) -> Bool {
            (a.fromLatitude, a.fromLongitude, a.toLatitude, a.toLongitude)
                < (b.fromLatitude, b.fromLongitude, b.toLatitude, b.toLongitude)
        }
    }

    public struct Entry: Codable, Sendable, Hashable {
        public let key: Key
        /// Minutes by road, or `nil` when Apple Maps found no road route (an island, a ferry).
        public let minutes: Int?
        /// When it was looked up, and the departure it was looked up for.
        public let fetched: Date
        public let departure: Date

        public init(key: Key, minutes: Int?, fetched: Date, departure: Date) {
            self.key = key
            self.minutes = minutes
            self.fetched = fetched
            self.departure = departure
        }
    }

    /// One drive between two stops in the plan, and when it's planned to start.
    public struct Leg: Sendable, Hashable {
        public let from: ItemSummary.Coordinate
        public let to: ItemSummary.Coordinate
        public let departure: Date
        public var key: Key { Key(from: from, to: to) }

        public init(from: ItemSummary.Coordinate, to: ItemSummary.Coordinate, departure: Date) {
            self.from = from
            self.to = to
            self.departure = departure
        }
    }

    /// Kept in key order so the saved file is stable.
    public private(set) var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries.sorted { $0.key < $1.key }
    }

    /// An answer older than this is asked again.
    public static let refreshAfter: TimeInterval = 24 * 3600
    /// Looked up for a departure further off than this from the planned one: asked again for the
    /// new time, since traffic differs.
    public static let departureSlack: TimeInterval = 3 * 3600
    /// Entries not refreshed for this long are dropped.
    public static let keepFor: TimeInterval = 14 * 24 * 3600
    /// Legs starting within this of now are looked up: today and tomorrow.
    public static let lookAhead: TimeInterval = 48 * 3600

    public func entry(from a: ItemSummary.Coordinate, to b: ItemSummary.Coordinate) -> Entry? {
        let key = Key(from: a, to: b)
        return entries.first { $0.key == key }
    }

    /// The routed minutes, when that leg has been looked up and has a road route.
    public func minutes(from a: ItemSummary.Coordinate, to b: ItemSummary.Coordinate) -> Int? {
        entry(from: a, to: b)?.minutes
    }

    /// The time to plan with: routed when known, else the straight-line estimate.
    public func travel(from a: ItemSummary.Coordinate, to b: ItemSummary.Coordinate) -> Travel {
        if let routed = minutes(from: a, to: b) { return Travel(minutes: routed, isRouted: true) }
        return Travel(minutes: LeaveBy.estimatedMinutes(from: a, to: b), isRouted: false)
    }

    public struct Travel: Sendable, Hashable {
        public let minutes: Int
        public let isRouted: Bool

        public init(minutes: Int, isRouted: Bool) {
            self.minutes = minutes
            self.isRouted = isRouted
        }

        /// "40 min drive" when routed, "~40 min drive" for the estimate.
        public var driveText: String {
            (isRouted ? "" : "~") + ItemSummary.durationText(minutes: minutes) + " drive"
        }
    }

    /// Whether `leg` should be (re)looked up now.
    public func needsLookup(_ leg: Leg, now: Date) -> Bool {
        guard let entry = entries.first(where: { $0.key == leg.key }) else { return true }
        return now.timeIntervalSince(entry.fetched) >= Self.refreshAfter
            || abs(entry.departure.timeIntervalSince(leg.departure)) > Self.departureSlack
    }

    /// Keeps an answer from Apple Maps; `seconds` is `nil` for no road route.
    public mutating func record(_ leg: Leg, seconds: TimeInterval?, at now: Date) {
        let minutes = seconds.map { max(1, Int(($0 / 60).rounded(.up))) }
        let entry = Entry(key: leg.key, minutes: minutes, fetched: now, departure: leg.departure)
        if let index = entries.firstIndex(where: { $0.key == leg.key }) {
            entries[index] = entry
        } else {
            entries.append(entry)
            entries.sort { $0.key < $1.key }
        }
    }

    /// Drops answers not refreshed for `keepFor`.
    public mutating func prune(now: Date) {
        entries.removeAll { now.timeIntervalSince($0.fetched) > Self.keepFor }
    }

    /// The drives in `plan` worth looking up now: legs setting off from an hour ago to `lookAhead`
    /// out, soonest first, that `needsLookup`. Each leg runs from the last place before a timed
    /// stop (as reminders and Today measure it) to that stop, more than 300 m apart.
    /// The same two ends twice in that time are looked up once, for the sooner drive.
    public func legsToLookUp(in plan: TripPlan, now: Date, skipped: Set<String> = []) -> [Leg] {
        var seen: Set<Key> = []
        return Self.legs(in: plan, skipped: skipped)
            .filter { $0.departure >= now.addingTimeInterval(-3600) && $0.departure <= now.addingTimeInterval(Self.lookAhead) }
            .filter { needsLookup($0, now: now) && seen.insert($0.key).inserted }
    }

    /// Every drive between consecutive places in `plan`, soonest first.
    public static func legs(in plan: TripPlan, skipped: Set<String> = []) -> [Leg] {
        var legs: [Leg] = []
        for day in plan.days {
            let summaries = day.entries.map { $0.summary(in: plan) }
            for (index, entry) in day.entries.enumerated() {
                let summary = summaries[index]
                guard !skipped.contains(entry.row.id), TodayPlan.isPlace(summary.kind),
                      let start = summary.start, !summary.isAllDay, let destination = summary.coordinate,
                      let origin = ReminderPlanner.origin(before: index, in: day.entries, summaries: summaries, skipped: skipped),
                      LeaveBy.kilometres(from: origin, to: destination) > ReminderPlanner.sameplaceKilometres
                else { continue }
                let estimate = LeaveBy.estimatedMinutes(from: origin, to: destination)
                let leg = Leg(from: origin, to: destination, departure: start.addingTimeInterval(-Double(estimate * 60)))
                legs.append(leg)
            }
        }
        return legs.sorted { $0.departure < $1.departure }
    }

    // Saved as a plain list, so the file reads as entries.
    public init(from decoder: any Decoder) throws {
        self.init(entries: try decoder.singleValueContainer().decode([Entry].self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(entries)
    }
}
