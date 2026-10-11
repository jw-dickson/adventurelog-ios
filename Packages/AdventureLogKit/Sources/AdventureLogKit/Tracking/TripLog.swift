// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// One line of "plan vs what happened" (Design/review-1, 07).
public struct LogRow: Sendable, Hashable, Identifiable {
    public enum Status: Sendable, Hashable {
        /// Visited, on time or early.
        case done
        /// Visited, this many minutes after the planned start.
        case late(minutes: Int)
        /// Skipped on Today.
        case skipped
        /// Its time has passed and the phone never went there.
        case missed
        /// Still ahead.
        case upcoming
        /// A stop that wasn't in the plan.
        case unplanned
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let status: Status
    public let plannedStart: Date?
    public let actualStart: Date?
    public let actualEnd: Date?
    /// The zone the times are shown in.
    public let zone: TimeZone
    public let coordinate: ItemSummary.Coordinate?
    /// The itinerary row, for planned items.
    public let rowID: String?
    public let itemID: String?
    /// A journey rather than a place: its times are leaving and arriving.
    public let isLeg: Bool

    /// "12 min late · 14 min ride", "Unplanned stop · 22 min", "Not visited".
    public var detail: String {
        let stay = actualStart.flatMap { start in actualEnd.map { Int(($0.timeIntervalSince(start) / 60).rounded()) } }
        switch status {
        case .done:
            if isLeg { return stay.map { "Took \(ItemSummary.durationText(minutes: max($0, 1)))" } ?? "On the way" }
            return stay.map { $0 > 0 ? "Stayed \(ItemSummary.durationText(minutes: $0))" : "Visited" } ?? "Visited"
        case .late(let minutes):
            if isLeg {
                let late = "Left \(ItemSummary.durationText(minutes: minutes)) late"
                return stay.map { late + " · took \(ItemSummary.durationText(minutes: max($0, 1)))" } ?? late
            }
            return "\(ItemSummary.durationText(minutes: minutes)) later than planned"
        case .skipped: return "Skipped"
        case .missed: return "Not visited"
        case .upcoming: return "Still to come"
        case .unplanned: return "Unplanned stop" + (stay.map { " · \(ItemSummary.durationText(minutes: max($0, 1)))" } ?? "")
        }
    }
}

/// What happened on one day of a trip, from the track and geofence events.
public struct DayLog: Sendable {
    public let date: CalendarDate
    public let rows: [LogRow]
    public let points: [TrackPoint]
    public let stops: [DetectedStop]
    public let drivenKilometres: Double
    /// Planned places, stays and legs visited, out of all of them.
    public let plannedDone: Int
    public let plannedCount: Int
    /// Ground travel the plan expected that day.
    public let plannedKilometres: Double?
}

public enum TripLog {
    /// Metres from a planned place within which a stop counts as visiting it.
    static func matchRadius(_ kind: ItemKind) -> Double { kind == .lodging ? 250 : 150 }
    /// Arriving later than this counts as late.
    static let lateAfter: TimeInterval = 10 * 60
    /// Unplanned stops shorter than this are left out of the log (they're still in the GPX).
    static let unplannedMinimum: TimeInterval = 10 * 60

    /// The log for `date`. Points and events can cover the whole trip; only the day's are used,
    /// by the local date in the trip's zone.
    public static func day(_ date: CalendarDate, plan: TripPlan, points: [TrackPoint], events: [PlaceEvent] = [],
                           skipped: Set<String> = [], now: Date) -> DayLog {
        let zone = plan.timeZone
        let dayPoints = points.filter { CalendarDate($0.time, in: zone) == date }.sorted { $0.time < $1.time }
        let stops = StopDetector.stops(in: dayPoints)
        // Stops a place claimed, and stops a leg only started or ended at: the place you drive to
        // is still that place's visit, and neither kind counts as an unplanned stop.
        var used = Set<Int>()
        var legEnds = Set<Int>()
        var rows: [LogRow] = []
        var plannedKilometres = 0.0

        for entry in plan.day(for: date)?.entries ?? [] {
            let summary = entry.summary(in: plan)
            guard TodayPlan.isPlace(summary.kind) else { continue }
            if case .transportation(let leg) = entry.item, leg.type != .plane, let km = leg.distance { plannedKilometres += km }
            // A hire that starts and ends in one place is a stop, not a journey.
            let isLeg: Bool = {
                guard summary.kind == .transportation, let from = summary.coordinate, let to = summary.destination else { return false }
                return LeaveBy.kilometres(from: from, to: to) > 0.3
            }()

            func row(_ status: LogRow.Status, start: Date? = nil, end: Date? = nil) -> LogRow {
                LogRow(id: entry.row.id, title: summary.title, symbol: summary.symbol, status: status,
                       plannedStart: summary.isAllDay ? nil : summary.start, actualStart: start, actualEnd: end,
                       zone: summary.startZone, coordinate: summary.coordinate, rowID: entry.row.id, itemID: entry.item.id,
                       isLeg: isLeg)
            }
            func visited(_ start: Date, _ end: Date?) -> LogRow {
                if let planned = summary.start, !summary.isAllDay, start.timeIntervalSince(planned) > lateAfter {
                    return row(.late(minutes: Int((start.timeIntervalSince(planned) / 60).rounded())), start: start, end: end)
                }
                return row(.done, start: start, end: end)
            }

            if skipped.contains(entry.row.id) {
                rows.append(row(.skipped))
                continue
            }
            // A geofence saw it: the most direct evidence.
            let mine = events.filter { $0.rowID == entry.row.id && CalendarDate($0.time, in: zone) == date }.sorted { $0.time < $1.time }
            if let arrived = mine.first(where: { $0.kind == .arrived }) {
                rows.append(visited(arrived.time, mine.last(where: { $0.kind == .left && $0.time > arrived.time })?.time))
                continue
            }
            // A leg between two places: left the start, reached the end.
            if case .transportation(let leg) = entry.item, let from = summary.coordinate, let to = summary.destination,
               LeaveBy.kilometres(from: from, to: to) > 0.3 {
                if leg.type != .plane, let departure = nearest(stops, to: from, radius: 200, around: summary.start, used: [], preferEnd: true) {
                    let arrival = stops.indices.first { index in
                        stops[index].start > stops[departure].end && distance(stops[index], to) <= 200
                    }
                    let start = stops[departure].end
                    let end = arrival.map { stops[$0].start }
                    legEnds.insert(departure)
                    if let arrival { legEnds.insert(arrival) }
                    rows.append(visited(start, end))
                } else {
                    rows.append(row(passed(summary, now: now) ? .missed : .upcoming))
                }
                continue
            }
            // A place or a stay (or a hire that starts and ends in one place).
            if let point = summary.coordinate,
               let index = nearest(stops, to: point, radius: matchRadius(summary.kind), around: summary.start, used: used, preferEnd: false) {
                used.insert(index)
                rows.append(visited(stops[index].start, stops[index].end))
            } else {
                rows.append(row(passed(summary, now: now) ? .missed : .upcoming))
            }
        }

        let planned = rows.count
        let done = rows.filter { if case .done = $0.status { return true }; if case .late = $0.status { return true }; return false }.count
        for (index, stop) in stops.enumerated() where !used.contains(index) && !legEnds.contains(index) && stop.duration >= unplannedMinimum {
            rows.append(LogRow(id: "stop-\(Int(stop.start.timeIntervalSince1970))", title: "Unplanned stop", symbol: "mappin",
                               status: .unplanned, plannedStart: nil, actualStart: stop.start, actualEnd: stop.end,
                               zone: zone, coordinate: stop.coordinate, rowID: nil, itemID: nil, isLeg: false))
        }
        rows.sort { ($0.actualStart ?? $0.plannedStart ?? .distantFuture) < ($1.actualStart ?? $1.plannedStart ?? .distantFuture) }

        return DayLog(date: date, rows: rows, points: dayPoints, stops: stops,
                      drivenKilometres: StopDetector.kilometres(along: dayPoints),
                      plannedDone: done, plannedCount: planned,
                      plannedKilometres: plannedKilometres >= 1 ? plannedKilometres : nil)
    }

    /// The unused stop within `radius` closest in time to `around` (any stop that day when untimed).
    static func nearest(_ stops: [DetectedStop], to point: ItemSummary.Coordinate, radius: Double, around time: Date?,
                        used: Set<Int>, preferEnd: Bool) -> Int? {
        let candidates = stops.indices.filter { !used.contains($0) && distance(stops[$0], point) <= radius }
        guard let time else { return candidates.first }
        return candidates.min { a, b in
            let ta = preferEnd ? stops[a].end : stops[a].start
            let tb = preferEnd ? stops[b].end : stops[b].start
            return abs(ta.timeIntervalSince(time)) < abs(tb.timeIntervalSince(time))
        }
    }

    static func distance(_ stop: DetectedStop, _ point: ItemSummary.Coordinate) -> Double {
        guard let here = stop.coordinate else { return .infinity }
        return LeaveBy.kilometres(from: here, to: point) * 1000
    }

    /// An hour after it should have started (or the end of its day, untimed), and still no visit.
    static func passed(_ summary: ItemSummary, now: Date) -> Bool {
        if let start = summary.start, !summary.isAllDay { return now > start.addingTimeInterval(3600) }
        guard let day = summary.day else { return false }
        return CalendarDate(now, in: summary.startZone) > day
    }
}

/// A planned stop to watch with a geofence.
public struct WatchedPlace: Sendable, Hashable {
    public let rowID: String
    public let coordinate: ItemSummary.Coordinate
    public let radius: Double
}

extension TripLog {
    /// The day's places and stays still to come, soonest first, for geofences. Journeys are left
    /// out (their start and end are other places), and so are skipped rows and visits whose time
    /// has passed. iOS allows 20 regions per app; the default leaves room to spare.
    public static func placesToWatch(on date: CalendarDate, plan: TripPlan, skipped: Set<String> = [], now: Date,
                                     limit: Int = 15) -> [WatchedPlace] {
        var found: [(start: Date, place: WatchedPlace)] = []
        for entry in plan.day(for: date)?.entries ?? [] where !skipped.contains(entry.row.id) {
            let summary = entry.summary(in: plan)
            guard TodayPlan.isPlace(summary.kind), let point = summary.coordinate else { continue }
            if summary.kind == .transportation, let to = summary.destination, LeaveBy.kilometres(from: point, to: to) > 0.3 { continue }
            if passed(summary, now: now) { continue }
            let start = summary.isAllDay ? .distantFuture : (summary.start ?? .distantFuture)
            found.append((start, WatchedPlace(rowID: entry.row.id, coordinate: point, radius: matchRadius(summary.kind))))
        }
        return found.sorted { ($0.start, $0.place.rowID) < ($1.start, $1.place.rowID) }.prefix(limit).map(\.place)
    }
}
