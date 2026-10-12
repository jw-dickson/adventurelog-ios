// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// The rules every proposal must keep before it's shown, whoever made it. A proposal from the
/// companion (Claude) is only data until it passes.
public enum ReplanCheck {
    public enum Problem: Sendable, Hashable {
        case tooManyChanges
        /// Today changed so much that the proposal's day can't be checked (nothing timed left, say).
        case outOfDate
        /// The row isn't one of today's remaining stops.
        case unknownRow(String)
        /// More than one change for the same row.
        case duplicate(String)
        /// A booked item would move, change or be left out.
        case changesBooked(String)
        /// A journey would get shorter or longer, go to another day, or be left out: it joins two places.
        case changesJourney(String)
        case endNotAfterStart(String)
        case startsInThePast(String)
        /// New times that aren't on today (a move is for other days).
        case notToday(String)
        /// Something would end after 23:00.
        case endsTooLate(String)
        /// A move or a new note on a date that isn't a later day of the trip.
        case notALaterTripDay(String)
        case blankTitle
        /// Two things at once afterwards that weren't before; the titles.
        case overlap(String, String)

        public var message: String {
            switch self {
            case .tooManyChanges: return "It changes too many things at once."
            case .outOfDate: return "Today has changed since this plan was made."
            case .unknownRow(let title): return "It mentions something that isn't left today (\(title))."
            case .duplicate(let title): return "It changes \(title) twice."
            case .changesBooked(let title): return "It moves \(title), which is booked."
            case .changesJourney(let title): return "It changes how \(title) goes; a journey only moves in time."
            case .endNotAfterStart(let title): return "It gives \(title) an end before its start."
            case .startsInThePast(let title): return "It starts \(title) in the past."
            case .notToday(let title): return "It moves \(title) off today without saying which day."
            case .endsTooLate(let title): return "It runs \(title) past 23:00."
            case .notALaterTripDay(let title): return "It puts \(title) on a day that isn't a later day of the trip."
            case .blankTitle: return "It adds a note without a title."
            case .overlap(let a, let b): return "It puts \(a) and \(b) at the same time."
            }
        }
    }

    public static let maximumChanges = 40

    /// Everything wrong with `proposal` for `situation`; empty when it can be shown.
    /// - Parameter tripDays: the trip's days, for moves and new notes.
    public static func problems(_ proposal: Replan.Proposal, situation: Replan.Situation, tripDays: Set<CalendarDate>) -> [Problem] {
        guard proposal.changes.count <= maximumChanges else { return [.tooManyChanges] }
        let stops = Dictionary(situation.stops.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
        var problems: [Problem] = []
        var seen: Set<String> = []
        // Today afterwards: row → (start, end); moved and skipped rows drop out.
        var timeline = Dictionary(situation.stops.map { ($0.rowID, ($0.start, $0.end)) }, uniquingKeysWith: { first, _ in first })
        var changed: Set<String> = []
        let lateEnough = situation.now.addingTimeInterval(-10 * 60)

        for change in proposal.changes {
            if case .add(let title, _, let date, _) = change {
                if title.nilIfBlank == nil { problems.append(.blankTitle) }
                if !tripDays.contains(date) || date < situation.date { problems.append(.notALaterTripDay(title)) }
                continue
            }
            guard let rowID = change.rowID else { continue }
            guard let stop = stops[rowID] else {
                problems.append(.unknownRow(rowID))
                continue
            }
            guard seen.insert(rowID).inserted else {
                problems.append(.duplicate(stop.title))
                continue
            }
            switch change {
            case .keep, .add:
                break
            case .retime(_, let start, let end, _):
                if stop.isBooked { problems.append(.changesBooked(stop.title)); continue }
                if end <= start { problems.append(.endNotAfterStart(stop.title)); continue }
                if !stop.isPlace, abs(end.timeIntervalSince(start) - stop.end.timeIntervalSince(stop.start)) > 60 {
                    problems.append(.changesJourney(stop.title))
                }
                if start < lateEnough { problems.append(.startsInThePast(stop.title)) }
                if TripTime.localDate(of: start, in: stop.zone) != situation.date { problems.append(.notToday(stop.title)) }
                let dayEnd = Replan.clock(Replan.latestEndHour, on: situation.date, in: stop.zone)
                if end > dayEnd.addingTimeInterval(60), end > stop.end { problems.append(.endsTooLate(stop.title)) }
                timeline[rowID] = (start, end)
                changed.insert(rowID)
            case .move(_, let date, let start, let end, _):
                if stop.isBooked { problems.append(.changesBooked(stop.title)); continue }
                if !stop.isPlace { problems.append(.changesJourney(stop.title)); continue }
                if end <= start { problems.append(.endNotAfterStart(stop.title)) }
                if date <= situation.date || !tripDays.contains(date) || TripTime.localDate(of: start, in: stop.zone) != date {
                    problems.append(.notALaterTripDay(stop.title))
                }
                timeline[rowID] = nil
            case .skip:
                if stop.isBooked { problems.append(.changesBooked(stop.title)); continue }
                if !stop.isPlace { problems.append(.changesJourney(stop.title)); continue }
                timeline[rowID] = nil
            }
        }

        // Overlaps the proposal causes: a changed row against anything it didn't overlap before.
        // Running into the booked item the proposal says you'll be late for is allowed, but only
        // from before it and only by the lateness it states (plus that item's buffer).
        func overlaps(_ a: (Date, Date), _ b: (Date, Date)) -> Bool {
            a.0 < b.1.addingTimeInterval(-60) && b.0 < a.1.addingTimeInterval(-60)
        }
        let ordered = situation.stops.filter { timeline[$0.rowID] != nil }
        var reported: Set<[String]> = []
        for stop in ordered where changed.contains(stop.rowID) {
            guard let mine = timeline[stop.rowID] else { continue }
            for other in ordered where other.rowID != stop.rowID {
                guard let theirs = timeline[other.rowID], overlaps(mine, theirs),
                      !overlaps((stop.start, stop.end), (other.start, other.end)) else { continue }
                let allowance = Double((proposal.lateMinutes ?? 0) + Replan.buffer(before: other)) * 60 + 60
                if other.rowID == proposal.lateRowID, other.isBooked, mine.0 < theirs.0,
                   mine.1 <= theirs.0.addingTimeInterval(allowance) {
                    continue
                }
                let pair = [stop, other].sorted { $0.start < $1.start }
                guard reported.insert(pair.map(\.rowID)).inserted else { continue }
                problems.append(.overlap(pair[0].title, pair[1].title))
            }
        }
        return problems
    }
}
