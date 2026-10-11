// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A trip laid out the way AdventureLog's planner shows it: one day per calendar date from the
/// collection's start to end (empty days included), each day's rows in `order`, trip-wide rows,
/// and items that are in the collection but on no day.
public struct TripPlan: Sendable {
    public enum Item: Sendable, Hashable {
        /// A location, with the visits that fall on this day (empty for trip-wide or unscheduled).
        case location(Location, visits: [Visit])
        case transportation(Transportation)
        case lodging(Lodging)
        case note(Note)
        case checklist(Checklist)
        /// A row whose object is not in the collection payload (deleted, or a kind this build does not know).
        case missing(kind: ItemKind, id: String)

        public var id: String {
            switch self {
            case .location(let value, _): return value.id
            case .transportation(let value): return value.id
            case .lodging(let value): return value.id
            case .note(let value): return value.id
            case .checklist(let value): return value.id
            case .missing(_, let id): return id
            }
        }

        public var kind: ItemKind {
            switch self {
            case .location: return .location
            case .transportation: return .transportation
            case .lodging: return .lodging
            case .note: return .note
            case .checklist: return .checklist
            case .missing(let kind, _): return kind
            }
        }

        public var title: String {
            switch self {
            case .location(let value, _): return value.name
            case .transportation(let value): return value.name
            case .lodging(let value): return value.name
            case .note(let value): return value.name
            case .checklist(let value): return value.name
            case .missing: return "Unavailable item"
            }
        }
    }

    public struct Entry: Sendable, Hashable, Identifiable {
        public let row: ItineraryRow
        public let item: Item
        public var id: String { row.id }
    }

    public struct Day: Sendable, Hashable, Identifiable {
        public let date: CalendarDate
        /// 1-based position in the trip.
        public let number: Int
        public let name: String?
        public let description: String?
        public let entries: [Entry]
        public var id: CalendarDate { date }
    }

    public let collection: CollectionDetail
    /// The zone most of the trip's items use; the fallback for items with no zone of their own.
    public let timeZone: TimeZone
    public let days: [Day]
    public let tripWide: [Entry]
    public let unscheduled: [Item]

    /// Assembles days from itinerary dates, ordering entries by row order and then row ID.
    /// Keeps rows outside a valid trip range; with missing or reversed trip dates, uses row and
    /// day-metadata dates. Global or undated rows go trip-wide, and unresolved objects remain as missing items.
    /// - Parameter fallbackTimeZone: Used when the most frequent stored zone cannot be resolved.
    public init(_ collection: CollectionDetail, fallbackTimeZone: TimeZone = .autoupdatingCurrent) {
        self.collection = collection
        let zone = TripPlan.dominantTimeZone(collection) ?? fallbackTimeZone
        self.timeZone = zone

        let locations = Dictionary(collection.locations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let transportations = Dictionary(collection.transportations.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let lodging = Dictionary(collection.lodging.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let notes = Dictionary(collection.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let checklists = Dictionary(collection.checklists.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        func resolve(_ row: ItineraryRow) -> Item {
            switch row.kind {
            case .location:
                guard let location = locations[row.objectId] else { return .missing(kind: .location, id: row.objectId) }
                let visits = row.date.map { TripPlan.visits(of: location, on: $0, fallback: zone) } ?? []
                return .location(location, visits: visits)
            case .transportation:
                return transportations[row.objectId].map(Item.transportation) ?? .missing(kind: .transportation, id: row.objectId)
            case .lodging:
                return lodging[row.objectId].map(Item.lodging) ?? .missing(kind: .lodging, id: row.objectId)
            case .note:
                return notes[row.objectId].map(Item.note) ?? .missing(kind: .note, id: row.objectId)
            case .checklist:
                return checklists[row.objectId].map(Item.checklist) ?? .missing(kind: .checklist, id: row.objectId)
            case .visit, .unknown:
                return .missing(kind: row.kind, id: row.objectId)
            }
        }

        let ordered = collection.itinerary.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
        var byDate: [CalendarDate: [Entry]] = [:]
        var global: [Entry] = []
        for row in ordered {
            let entry = Entry(row: row, item: resolve(row))
            if row.isGlobal || row.date == nil {
                global.append(entry)
            } else if let date = row.date {
                byDate[date, default: []].append(entry)
            }
        }

        let meta = Dictionary(collection.itineraryDays.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
        var dates: [CalendarDate]
        if let start = collection.startDate, let end = collection.endDate, start <= end {
            dates = start.through(end)
            // Rows outside the range should not exist (the server deletes them), but never drop data.
            dates += byDate.keys.filter { $0 < start || $0 > end }
            dates.sort()
        } else {
            dates = Array(Set(byDate.keys).union(meta.keys)).sorted()
        }

        self.days = dates.enumerated().map { index, date in
            Day(
                date: date,
                number: index + 1,
                name: meta[date]?.name?.nilIfBlank,
                description: meta[date]?.description?.nilIfBlank,
                entries: byDate[date] ?? []
            )
        }
        self.tripWide = global

        let placed = Set(collection.itinerary.map(\.objectId))
        var loose: [Item] = []
        loose += collection.locations.filter { !placed.contains($0.id) }.map { .location($0, visits: []) }
        loose += collection.transportations.filter { !placed.contains($0.id) }.map(Item.transportation)
        loose += collection.lodging.filter { !placed.contains($0.id) }.map(Item.lodging)
        loose += collection.notes.filter { !placed.contains($0.id) }.map(Item.note)
        loose += collection.checklists.filter { !placed.contains($0.id) }.map(Item.checklist)
        self.unscheduled = loose
    }

    /// Returns the assembled day for this calendar date, or `nil` if it is absent.
    public func day(for date: CalendarDate) -> Day? {
        days.first { $0.date == date }
    }

    /// Visits of a location whose local start date (its own zone; UTC date when all-day) is `day`.
    /// Omits visits without a start, sorts by start time, and uses `fallback` for missing or invalid zones.
    public static func visits(of location: Location, on day: CalendarDate, fallback: TimeZone) -> [Visit] {
        location.visits.filter { visit in
            guard let start = visit.startDate else { return false }
            let allDay = TripTime.isAllDay(start: start, end: visit.endDate)
            let zone = TripTime.zone(visit.timezone, fallback: fallback)
            return TripTime.localDate(of: start, in: zone, allDay: allDay) == day
        }
        .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
    }

    /// Resolves the most frequent stored zone across visits, lodging, and transport arrivals.
    /// Ties favor the lexicographically smallest identifier. Returns `nil` if no zone is stored
    /// or the winning identifier is invalid, even when a less frequent valid zone exists.
    static func dominantTimeZone(_ collection: CollectionDetail) -> TimeZone? {
        var counts: [String: Int] = [:]
        for location in collection.locations {
            for visit in location.visits { if let tz = visit.timezone { counts[tz, default: 0] += 1 } }
        }
        for stay in collection.lodging { if let tz = stay.timezone { counts[tz, default: 0] += 1 } }
        for leg in collection.transportations { if let tz = leg.endTimezone { counts[tz, default: 0] += 1 } }
        let best = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }
        return best.flatMap { TimeZone(identifier: $0.key) }
    }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
