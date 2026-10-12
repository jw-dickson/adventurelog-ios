// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Where a day's clock changes")
struct ZoneShiftTests {
    func zone(_ id: String) throws -> TimeZone { try #require(TimeZone(identifier: id)) }

    @Test func theTravelDayShowsEachChangeWhereItHappens() throws {
        // Fri 5 Mar: Denver → Los Angeles, then Los Angeles → Sydney (US clocks change on 14 Mar).
        let plan = try TripPlan(Fixture.trip(), fallbackTimeZone: .gmt)
        let day = try #require(plan.day(for: try #require(CalendarDate("2027-03-05"))))
        let summaries = day.entries.map { $0.summary(in: plan) }
        let marks = ZoneShift.marks(summaries)
        let byTitle = Dictionary(zip(summaries.map(\.title), marks), uniquingKeysWith: { first, _ in first })

        let denver = try #require(byTitle["Example Air EX 101 DEN → LAX"])
        #expect(denver.before == nil)
        #expect(denver.within?.minutes == -60)
        #expect(denver.within?.text == "Now on Los Angeles time · clocks go back 1 h")

        let pacific = try #require(byTitle["Example Air EX 7 LAX → SYD"])
        #expect(pacific.before == nil, "it leaves from where the last flight landed")
        #expect(pacific.within?.minutes == 19 * 60)
        #expect(pacific.within?.text == "Now on Sydney time · clocks go forward 19 h")
    }

    @Test func sameClockDifferentPlaceIsNoChange() throws {
        // Sydney and Hobart keep the same time, so landing in Hobart shows nothing.
        let at = try #require(ISO8601.parse("2027-03-06T21:50:00Z"))
        #expect(ZoneShift(from: try zone("Australia/Sydney"), to: try zone("Australia/Hobart"), at: at) == nil)
    }

    @Test func theZonesOwnRulesDecideTheAmount() throws {
        // Daylight saving decides it: on 30 Mar 2027 Sydney is +11, Brisbane +10 and Adelaide +10:30.
        let at = try #require(ISO8601.parse("2027-03-30T00:00:00Z"))
        let shift = try #require(ZoneShift(from: try zone("Australia/Sydney"), to: try zone("Australia/Brisbane"), at: at))
        #expect(shift.minutes == -60)
        #expect(shift.text == "Now on Brisbane time · clocks go back 1 h")
        let half = try #require(ZoneShift(from: try zone("Australia/Brisbane"), to: try zone("Australia/Adelaide"), at: at))
        #expect(half.text == "Now on Adelaide time · clocks go forward 30 min")
    }
}
