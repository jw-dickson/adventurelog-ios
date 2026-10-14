// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Works out a revised rest-of-today on the phone, with no network.
///
/// Booked items stay put. Everything else is laid out again in time order from when you're free,
/// with travel between stops (Today's straight-line estimate). Only lateness the delay causes
/// counts: whatever the plan was already tight on (by this estimate) is its own business. Then,
/// until the day works:
///
/// 1. A place that would end after sunset, when it was planned for daylight, or anything that would
///    end after 23:00, or make you late for a booked item, makes room by shortening places before
///    it (never below half their length or 15 minutes), the most spare first.
/// 2. If that isn't enough, a place goes to the next trip day's morning (08:00, if it fits before
///    that day's first item), or is left out today. For a booked item the longest place before it
///    goes; for a place pushed too late, that place itself goes. Shortening starts again from the
///    planned lengths after each removal.
/// 3. What can't be fixed (a journey with nothing before it to give way, say) is left as it is, and
///    the proposal says which booked item you'd still be late for.
public enum ReplanPlanner {
    /// Below this you're on time and nothing changes.
    public static let onTimeMinutes = 5
    static let shortestPlaceMinutes = 15

    public static func propose(_ situation: Replan.Situation, locale: Locale = .autoupdatingCurrent) -> Replan.Proposal {
        let delay = max(0, situation.delayMinutes)
        let stops = Replan.inTimeOrder(situation.stops)
        let keeps = stops.filter(\.isBooked).map { Replan.Change.keep(rowID: $0.rowID) }
        guard delay >= onTimeMinutes, !stops.isEmpty else {
            return Replan.Proposal(behindMinutes: delay < onTimeMinutes ? 0 : delay,
                                   summary: "Nothing needs to change.", changes: keeps)
        }

        var slots = stops.map(Slot.init)
        // How far over each stop already was with no delay at all.
        var planned = slots
        let baseline = Dictionary(layOut(&planned, situation, delay: 0, fromNow: false).map { ($0.index, $0.minutes) },
                                  uniquingKeysWith: max)
        var morning = Morning(situation.nextDay)
        var accepted: Set<Int> = []

        // Each pass shortens, removes or gives up on something, and a removal undoes earlier
        // shortening, so this ends well inside the cap.
        for _ in 0..<((slots.count + 1) * (slots.count + 2) * 4) {
            let violations = layOut(&slots, situation, delay: delay, fromNow: true, baseline: baseline)
            guard let violation = violations.first(where: { !accepted.contains($0.index) }) else { break }
            let candidates = helpful(slots, before: violation)
            if shorten(&slots, candidates: candidates, by: violation.minutes) { continue }
            let leaving: Int?
            if violation.isBooked {
                leaving = candidates.max { slots[$0].minutes != slots[$1].minutes ? slots[$0].minutes < slots[$1].minutes : $0 > $1 }
            } else {
                leaving = slots[violation.index].stop.isPlace ? violation.index : candidates.last
            }
            guard let leaving else {
                accepted.insert(violation.index)
                continue
            }
            slots[leaving].removal = morning.place(slots[leaving].stop).map { Removal.moved(date: $0.date, start: $0.start, end: $0.end) } ?? .skipped
            // With that out of the way, earlier shortening may not be needed any more.
            for index in slots.indices { slots[index].minutes = slots[index].stop.minutes }
        }
        // The times after the last change, and the first booked item still out of reach.
        let left = layOut(&slots, situation, delay: delay, fromNow: true, baseline: baseline)
        let unresolved = left.first(where: \.isBooked)

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
        /// Over by this much, beyond what the plan already was.
        let minutes: Int
        let isBooked: Bool
        /// When you'd get there (booked items).
        let arrive: Date
    }

    /// The next day's free morning, filled one moved place at a time.
    struct Morning {
        let day: Replan.NextDay?
        var free: Date?

        init(_ day: Replan.NextDay?) {
            self.day = day
            self.free = day.map { Replan.clock(Replan.morningHour, on: $0.date, in: $0.zone) }
        }

        mutating func place(_ stop: Replan.Stop) -> (date: CalendarDate, start: Date, end: Date)? {
            guard let day, let start = free, stop.isPlace else { return nil }
            let end = start.addingTimeInterval(Double(stop.minutes * 60))
            if let first = day.firstStart, end.addingTimeInterval(15 * 60) > first { return nil }
            free = end.addingTimeInterval(15 * 60)
            return (day.date, start, end)
        }
    }

    /// Lays every active stop out from when you're free; returns every stop that doesn't fit, in order.
    /// - Parameters:
    ///   - fromNow: nothing starts before now (off for the plan's own baseline).
    ///   - baseline: how far over each stop already was; only more than that counts.
    static func layOut(_ slots: inout [Slot], _ situation: Replan.Situation, delay: Int, fromNow: Bool,
                       baseline: [Int: Int] = [:]) -> [Violation] {
        guard let first = slots.first?.stop else { return [] }
        var violations: [Violation] = []
        var at = situation.position ?? first.coordinate
        var free = first.start.addingTimeInterval(Double(delay * 60 - Replan.travelMinutes(from: at, to: first.coordinate, departure: first.start.addingTimeInterval(Double(delay * 60)), routes: situation.routes) * 60))
        if fromNow { free = max(free, situation.now) }
        for index in slots.indices where slots[index].isActive {
            let stop = slots[index].stop
            let arrive = free.addingTimeInterval(Double(Replan.travelMinutes(from: at, to: stop.coordinate, departure: free, routes: situation.routes) * 60))
            if stop.isFlexible {
                let start = max(stop.start, arrive)
                let end = start.addingTimeInterval(Double(slots[index].minutes * 60))
                slots[index].start = start
                slots[index].end = end
                let over = minutes(from: latestEnd(for: stop, situation), to: end) - (baseline[index] ?? 0)
                if over > 0 { violations.append(Violation(index: index, minutes: over, isBooked: false, arrive: arrive)) }
                free = end
                at = stop.exit ?? at
            } else {
                let needed = stop.start.addingTimeInterval(-Double(Replan.buffer(before: stop) * 60))
                let over = minutes(from: needed, to: arrive) - (baseline[index] ?? 0)
                if over > 0 { violations.append(Violation(index: index, minutes: over, isBooked: true, arrive: arrive)) }
                // A booked tour or hire with other rows inside it: you're there from its start, and
                // the rows inside follow; otherwise you're free when it ends.
                let nextStart = slots[(index + 1)...].first(where: \.isActive)?.stop.start
                if let nextStart, nextStart < stop.end {
                    free = max(arrive, stop.start)
                    at = stop.coordinate ?? at
                } else {
                    free = stop.end
                    at = stop.exit ?? at
                }
            }
        }
        return violations
    }

    /// 23:00 that day in the stop's zone, or sunset for a place planned to be over before dark.
    static func latestEnd(for stop: Replan.Stop, _ situation: Replan.Situation) -> Date {
        var latest = dayEnd(for: stop, situation)
        if stop.isPlace, let place = stop.coordinate ?? situation.position,
           let sunset = SunTimes.sunset(on: situation.date, latitude: place.latitude, longitude: place.longitude, zone: stop.zone),
           stop.end <= sunset.addingTimeInterval(5 * 60) {
            latest = min(latest, sunset)
        }
        return latest
    }

    static func dayEnd(for stop: Replan.Stop, _ situation: Replan.Situation) -> Date {
        Replan.clock(Replan.latestEndHour, on: situation.date, in: stop.zone)
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

    /// Whole minutes from `a` to `b`, rounded up; negative when `b` is earlier.
    static func minutes(from a: Date, to b: Date) -> Int {
        Int((b.timeIntervalSince(a) / 60).rounded(.up))
    }

    // MARK: The proposal

    static func proposal(slots: [Slot], keeps: [Replan.Change], delay: Int, unresolved: Violation?,
                         situation: Replan.Situation, locale: Locale) -> Replan.Proposal {
        var changes = keeps
        var moved: [String] = []
        var skipped: [String] = []
        var later: [String] = []
        var beforeSunset: String?
        for slot in slots where slot.stop.isFlexible {
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
                if slot.start > slot.stop.start { later.append(slot.stop.title) }
                // The last daylight place of the day is the one to name.
                if latestEnd(for: slot.stop, situation) < dayEnd(for: slot.stop, situation) { beforeSunset = slot.stop.title }
            }
        }

        let kept = slots.indices.filter { slots[$0].stop.isBooked && $0 != unresolved?.index }.map { slots[$0].stop.title }
        var sentences: [String] = []
        switch (kept.isEmpty, beforeSunset) {
        case (false, let sunset?): sentences.append("This keeps \(list(kept)), and gets you to \(sunset) before sunset.")
        case (false, nil): sentences.append("This keeps \(list(kept)).")
        case (true, let sunset?): sentences.append("This gets you to \(sunset) before sunset.")
        case (true, nil):
            // Nothing booked or planned for daylight to name: say what moves.
            if !later.isEmpty, moved.isEmpty, skipped.isEmpty {
                sentences.append(later.count == 1 ? "\(later[0]) starts later." : "\(list(later)) start later.")
            }
        }
        if !moved.isEmpty {
            let when = situation.nextDay.map { day in
                day.date == situation.date.adding(days: 1) ? "to tomorrow" : "to " + dayName(day.date, locale: locale)
            } ?? "later"
            sentences.append("\(list(moved)) \(moved.count == 1 ? "moves" : "move") \(when).")
        }
        if !skipped.isEmpty {
            sentences.append("\(list(skipped)) \(skipped.count == 1 ? "is" : "are") left out today.")
        }
        var proposal = Replan.Proposal(behindMinutes: delay, summary: "", changes: changes)
        if let unresolved {
            let stop = slots[unresolved.index].stop
            let late = minutes(from: stop.start, to: unresolved.arrive)
            proposal.lateFor = stop.title
            proposal.lateRowID = stop.rowID
            proposal.lateMinutes = max(0, late)
            if late > 0 {
                sentences.append("Even so, you'd reach \(stop.title) about \(ItemSummary.durationText(minutes: late)) late.")
            } else {
                let spare = -late
                sentences.append(spare == 0 ? "Even so, you'd reach \(stop.title) just in time."
                                            : "Even so, you'd reach \(stop.title) with only \(ItemSummary.durationText(minutes: spare)) to spare.")
            }
        }
        if changes.count == keeps.count && unresolved == nil {
            sentences = ["There's enough slack in the plan: nothing needs to change."]
        }
        proposal.summary = sentences.joined(separator: " ")
        return proposal
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
