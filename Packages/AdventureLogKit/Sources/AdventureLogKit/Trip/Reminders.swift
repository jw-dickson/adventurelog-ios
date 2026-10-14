// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Which reminders to give, set on the phone.
public struct ReminderSettings: Codable, Sendable, Hashable {
    /// "Leave by 18:15 for Sunset cruise", counted from the previous stop.
    public var leaveBy = true
    /// "Sunset cruise starts at 18:30", some minutes before.
    public var headsUp = true
    /// Heads-up lead for places, stays and ground travel.
    public var headsUpMinutes = 15
    /// Heads-up lead for booked items (they can't move).
    public var bookedHeadsUpMinutes = 60
    /// Heads-up lead for flights.
    public var flightHeadsUpMinutes = 180

    public init() {}
}

/// One local notification to schedule.
public struct Reminder: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case leaveBy, headsUp
    }

    /// Stable across recalculations, so rescheduling replaces rather than duplicates.
    public let id: String
    public let kind: Kind
    public let fireDate: Date
    public let title: String
    public let body: String
    public let tripID: String
    public let itemID: String
    public let day: CalendarDate?
}

/// Works out the reminders for a trip from its plan and the clock.
///
/// A pure function, so a whole day can be replayed in tests. Times are UTC instants, so a
/// reminder fires at the right moment whatever zone the phone is in; the text shows each time in
/// its item's own zone.
public enum ReminderPlanner {
    /// How far ahead to schedule. The app recalculates whenever the trip changes, when it comes
    /// to the front and on background refresh, so this only has to cover the gaps between those.
    public static let window: TimeInterval = 48 * 3600
    /// iOS keeps at most 64 pending notifications per app; leave room.
    public static let limit = 60
    /// No leave-by when the previous stop is this close: you're already there.
    static let sameplaceKilometres = 0.3
    /// A heads-up this close to the leave-by adds nothing.
    static let mergeWindow: TimeInterval = 10 * 60

    public static func reminders(for plan: TripPlan, now: Date, skipped: Set<String> = [],
                                 settings: ReminderSettings = ReminderSettings(), routes: RouteTimes = RouteTimes(),
                                 locale: Locale = .autoupdatingCurrent) -> [Reminder] {
        var reminders: [Reminder] = []
        let end = now.addingTimeInterval(window)
        let tripID = plan.collection.id

        for day in plan.days {
            let summaries = day.entries.map { $0.summary(in: plan) }
            for (index, entry) in day.entries.enumerated() {
                let summary = summaries[index]
                guard !skipped.contains(entry.row.id), TodayPlan.isPlace(summary.kind),
                      let start = summary.start, !summary.isAllDay, start > now,
                      start.timeIntervalSince(now) <= window + 4 * 3600
                else { continue }
                let time = TripTime.shortTime(start, in: summary.startZone, locale: locale)
                let isFlight: Bool = {
                    if case .transportation(let leg) = entry.item { return leg.type == .plane }
                    return false
                }()

                var leave: Reminder?
                if settings.leaveBy, let destination = summary.coordinate,
                   let origin = origin(before: index, in: day.entries, summaries: summaries, skipped: skipped),
                   LeaveBy.kilometres(from: origin, to: destination) > sameplaceKilometres {
                    let travel = routes.travel(from: origin, to: destination, arriving: start)
                    let buffer = isFlight ? 90 : summary.isBooked ? 10 : 5
                    let fire = LeaveBy.time(start: start, travelMinutes: travel.minutes, bufferMinutes: buffer)
                    if fire > now, fire <= end {
                        let leaveText = TripTime.shortTime(fire, in: summary.startZone, locale: locale)
                        // A routed time says how long the drive is; the estimate says "about".
                        var body = travel.isRouted
                            ? "\(travel.driveText) · "
                            : "About \(ItemSummary.durationText(minutes: travel.minutes)) away · "
                        body += isFlight ? "departs \(time), allowing time at the airport" : "starts \(time)"
                        leave = Reminder(id: id(.leaveBy, entry, fire), kind: .leaveBy, fireDate: fire,
                                         title: "Leave by \(leaveText) for \(summary.title)", body: body,
                                         tripID: tripID, itemID: entry.item.id, day: day.date)
                    }
                }
                if let leave { reminders.append(leave) }

                if settings.headsUp {
                    let minutes = isFlight ? settings.flightHeadsUpMinutes
                        : summary.isBooked ? settings.bookedHeadsUpMinutes : settings.headsUpMinutes
                    let fire = start.addingTimeInterval(-Double(minutes * 60))
                    let duplicate = leave.map { abs($0.fireDate.timeIntervalSince(fire)) < mergeWindow } ?? false
                    if fire > now, fire <= end, !duplicate {
                        var body = (isFlight ? "Departs" : "Starts") + " in \(ItemSummary.durationText(minutes: minutes))"
                        if let reference = summary.reference { body += " · \(reference)" }
                        reminders.append(Reminder(id: id(.headsUp, entry, fire), kind: .headsUp, fireDate: fire,
                                                  title: "\(summary.title) at \(time)", body: body,
                                                  tripID: tripID, itemID: entry.item.id, day: day.date))
                    }
                }
            }
        }
        return Array(reminders.sorted { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }.prefix(limit))
    }

    /// The last place before `index` that day with a known position (a leg counts from where it
    /// ends), skipping skipped rows.
    static func origin(before index: Int, in entries: [TripPlan.Entry], summaries: [ItemSummary],
                       skipped: Set<String>) -> ItemSummary.Coordinate? {
        for i in stride(from: index - 1, through: 0, by: -1) where !skipped.contains(entries[i].row.id) {
            let summary = summaries[i]
            if summary.kind == .transportation, let point = summary.destination ?? summary.coordinate { return point }
            if let point = summary.coordinate { return point }
        }
        return nil
    }

    /// Includes the fire time, so a reminder whose time moves replaces the old one.
    static func id(_ kind: Reminder.Kind, _ entry: TripPlan.Entry, _ fire: Date) -> String {
        "\(prefix)\(kind.rawValue).\(entry.row.id).\(Int(fire.timeIntervalSince1970))"
    }

    /// Every reminder id starts with this, so the app can tell its own pending notifications apart.
    public static let prefix = "al.reminder."
}
