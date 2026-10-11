// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Calendar and time boundaries")
struct TimeBoundaryTests {
    @Test(arguments: ["2026-02-29", "2100-02-29", "2028-04-31", "2028-00-01", "2028-01-00", "2028-13-01", "2028-01", "not-a-date"])
    func invalidCalendarDatesAreRejected(_ value: String) {
        #expect(CalendarDate(value) == nil)
        #expect(throws: DecodingError.self) {
            try ALCoding.decoder().decode(CalendarDate.self, from: Data("\"\(value)\"".utf8))
        }
    }

    @Test func leapDayArithmeticAndInclusiveRanges() throws {
        let first = try #require(CalendarDate("2028-02-28"))
        let leap = try #require(CalendarDate("2028-02-29"))
        let last = try #require(CalendarDate("2028-03-01"))
        #expect(first.through(last) == [first, leap, last])
        #expect(first.through(first) == [first])
        #expect(last.through(first).isEmpty)
        #expect(last.adding(days: -1) == leap)
        #expect(first.days(since: last) == -2)
        #expect(CalendarDate("2000-02-29") != nil)
        let encoded = try ALCoding.encoder().encode(leap)
        #expect(String(decoding: encoded, as: UTF8.self) == #""2028-02-29""#)
    }

    @Test func calendarDateKeepsTheWrittenDateAcrossOffsets() throws {
        let day = try ALCoding.decoder().decode(CalendarDate.self, from: Data(#""2027-03-07T00:30:00+13:00""#.utf8))
        #expect(day == CalendarDate("2027-03-07"))
    }

    @Test(arguments: [
        ("2026-12-31T23:30:00-02:30", "2027-01-01T02:00:00Z"),
        ("2026-01-01T00:15:00+0530", "2025-12-31T18:45:00Z"),
        ("2027-03-07 08:30:00+02", "2027-03-07T06:30:00Z"),
        ("2027-03-07T08:30:00.999999Z", "2027-03-07T08:30:00Z"),
    ])
    func offsetsAndFractionalSecondsFormatAsUTC(_ input: String, _ expected: String) throws {
        let date = try #require(ISO8601.parse(input))
        #expect(ISO8601.format(date) == expected)
    }

    @Test(arguments: ["2027-03-07T10:00:00.Z", "2027-03-07T10:00:00Zjunk", "2027-03-07T10:00:00+0", "2027-03-07T10:00:00+01:3", "2027-03-07T10:60:00Z", "2027-03-07T10:00:62Z"])
    func malformedDatetimeSuffixesAreRejected(_ input: String) {
        #expect(ISO8601.parse(input) == nil)
    }

    @Test func calendarDayArithmeticSurvivesDaylightSaving() throws {
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let spring = try #require(CalendarDate("2026-03-08"))
        let autumn = try #require(CalendarDate("2026-11-01"))
        #expect(spring.adding(days: 1).startOfDay(in: zone).timeIntervalSince(spring.startOfDay(in: zone)) == 23 * 3600)
        #expect(autumn.adding(days: 1).startOfDay(in: zone).timeIntervalSince(autumn.startOfDay(in: zone)) == 25 * 3600)
        #expect(spring.adding(days: 1).days(since: spring) == 1)
        #expect(autumn.adding(days: 1).days(since: autumn) == 1)
    }

    @Test func allDayBoundariesAndMissingEndpoints() throws {
        let midnight = try #require(ISO8601.parse("2027-03-07T00:00:00Z"))
        #expect(!TripTime.isAllDay(start: nil, end: midnight))
        #expect(TripTime.isAllDay(start: midnight, end: nil))
        #expect(TripTime.isAllDay(start: midnight, end: midnight.addingTimeInterval(86_400)))
        #expect(TripTime.isAllDay(start: midnight.addingTimeInterval(0.0005), end: nil))
        #expect(!TripTime.isAllDay(start: midnight.addingTimeInterval(0.002), end: nil))
        #expect(!TripTime.isAllDay(start: midnight, end: midnight.addingTimeInterval(1)))
        let zone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(TripTime.localDate(of: midnight, in: zone) == CalendarDate("2027-03-06"))
        #expect(TripTime.localDate(of: midnight, in: zone, allDay: true) == CalendarDate("2027-03-07"))
    }

    @Test func missingAndInvalidZonesUseTheExplicitFallback() throws {
        let fallback = try #require(TimeZone(identifier: "Australia/Hobart"))
        #expect(TripTime.zone(nil, fallback: fallback) == fallback)
        #expect(TripTime.zone("Mars/Olympus", fallback: fallback) == fallback)
        #expect(TripTime.zone("America/Los_Angeles", fallback: fallback).identifier == "America/Los_Angeles")
    }

    @Test(arguments: [(0, nil as String?), (1, "+1 day"), (-1, "−1 day"), (3, "+3 days"), (-3, "−3 days")])
    func offsetLabelsHandleBothDirections(_ offset: Int, _ expected: String?) {
        #expect(TripTime.offsetLabel(offset) == expected)
    }
}
