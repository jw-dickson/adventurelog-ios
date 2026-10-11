// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Time rules for showing AdventureLog times correctly on the road.
///
/// Every datetime is a UTC instant plus a separate IANA zone name. Show each instant in its
/// own zone, never the device's; an item that ends on a later local date than the day it sits on
/// gets a "+N" marker.
public enum TripTime {
    /// Treats a UTC-midnight start as all-day when the end is absent or also at UTC midnight.
    /// A missing start returns `false`; times less than one millisecond after midnight count as midnight.
    ///
    /// When an end is present, check both ends: an 11:00 AEDT event starts at exactly 00:00Z, and the
    /// server's own calendar export mislabels it as all-day from its start alone.
    public static func isAllDay(start: Date?, end: Date?) -> Bool {
        guard let start, isUTCMidnight(start) else { return false }
        guard let end else { return true }
        return isUTCMidnight(end)
    }

    /// Returns whether the instant falls within the first millisecond of a UTC day.
    static func isUTCMidnight(_ date: Date) -> Bool {
        let c = ISO8601.utc.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
        return c.hour == 0 && c.minute == 0 && c.second == 0 && (c.nanosecond ?? 0) < 1_000_000
    }

    /// Resolves a stored zone name, falling back when it is missing or unknown.
    public static func zone(_ identifier: String?, fallback: TimeZone) -> TimeZone {
        identifier.flatMap(TimeZone.init(identifier:)) ?? fallback
    }

    /// The calendar date an instant falls on in a zone. All-day values keep their UTC date.
    public static func localDate(of date: Date, in zone: TimeZone, allDay: Bool = false) -> CalendarDate {
        CalendarDate(date, in: allDay ? ISO8601.utc.timeZone : zone)
    }

    /// Days between the itinerary day a row sits on and the local date of `date` in `zone`:
    /// 0 on the same day, 2 for a LAX→SYD flight that lands two calendar days later.
    public static func dayOffset(of date: Date, in zone: TimeZone, from day: CalendarDate) -> Int {
        localDate(of: date, in: zone).days(since: day)
    }

    /// Hour and minute of an instant in a zone, for layout and tests that must not depend on locale.
    public static func clock(of date: Date, in zone: TimeZone) -> (hour: Int, minute: Int) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0, c.minute ?? 0)
    }

    /// Localised short time ("19:10" or "7:10 PM") of an instant in its own zone.
    public static func shortTime(_ date: Date, in zone: TimeZone, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: zone)
        style.timeZone = zone
        return date.formatted(style)
    }

    /// Formats a signed day offset ("+1 day", "+2 days", "−2 days"); returns `nil` for zero.
    public static func offsetLabel(_ offset: Int) -> String? {
        switch offset {
        case 0: return nil
        case 1: return "+1 day"
        case -1: return "−1 day"
        default: return offset > 0 ? "+\(offset) days" : "−\(-offset) days"
        }
    }
}
