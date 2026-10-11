// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// The Trips screen's sections, worked out from the person's own calendar date rather than the
/// server's `status` (which uses the server's date and zone).
public struct TripListSections: Sendable, Hashable {
    /// Trips, owned or shared, whose dates include today. Soonest-ending first.
    public let happeningNow: [CollectionSummary]
    /// Owned trips that start after today, soonest first.
    public let upcoming: [CollectionSummary]
    /// Trips shared with the person that are not happening now, soonest first, undated last.
    public let shared: [CollectionSummary]
    /// Owned trips that ended before today, most recent first.
    public let past: [CollectionSummary]
    /// Owned collections without dates, by name.
    public let collections: [CollectionSummary]

    public init(owned: [CollectionSummary], shared: [CollectionSummary], today: CalendarDate, matching query: String = "") {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        func keep(_ trip: CollectionSummary) -> Bool {
            needle.isEmpty || trip.name.localizedStandardContains(needle) || (trip.description?.localizedStandardContains(needle) ?? false)
        }
        let owned = owned.filter { keep($0) && $0.isArchived != true }
        let sharedTrips = shared.filter(keep)

        func range(_ trip: CollectionSummary) -> (CalendarDate, CalendarDate)? {
            guard let start = trip.startDate, let end = trip.endDate else { return nil }
            return (min(start, end), max(start, end)) // the server does not enforce start <= end
        }
        func isNow(_ trip: CollectionSummary) -> Bool {
            guard let dates = range(trip) else { return false }
            return dates.0 <= today && today <= dates.1
        }
        func byName(_ a: CollectionSummary, _ b: CollectionSummary) -> Bool {
            a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        func byStart(_ a: CollectionSummary, _ b: CollectionSummary) -> Bool {
            switch (range(a)?.0, range(b)?.0) {
            case let (x?, y?): return x == y ? byName(a, b) : x < y
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return byName(a, b)
            }
        }

        happeningNow = (owned + sharedTrips).filter(isNow).sorted { a, b in
            let x = range(a)!.1, y = range(b)!.1
            return x == y ? byName(a, b) : x < y
        }
        upcoming = owned.filter { range($0).map { $0.0 > today } ?? false }.sorted(by: byStart)
        self.shared = sharedTrips.filter { !isNow($0) }.sorted(by: byStart)
        past = owned.filter { range($0).map { $0.1 < today } ?? false }.sorted { byStart($1, $0) }
        collections = owned.filter { range($0) == nil }.sorted(by: byName)
    }

    public var isEmpty: Bool {
        happeningNow.isEmpty && upcoming.isEmpty && shared.isEmpty && past.isEmpty && collections.isEmpty
    }

    /// The trip to open on launch: the one happening now, if there is exactly one obvious choice.
    public var current: CollectionSummary? { happeningNow.first }
}
