// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Today")
struct TodayPlanTests {
    let hobart = TimeZone(identifier: "Australia/Hobart")!
    let d2 = CalendarDate("2027-03-08")!

    func plan() throws -> TripPlan {
        TripPlan(try Fixture.trip(), fallbackTimeZone: hobart)
    }

    func at(_ iso: String) -> Date { ISO8601.parse(iso)! }

    @Test func eveningOfDayFourIsTheCruiseNext() throws {
        // 18:00 AEDT on Mon 8 Mar: the drive, the stay's check-in and the lookout are behind.
        let now = at("2027-03-08T07:00:00Z")
        let today = try #require(TodayPlan(plan: try plan(), today: d2, now: now))
        #expect(today.next?.summary.title == "Sunset cruise")
        #expect(TodayPlan.nextLabel(for: try #require(today.next), now: now) == "Next · in 30 min")
        #expect(today.metaText == "Day 4 of 19 · 115 km · 4 of 5 done")
        #expect(today.hasOvernight)
        #expect(today.earlier.map(\.summary.title) == ["Car hire (Hobart → Hobart)", "Drive Hobart → Freycinet", "Bay Holiday Park", "Wineglass Bay Lookout"])
        #expect(today.later.map(\.summary.title) == ["Car pickup"], "a checklist with items left stays ahead")
        #expect(today.entries.first { $0.summary.title == "Car hire (Hobart → Hobart)" }?.status == .ongoing)
    }

    @Test func morningOfDayFourIsTheDriveNext() throws {
        // 10:00 AEDT: the car hire has started (it runs for two weeks, so it isn't "next").
        let now = at("2027-03-07T23:00:00Z")
        let today = try #require(TodayPlan(plan: try plan(), today: d2, now: now))
        #expect(today.next?.summary.title == "Drive Hobart → Freycinet")
        #expect(TodayPlan.nextLabel(for: try #require(today.next), now: now) == "Next · in 1 h")
        #expect(today.later.map(\.summary.title) == ["Car pickup", "Bay Holiday Park", "Wineglass Bay Lookout", "Sunset cruise"])
    }

    @Test func somethingUnderWayIsShownAsNow() throws {
        let now = at("2027-03-08T08:00:00Z") // 19:00 AEDT, on the cruise
        let today = try #require(TodayPlan(plan: try plan(), today: d2, now: now))
        let next = try #require(today.next)
        #expect(next.status == .now)
        #expect(TodayPlan.nextLabel(for: next, now: now, locale: Locale(identifier: "en_GB")) == "Now · until 20:30")
    }

    @Test func skippingTheNextItemMovesOn() throws {
        let now = at("2027-03-07T23:00:00Z")
        let base = try #require(TodayPlan(plan: try plan(), today: d2, now: now))
        let drive = try #require(base.next)
        let today = try #require(TodayPlan(plan: try plan(), today: d2, now: now, skipped: [drive.rowID]))
        #expect(today.next?.summary.title == "Bay Holiday Park")
        #expect(today.earlier.contains { $0.id == drive.id && $0.status == .skipped })
        #expect(today.doneCount == base.doneCount, "a skipped place isn't counted as done")
    }

    @Test func aDayOutsideTheTripHasNoToday() throws {
        #expect(TodayPlan(plan: try plan(), today: CalendarDate("2027-04-01")!, now: .now) == nil)
    }

    @Test func leaveByCountsFromThePreviousStop() throws {
        let now = at("2027-03-08T07:00:00Z")
        let today = try #require(TodayPlan(plan: try plan(), today: d2, now: now))
        let next = try #require(today.next)
        let origin = try #require(LeaveBy.origin(before: next, in: today))
        #expect(origin == ItemSummary.Coordinate(-42.15, 148.29), "from the lookout")
        let destination = try #require(next.summary.coordinate)
        let minutes = LeaveBy.estimatedMinutes(from: origin, to: destination)
        #expect(minutes == 10)
        let leave = LeaveBy.time(start: try #require(next.summary.start), travelMinutes: minutes)
        let clock = TripTime.clock(of: leave, in: hobart)
        #expect(clock.hour == 18 && clock.minute == 15)
    }

    @Test func distancesAndRounding() {
        let hobartCBD = ItemSummary.Coordinate(-42.8821, 147.3272)!
        let colesBay = ItemSummary.Coordinate(-42.1236, 148.2890)!
        #expect((105...125).contains(Int(LeaveBy.kilometres(from: hobartCBD, to: colesBay))))
        #expect(LeaveBy.estimatedMinutes(from: hobartCBD, to: hobartCBD) == 5)
        let start = at("2027-03-08T07:32:00Z")
        #expect(LeaveBy.time(start: start, travelMinutes: 8) == at("2027-03-08T07:15:00Z"))
    }
}
