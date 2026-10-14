// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

extension Replan.Situation {
    /// A position older than this isn't where you are any more.
    public static let freshPosition: TimeInterval = 15 * 60
    /// Within this of a stop, you're at it.
    public static let atStopMetres: Double = 200

    /// Today's situation from the plan, the clock and what the phone recorded.
    ///
    /// - Rows the log shows visited, and rows skipped on this phone, are behind you. While recording,
    ///   a place whose planned end passed in the last 30 minutes with no visit is still ahead: you
    ///   may well be on the way.
    /// - With a recent position, the delay is how late you'd reach the first stop setting off now.
    ///   If you're at that stop already, you're there until its planned end (for a journey, at its
    ///   far end) and the next stop is the one that counts.
    /// - Without one, the delay is `reportedDelay` (what the person says), or none.
    /// - Returns: `nil` when today isn't a day of the trip or nothing timed is left.
    public static func current(plan: TripPlan, today: CalendarDate, now: Date, skipped: Set<String> = [],
                               log: DayLog? = nil, lastPoint: TrackPoint? = nil, reportedDelay: Int? = nil,
                               routes: RouteTimes = RouteTimes()) -> Replan.Situation? {
        guard let todayPlan = TodayPlan(plan: plan, today: today, now: now, skipped: skipped) else { return nil }
        let visited = Set((log?.rows ?? []).compactMap { row -> String? in
            switch row.status {
            case .done, .late: return row.rowID
            default: return nil
            }
        })
        var stops = stops(in: todayPlan, now: now).filter { !visited.contains($0.rowID) }
        if log != nil {
            let recentlyMissed = todayPlan.entries.filter { entry in
                entry.status == .done && entry.summary.kind == .location && !visited.contains(entry.rowID)
                    && (entry.summary.end.map { $0 >= now.addingTimeInterval(-30 * 60) } ?? false)
            }.compactMap(Replan.Stop.init)
            stops = Replan.inTimeOrder(recentlyMissed + stops)
        }
        guard !stops.isEmpty else { return nil }

        let position = lastPoint.flatMap { point -> ItemSummary.Coordinate? in
            now.timeIntervalSince(point.time) <= freshPosition ? ItemSummary.Coordinate(point.latitude, point.longitude) : nil
        }
        var delay = reportedDelay ?? 0
        var startingPoint = position
        if reportedDelay == nil, let position {
            let first = stops[0]
            if let at = first.coordinate, LeaveBy.kilometres(from: position, to: at) * 1000 <= atStopMetres,
               now >= first.start.addingTimeInterval(-15 * 60) {
                stops.removeFirst()
                let after = afterStop(first, next: stops.first, now: now, position: position, routes: routes)
                delay = after.delay
                startingPoint = after.startingPoint
            } else {
                delay = Replan.delay(now: now, position: position, target: first, routes: routes)
            }
        }
        guard !stops.isEmpty else { return nil }
        return Replan.Situation(date: today, now: now, stops: stops, delayMinutes: delay,
                                position: reportedDelay == nil ? startingPoint : nil,
                                nextDay: nextDay(after: today, in: plan), zone: plan.timeZone, routes: routes)
    }

    /// You're at `first`: how late you'll be for `next`, and where you'll set off from. You're free
    /// when `first` ends (or now, if you've stayed on), wherever it ends. A booked tour with rows
    /// inside it is different: those rows follow from its start, there.
    public static func afterStop(_ first: Replan.Stop, next: Replan.Stop?, now: Date,
                                 position: ItemSummary.Coordinate,
                                 routes: RouteTimes = RouteTimes()) -> (delay: Int, startingPoint: ItemSummary.Coordinate) {
        guard let next else { return (0, first.exit ?? position) }
        let nested = next.start < first.end
        let from = nested ? (first.coordinate ?? position) : (first.exit ?? position)
        let free = nested ? max(now, first.start) : max(now, first.end)
        let arrive = free.addingTimeInterval(Double(Replan.travelMinutes(from: from, to: next.coordinate, routes: routes) * 60))
        return (max(0, Int((arrive.timeIntervalSince(next.start) / 60).rounded(.up))), from)
    }

    /// The trip's next day after `date`, with its first timed place or journey that starts that day
    /// (a stay checked in earlier doesn't count), in that item's zone.
    public static func nextDay(after date: CalendarDate, in plan: TripPlan) -> Replan.NextDay? {
        guard let day = plan.days.first(where: { $0.date > date }) else { return nil }
        let first = day.entries.map { $0.summary(in: plan) }
            .filter { summary in
                guard let start = summary.start, !summary.isAllDay, summary.kind == .location || summary.kind == .transportation
                else { return false }
                return TripTime.localDate(of: start, in: summary.startZone) == day.date
            }
            .min { $0.start! < $1.start! }
        return Replan.NextDay(date: day.date, firstStart: first?.start, firstTitle: first?.title,
                              zone: first?.startZone ?? plan.timeZone)
    }
}

/// How a proposal's lines read on the sheet (Design/review-1, 08).
public enum ReplanText {
    public enum Mark: Sendable, Hashable { case locked, moved, shortened, left, added }

    public struct Line: Sendable, Hashable, Identifiable {
        public let id: String
        public let mark: Mark
        public let title: String
        public let detail: String
    }

    /// One line per change, in the proposal's order. Rows it can't find are left out (the checker
    /// has already refused proposals like that).
    public static func lines(_ proposal: Replan.Proposal, situation: Replan.Situation, locale: Locale = .autoupdatingCurrent) -> [Line] {
        let stops = Dictionary(situation.stops.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
        func time(_ date: Date, _ stop: Replan.Stop) -> String { TripTime.shortTime(date, in: stop.zone, locale: locale) }
        return proposal.changes.enumerated().compactMap { index, change -> Line? in
            switch change {
            case .keep(let id):
                guard let stop = stops[id] else { return nil }
                var detail = "Booked · stays at \(time(stop.start, stop))"
                if proposal.lateRowID == stop.rowID {
                    let late = proposal.lateMinutes ?? 0
                    detail += late > 0 ? " · about \(ItemSummary.durationText(minutes: late)) late" : " · little time to spare"
                }
                return Line(id: id, mark: .locked, title: stop.title, detail: detail)
            case .retime(let id, let start, let end, let reason):
                guard let stop = stops[id] else { return nil }
                let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
                var detail: String
                if minutes < stop.minutes {
                    detail = "\(stop.minutes) → \(minutes) min · \(time(start, stop))–\(time(end, stop))"
                } else {
                    detail = "\(time(stop.start, stop)) → \(time(start, stop))"
                }
                if let reason { detail += " · " + reason }
                return Line(id: id, mark: minutes < stop.minutes ? .shortened : .moved, title: stop.title, detail: detail)
            case .move(let id, let date, let start, _, let reason):
                guard let stop = stops[id] else { return nil }
                let day = date == situation.date.adding(days: 1) ? "tomorrow" : ReplanPlanner.dayName(date, locale: locale)
                var detail = "Moved to \(day) \(time(start, stop))"
                if let reason { detail += ", " + reason.prefix(1).lowercased() + reason.dropFirst() }
                return Line(id: id, mark: .moved, title: stop.title, detail: detail)
            case .skip(let id, let reason):
                guard let stop = stops[id] else { return nil }
                return Line(id: id, mark: .left, title: stop.title, detail: "Left out today" + (reason.map { " · " + $0 } ?? ""))
            case .add(let title, _, let date, let reason):
                let when = date == situation.date ? "Today" : date == situation.date.adding(days: 1) ? "Tomorrow" : ReplanPlanner.dayName(date, locale: locale)
                return Line(id: "add-\(index)", mark: .added, title: title, detail: "New · \(when)" + (reason.map { " · " + $0 } ?? ""))
            }
        }
    }
}

/// What applying a proposal does, as edits the app already knows how to send.
public enum ReplanApply {
    public enum Action: Sendable, Hashable {
        /// New start and end for the item (its visit, for a place).
        case retime(item: TripPlan.Item, start: Date, end: Date)
        /// To another day: new times, then the row at `index` on that day.
        case move(entry: TripPlan.Entry, item: TripPlan.Item, date: CalendarDate, index: Int, start: Date, end: Date)
        /// Skipped on this phone.
        case skip(rowID: String)
        case addNote(title: String, content: String, date: CalendarDate)
    }

    public static func actions(for proposal: Replan.Proposal, plan: TripPlan, today: CalendarDate) -> [Action] {
        let entries = plan.day(for: today)?.entries ?? []
        func entry(_ rowID: String) -> TripPlan.Entry? { entries.first { $0.row.id == rowID } }
        // Rows already moved onto a day, with their starts: each later move goes after the earlier ones.
        var placed: [CalendarDate: [Date]] = [:]
        return proposal.changes.compactMap { change -> Action? in
            switch change {
            case .keep:
                return nil
            case .retime(let id, let start, let end, _):
                return entry(id).map { .retime(item: $0.item, start: start, end: end) }
            case .move(let id, let date, let start, let end, _):
                guard let entry = entry(id) else { return nil }
                // Among that day's timed rows, before the first that starts later.
                let target = plan.day(for: date)?.entries ?? []
                let index = target.firstIndex { other in
                    let summary = other.summary(in: plan)
                    return summary.start.map { $0 > start && !summary.isAllDay } ?? false
                } ?? target.count
                let before = placed[date, default: []].filter { $0 <= start }.count
                placed[date, default: []].append(start)
                return .move(entry: entry, item: entry.item, date: date, index: index + before, start: start, end: end)
            case .skip(let id, _):
                return entry(id) == nil ? nil : .skip(rowID: id)
            case .add(let title, let content, let date, _):
                return .addNote(title: title, content: content, date: date)
            }
        }
    }
}
