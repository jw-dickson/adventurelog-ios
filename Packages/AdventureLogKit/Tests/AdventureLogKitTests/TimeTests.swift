// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

/// "HH:MM" from a clock tuple, so assertions compare strings rather than tuples.
func hm(_ clock: (hour: Int, minute: Int)) -> String {
    String(format: "%02d:%02d", clock.hour, clock.minute)
}

@Suite("Dates, time zones and the date line")
struct TimeTests {
    let hobart = TimeZone(identifier: "Australia/Hobart")!
    let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    @Test(arguments: [
        ("2027-03-06T03:10:00Z", 1_804_302_600.0),
        ("2026-10-11T01:08:01.590527Z", 1_791_680_881.590527),
        ("2027-03-08T21:30:00+11:00", 1_804_501_800.0),
        ("2027-03-08T21:30:00+1100", 1_804_501_800.0),
        ("2027-03-13T09:00:00", 1_804_928_400.0), // naive = UTC, as the server treats it
    ])
    func parsesServerDatetimes(_ text: String, _ epoch: Double) throws {
        let date = try #require(ISO8601.parse(text))
        #expect(abs(date.timeIntervalSince1970 - epoch) < 0.000_01)
    }

    @Test(arguments: ["2027-03-07", "2027-13-01T00:00:00Z", "not a date", "2027-03-07T25:00:00Z", "2027-03-07T10:00:00Q"])
    func rejectsNonDatetimes(_ text: String) {
        #expect(ISO8601.parse(text) == nil)
    }

    @Test func formatsCanonically() throws {
        let date = try #require(ISO8601.parse("2027-03-08T21:30:00+11:00"))
        #expect(ISO8601.format(date) == "2027-03-08T10:30:00Z")
    }

    @Test func calendarDates() throws {
        let start = try #require(CalendarDate("2027-03-05"))
        let end = try #require(CalendarDate("2027-03-23"))
        #expect(start.through(end).count == 19)
        #expect(end.days(since: start) == 18)
        #expect(start.adding(days: 20) == CalendarDate("2027-03-25"))
        #expect(CalendarDate("2027-02-29") == nil)
        #expect(start.description == "2027-03-05")
    }

    @Test func dateLineFlight() throws {
        let trip = try Fixture.trip()
        let flight = try #require(trip.transportations.first { $0.name.contains("EX 7 ") })
        let departs = try #require(flight.date)
        let arrives = try #require(flight.endDate)
        let fromZone = TripTime.zone(flight.startTimezone, fallback: .gmt)
        let toZone = TripTime.zone(flight.endTimezone, fallback: .gmt)

        #expect(hm(TripTime.clock(of: departs, in: fromZone)) == "19:10")
        #expect(TripTime.localDate(of: departs, in: fromZone) == CalendarDate("2027-03-05"))
        #expect(hm(TripTime.clock(of: arrives, in: toZone)) == "05:00")
        #expect(TripTime.localDate(of: arrives, in: toZone) == CalendarDate("2027-03-07"))

        let row = try #require(trip.itinerary.first { $0.objectId == flight.id })
        let day = try #require(row.date)
        #expect(day == CalendarDate("2027-03-05"), "a row's day is its own date, not derived from the item's times")
        #expect(TripTime.dayOffset(of: arrives, in: toZone, from: day) == 2)
        #expect(TripTime.offsetLabel(2) == "+2 days")
        #expect(flight.travelDurationMinutes == 890)
    }

    @Test func allDayNeedsBothEndsAtUTCMidnight() throws {
        let trip = try Fixture.trip()
        let hike = try #require(trip.locations.first { $0.name == "Dove Lake Circuit" }?.visits.first)
        #expect(TripTime.isAllDay(start: hike.startDate, end: hike.endDate))
        #expect(TripTime.localDate(of: hike.startDate!, in: hobart, allDay: true) == CalendarDate("2027-03-10"))

        // 11:00 AEDT is 00:00Z: the server's calendar calls this all-day; the app must not.
        let kayak = try #require(trip.locations.first { $0.name == "Harbour kayak tour" }?.visits.first)
        #expect(!TripTime.isAllDay(start: kayak.startDate, end: kayak.endDate))
        #expect(hm(TripTime.clock(of: kayak.startDate!, in: hobart)) == "11:00")
    }

    @Test func timedItemLandsOnItsLocalDay() throws {
        let trip = try Fixture.trip()
        let taxi = try #require(trip.transportations.first { $0.name.hasPrefix("Taxi") })
        // 22:15Z on the 6th is 09:15 on the 7th in Hobart.
        #expect(TripTime.localDate(of: taxi.date!, in: hobart) == CalendarDate("2027-03-07"))
    }

    @Test func shortTimeUsesTheItemsZone() throws {
        let date = try #require(ISO8601.parse("2027-03-06T03:10:00Z"))
        let text = TripTime.shortTime(date, in: losAngeles, locale: Locale(identifier: "en_GB"))
        #expect(text == "19:10")
    }
}
