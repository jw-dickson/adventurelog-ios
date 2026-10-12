// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// The rules every proposal must keep before it's shown, whoever made it. A proposal from the
/// companion (Claude) is only data until it passes.
public enum ReplanCheck {
    public enum Problem: Sendable, Hashable {
        case tooManyChanges
        /// The row isn't one of today's remaining stops.
        case unknownRow(String)
        /// More than one change for the same row.
        case duplicate(String)
        /// A booked item would move, change or be left out.
        case changesBooked(String)
        case endNotAfterStart(String)
        case startsInThePast(String)
        /// New times that aren't on today (a move is for other days).
        case notToday(String)
        /// A move or a new note on a date that isn't a later day of the trip.
        case notALaterTripDay(String)
        case blankTitle
        /// Two things at once afterwards; the titles.
        case overlap(String, String)

        public var message: String {
            switch self {
            case .tooManyChanges: return "It changes too many things at once."
            case .unknownRow(let title): return "It mentions something that isn't left today (\(title))."
            case .duplicate(let title): return "It changes \(title) twice."
            case .changesBooked(let title): return "It moves \(title), which is booked."
            case .endNotAfterStart(let title): return "It gives \(title) an end before its start."
            case .startsInThePast(let title): return "It starts \(title) in the past."
            case .notToday(let title): return "It moves \(title) off today without saying which day."
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
                if start < lateEnough { problems.append(.startsInThePast(stop.title)) }
                if TripTime.localDate(of: start, in: stop.zone) != situation.date { problems.append(.notToday(stop.title)) }
                timeline[rowID] = (start, end)
                changed.insert(rowID)
            case .move(_, let date, let start, let end, _):
                if stop.isBooked { problems.append(.changesBooked(stop.title)); continue }
                if end <= start { problems.append(.endNotAfterStart(stop.title)) }
                if date <= situation.date || !tripDays.contains(date) || TripTime.localDate(of: start, in: stop.zone) != date {
                    problems.append(.notALaterTripDay(stop.title))
                }
                timeline[rowID] = nil
            case .skip:
                if stop.isBooked { problems.append(.changesBooked(stop.title)); continue }
                timeline[rowID] = nil
            }
        }

        // Overlaps that the proposal causes (the plan's own overlaps aren't its fault).
        let ordered = situation.stops.compactMap { stop in timeline[stop.rowID].map { (stop, $0.0, $0.1) } }
            .sorted { $0.1 < $1.1 }
        var latest: (stop: Replan.Stop, end: Date)?
        for (stop, start, end) in ordered {
            if let previous = latest, start < previous.end.addingTimeInterval(-60),
               changed.contains(previous.stop.rowID) || changed.contains(stop.rowID) {
                problems.append(.overlap(previous.stop.title, stop.title))
            }
            if latest == nil || end > latest!.end { latest = (stop, end) }
        }
        return problems
    }
}
