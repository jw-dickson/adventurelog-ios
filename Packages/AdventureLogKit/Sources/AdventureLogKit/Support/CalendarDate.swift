// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A calendar date with no time zone: AdventureLog's `YYYY-MM-DD` fields.
///
/// Trip dates, itinerary dates, note and checklist dates are plain calendar dates in the trip's
/// local sense. They must never be converted through UTC, so they are not `Date`s.
public struct CalendarDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    /// Creates a Gregorian date, returning `nil` if the components do not form a valid date.
    public init?(year: Int, month: Int, day: Int) {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = ISO8601.utc.date(from: components) else { return nil }
        let check = ISO8601.utc.dateComponents([.year, .month, .day], from: date)
        guard check.year == year, check.month == month, check.day == day else { return nil }
        self.year = year
        self.month = month
        self.day = day
    }

    /// Parses `YYYY-MM-DD`. Also accepts a full datetime string and keeps only its date part,
    /// because a few AdventureLog fields carry either shape.
    public init?(_ string: String) {
        let parts = string.prefix(10).split(separator: "-")
        guard string.count >= 10, parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let value = CalendarDate(year: year, month: month, day: day)
        else { return nil }
        self = value
    }

    /// The calendar date that `date` falls on in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.year = c.year ?? 1970
        self.month = c.month ?? 1
        self.day = c.day ?? 1
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Converts this date's midnight components in `timeZone` using the Gregorian calendar.
    /// Returns the Unix epoch if the calendar cannot construct a date.
    public func startOfDay(in timeZone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    /// Shifts by signed calendar days in UTC, returning this date if calendar arithmetic fails.
    public func adding(days: Int) -> CalendarDate {
        let date = ISO8601.utc.date(byAdding: .day, value: days, to: startOfDay(in: ISO8601.utc.timeZone))
            ?? startOfDay(in: ISO8601.utc.timeZone)
        return CalendarDate(date, in: ISO8601.utc.timeZone)
    }

    /// Whole days from `other` to `self` (positive when `self` is later).
    public func days(since other: CalendarDate) -> Int {
        let a = other.startOfDay(in: ISO8601.utc.timeZone)
        let b = startOfDay(in: ISO8601.utc.timeZone)
        return Int((b.timeIntervalSince(a) / 86_400).rounded())
    }

    /// Every date from `self` through `last`, inclusive. Empty when `last` is earlier.
    public func through(_ last: CalendarDate) -> [CalendarDate] {
        let count = last.days(since: self)
        guard count >= 0 else { return [] }
        return (0...count).map { adding(days: $0) }
    }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// Decodes a date string, accepting the same date prefix as `init(_:)`.
    /// Throws `DecodingError.dataCorrupted` for an invalid date and propagates string-decoding errors.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = CalendarDate(string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a YYYY-MM-DD date: \(string)")
        }
        self = value
    }

    /// Encodes the date as a `YYYY-MM-DD` string; propagates encoder errors.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
