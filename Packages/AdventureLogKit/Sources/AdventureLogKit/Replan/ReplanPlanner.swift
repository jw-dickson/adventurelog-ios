// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Works out a revised rest-of-today on the phone, with no network.
///
/// Booked items stay put. Everything else is laid out again in the day's order from when you're
/// free, with travel between stops (Today's straight-line estimate). Then, until the day works:
///
/// 1. A place that would end after sunset, when it was planned for daylight, or after 23:00, or
///    that would make you late for a booked item, makes room by shortening places before it
///    (never below half their length or 15 minutes), the longest first.
/// 2. If that isn't enough, a place goes to the next trip day's morning (08:00, if it fits before
///    that day's first item), or is left out today. For a booked item the longest place before it
///    goes; for a place pushed too late, that place itself goes. Shortening starts again from the
///    planned lengths after each removal.
/// 3. If nothing is left to change, the proposal says which booked item you'd still be late for.
public enum ReplanPlanner {
    /// Below this you're on time and nothing changes.
    public static let onTimeMinutes = 5
    static let shortestPlaceMinutes = 15

    public static func propose(_ situation: Replan.Situation, locale: Locale = .autoupdatingCurrent) -> Replan.Proposal {
        let delay = max(0, situation.delayMinutes)
        let keeps = situation.stops.filter(\.isBooked).map { Replan.Change.keep(rowID: $0.rowID) }
        guard delay >= onTimeMinutes, !situation.stops.isEmpty else {
            return Replan.Proposal(behindMinutes: delay < onTimeMinutes ? 0 : delay,
                                   summary: "Nothing needs to change.", changes: keeps)
        }

        var slots = situation.stops.map(Slot.init)
        var morning = Morning(situation.nextDay)
        var unresolved: (index: Int, minutes: Int)?

        // Each pass shortens or removes something, and a removal undoes earlier shortening, so this
        // ends well inside the cap.
        for _ in 0..<((slots.count + 1) * (slots.count + 2) * 4) {
            guard let violation = layOut(&slots, situation) else { break }
            let candidates = helpful(slots, before: violation)
            if shorten(&slots, candidates: candidates, by: violation.minutes) { continue }
            let leaving: Int?
            if violation.isBooked {
                leaving = candidates.max { slots[$0].minutes != slots[$1].minutes ? slots[$0].minutes < slots[$1].minutes : $0 > $1 }
            } else {
                leaving = slots[violation.index].stop.isPlace ? violation.index : candidates.last
            }
            guard let leaving else {
                unresolved = violation.isBooked ? (violation.index, violation.minutes) : nil
                break
            }
            slots[leaving].removal = morning.place(slots[leaving].stop).map { Removal.moved(date: $0.date, start: $0.start, end: $0.end) } ?? .skipped
            // With that out of the way, earlier shortening may not be needed any more.
            for index in slots.indices { slots[index].minutes = slots[index].stop.minutes }
        }
        _ = layOut(&slots, situation) // the times after the last change

        return proposal(slots: slots, keeps: keeps, delay: delay, unresolved: unresolved, situation: situation, locale: locale)
    }

    // MARK: Working state

    struct Slot {
        let stop: Replan.Stop
        /// Current length; less than planned once shortened.
        var minutes: Int
        var start: Date
        var end: Date
        var removal: Removal?

        init(_ stop: Replan.Stop) {
            self.stop = stop
            self.minutes = stop.minutes
            self.start = stop.start
            self.end = stop.end
        }

        var isActive: Bool { removal == nil }
        var shortest: Int { min(stop.minutes, max(ReplanPlanner.shortestPlaceMinutes, Int((Double(stop.minutes) / 2 / 5).rounded(.up)) * 5)) }
    }

    enum Removal {
        case moved(date: CalendarDate, start: Date, end: Date)
        case skipped
    }

    struct Violation {
        let index: Int
        let minutes: Int
        let isBooked: Bool
    }

    /// The next day's free morning, filled one moved place at a time.
    struct Morning {
        let day: Replan.NextDay?
        var free: Date?

        init(_ day: Replan.NextDay?) {
            self.day = day
            self.free = day.map { $0.date.startOfDay(in: $0.zone).addingTimeInterval(Double(Replan.morningHour * 3600)) }
        }

        mutating func place(_ stop: Replan.Stop) -> (date: CalendarDate, start: Date, end: Date)? {
            guard let day, let start = free else { return nil }
            let end = start.addingTimeInterval(Double(stop.minutes * 60))
            if let first = day.firstStart, end.addingTimeInterval(15 * 60) > first { return nil }
            free = end.addingTimeInterval(15 * 60)
            return (day.date, start, end)
        }
    }

    /// Lays every active stop out from when you're free; returns the first one that doesn't fit.
    static func layOut(_ slots: inout [Slot], _ situation: Replan.Situation) -> Violation? {
        guard let first = slots.first?.stop else { return nil }
        var violation: Violation?
        let delay = Double(max(0, situation.delayMinutes) * 60)
        var at = situation.position ?? first.coordinate
        var free = max(situation.now,
                       first.start.addingTimeInterval(delay - Double(Replan.travelMinutes(from: at, to: first.coordinate) * 60)))
        for index in slots.indices where slots[index].isActive {
            let stop = slots[index].stop
            let arrive = free.addingTimeInterval(Double(Replan.travelMinutes(from: at, to: stop.coordinate) * 60))
            if stop.isFlexible {
                let start = max(stop.start, arrive)
                let end = start.addingTimeInterval(Double(slots[index].minutes * 60))
                slots[index].start = start
                slots[index].end = end
                let latest = latestEnd(for: stop, situation)
                if end > latest, violation == nil {
                    violation = Violation(index: index, minutes: minutes(from: latest, to: end), isBooked: false)
                }
            } else {
                let needed = stop.start.addingTimeInterval(-Double(Replan.buffer(before: stop) * 60))
                if arrive > needed.addingTimeInterval(60), violation == nil {
                    violation = Violation(index: index, minutes: minutes(from: needed, to: arrive), isBooked: true)
                }
            }
            free = slots[index].end
            at = stop.exit ?? at
        }
        return violation
    }

    /// 23:00 that day, or sunset for something planned to be over before dark.
    static func latestEnd(for stop: Replan.Stop, _ situation: Replan.Situation) -> Date {
        var latest = situation.dayEnd
        let place = stop.exit ?? situation.position
        if let place, let sunset = SunTimes.sunset(on: situation.date, latitude: place.latitude, longitude: place.longitude, zone: stop.zone),
           stop.end <= sunset.addingTimeInterval(5 * 60) {
            latest = min(latest, sunset)
        }
        return latest
    }

    /// Places whose shortening or removal would reach the violation: active, flexible, at or before
    /// it, with no wait in between (every flexible stop after it already pushed later, and no booked
    /// stop in the way).
    static func helpful(_ slots: [Slot], before violation: Violation) -> [Int] {
        let last = violation.isBooked ? violation.index - 1 : violation.index
        guard last >= 0 else { return [] }
        var result: [Int] = []
        var chainIntact = true
        for index in stride(from: last, through: 0, by: -1) where slots[index].isActive {
            let slot = slots[index]
            if slot.stop.isFlexible && slot.stop.isPlace && chainIntact { result.append(index) }
            // Anything earlier only helps through this stop if this one was pushed later than planned.
            if !slot.stop.isFlexible || slot.start <= slot.stop.start { chainIntact = false }
            if !chainIntact { break }
        }
        return result.reversed()
    }

    /// Takes `minutes` (rounded up to 5) out of the candidates, the most spare first (earlier on a
    /// tie). False if none can give any.
    static func shorten(_ slots: inout [Slot], candidates: [Int], by minutes: Int) -> Bool {
        var needed = Int((Double(minutes) / 5).rounded(.up)) * 5
        let spare = Dictionary(uniqueKeysWithValues: candidates.map { ($0, slots[$0].minutes - slots[$0].shortest) })
        var changed = false
        for index in candidates.sorted(by: { spare[$0]! != spare[$1]! ? spare[$0]! > spare[$1]! : $0 < $1 }) {
            guard needed > 0, let available = spare[index], available > 0 else { continue }
            let cut = min(available, needed)
            slots[index].minutes -= cut
            needed -= cut
            changed = true
        }
        return changed
    }

    static func minutes(from a: Date, to b: Date) -> Int {
        max(1, Int((b.timeIntervalSince(a) / 60).rounded(.up)))
    }

    // MARK: The proposal

    static func proposal(slots: [Slot], keeps: [Replan.Change], delay: Int, unresolved: (index: Int, minutes: Int)?,
                         situation: Replan.Situation, locale: Locale) -> Replan.Proposal {
        var changes = keeps
        var moved: [String] = []
        var skipped: [String] = []
        var beforeSunset: String?
        for slot in slots where !slot.stop.isBooked && slot.stop.isFlexible {
            switch slot.removal {
            case .moved(let date, let start, let end):
                let reason = situation.nextDay?.firstTitle.map { "Before \($0)" }
                changes.append(.move(rowID: slot.stop.rowID, date: date, start: start, end: end, reason: reason))
                moved.append(slot.stop.title)
            case .skipped:
                changes.append(.skip(rowID: slot.stop.rowID, reason: "No time left today"))
                skipped.append(slot.stop.title)
            case nil:
                guard slot.start != slot.stop.start || slot.end != slot.stop.end else { continue }
                changes.append(.retime(rowID: slot.stop.rowID, start: slot.start, end: slot.end, reason: nil))
                // The last daylight place of the day is the one to name.
                if latestEnd(for: slot.stop, situation) < situation.dayEnd { beforeSunset = slot.stop.title }
            }
        }

        let kept = situation.stops.indices
            .filter { situation.stops[$0].isBooked && $0 != unresolved?.index }
            .map { situation.stops[$0].title }
        var sentences: [String] = []
        switch (kept.isEmpty, beforeSunset) {
        case (false, let sunset?): sentences.append("This keeps \(list(kept)), and gets you to \(sunset) before sunset.")
        case (false, nil): sentences.append("This keeps \(list(kept)).")
        case (true, let sunset?): sentences.append("This gets you to \(sunset) before sunset.")
        case (true, nil): break
        }
        if !moved.isEmpty {
            let when = situation.nextDay.map { day in
                day.date == situation.date.adding(days: 1) ? "tomorrow" : "to " + dayName(day.date, locale: locale)
            } ?? "later"
            sentences.append("\(list(moved)) \(moved.count == 1 ? "moves" : "move") \(when == "tomorrow" ? "to tomorrow" : when).")
        }
        if !skipped.isEmpty {
            sentences.append("\(list(skipped)) \(skipped.count == 1 ? "is" : "are") left out today.")
        }
        var lateFor: String?
        var lateMinutes: Int?
        if let unresolved {
            let title = situation.stops[unresolved.index].title
            lateFor = title
            lateMinutes = unresolved.minutes
            sentences.append("Even so, you'd reach \(title) about \(ItemSummary.durationText(minutes: unresolved.minutes)) late.")
        }
        if changes.count == keeps.count && unresolved == nil {
            sentences = ["There's enough slack in the plan: nothing needs to change."]
        }
        return Replan.Proposal(behindMinutes: delay, summary: sentences.joined(separator: " "), changes: changes,
                               lateFor: lateFor, lateMinutes: lateMinutes)
    }

    /// "A", "A and B", "A, B and C".
    static func list(_ titles: [String]) -> String {
        switch titles.count {
        case 0: return ""
        case 1: return titles[0]
        default: return titles.dropLast().joined(separator: ", ") + " and " + titles[titles.count - 1]
        }
    }

    static func dayName(_ date: CalendarDate, locale: Locale) -> String {
        let style = Date.FormatStyle(locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: .gmt)
            .weekday(.abbreviated).day().month(.abbreviated)
        return date.startOfDay(in: .gmt).formatted(style)
    }
}
