// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

/// Routed drive times (#42): the times here are made up, standing in for Apple Maps.
@Suite("Route times")
struct RouteTimesTests {
    let hobart = TimeZone(identifier: "Australia/Hobart")!
    let gb = Locale(identifier: "en_GB")
    let carPark = ItemSummary.Coordinate(-42.120, 148.300)!
    let tourville = ItemSummary.Coordinate(-42.120, 148.340)!

    func plan() throws -> TripPlan {
        TripPlan(try Fixture.trip(), fallbackTimeZone: hobart)
    }

    func at(_ iso: String) -> Date { ISO8601.parse(iso)! }

    func shown(_ clock: String) -> String {
        TripTime.shortTime(at("2027-03-08T\(clock):00+11:00"), in: hobart, locale: gb)
    }

    @Test func aLookedUpTimeReplacesTheEstimateAndNoRouteKeepsIt() {
        let leg = RouteTimes.Leg(from: carPark, to: tourville, departure: at("2027-03-08T05:00:00Z"))
        var routes = RouteTimes()
        #expect(routes.travel(from: carPark, to: tourville) == .init(minutes: 10, isRouted: false))
        #expect(routes.travel(from: carPark, to: tourville).driveText == "~10 min drive")

        routes.record(leg, seconds: 14 * 60 + 5, at: at("2027-03-07T20:00:00Z"))
        #expect(routes.travel(from: carPark, to: tourville) == .init(minutes: 15, isRouted: true), "rounded up to the minute")
        #expect(routes.travel(from: carPark, to: tourville).driveText == "15 min drive")
        // A few metres away is the same leg; the way back is not.
        #expect(routes.minutes(from: ItemSummary.Coordinate(-42.1202, 148.3001)!, to: tourville) == 15)
        #expect(routes.minutes(from: tourville, to: carPark) == nil)

        routes.record(leg, seconds: nil, at: at("2027-03-07T21:00:00Z"))
        #expect(routes.entries.count == 1)
        #expect(routes.travel(from: carPark, to: tourville).isRouted == false)
    }

    @Test func answersAreAskedAgainWhenOldOrForAnotherTime() {
        let leg = RouteTimes.Leg(from: carPark, to: tourville, departure: at("2027-03-08T05:00:00Z"))
        var routes = RouteTimes()
        #expect(routes.needsLookup(leg, now: at("2027-03-07T20:00:00Z")))
        routes.record(leg, seconds: 600, at: at("2027-03-07T20:00:00Z"))
        #expect(!routes.needsLookup(leg, now: at("2027-03-08T19:59:00Z")))
        #expect(routes.needsLookup(leg, now: at("2027-03-08T20:00:00Z")), "a day old")
        let evening = RouteTimes.Leg(from: carPark, to: tourville, departure: at("2027-03-08T09:00:00Z"))
        #expect(routes.needsLookup(evening, now: at("2027-03-07T21:00:00Z")), "four hours later, other traffic")

        routes.prune(now: at("2027-03-21T20:00:00Z"))
        #expect(routes.entries.count == 1)
        routes.prune(now: at("2027-03-21T20:01:00Z"))
        #expect(routes.entries.isEmpty)
    }

    @Test func theCacheSurvivesBeingSaved() throws {
        var routes = RouteTimes()
        routes.record(.init(from: tourville, to: carPark, departure: at("2027-03-08T06:00:00Z")), seconds: 700, at: at("2027-03-07T20:00:00Z"))
        routes.record(.init(from: carPark, to: tourville, departure: at("2027-03-08T05:00:00Z")), seconds: nil, at: at("2027-03-07T20:00:00Z"))
        let data = try JSONEncoder().encode(routes)
        #expect(try JSONDecoder().decode(RouteTimes.self, from: data) == routes)
    }

    /// The drive day of the fixture trip, looked up the evening before.
    @Test func theNextTwoDaysLegsAreLookedUpSoonestFirst() throws {
        let plan = try plan()
        let now = at("2027-03-07T20:00:00Z")
        let legs = RouteTimes().legsToLookUp(in: plan, now: now)
        #expect(!legs.isEmpty)
        #expect(legs.map(\.departure) == legs.map(\.departure).sorted())
        #expect(legs.allSatisfy { $0.departure >= now.addingTimeInterval(-3600) && $0.departure <= now.addingTimeInterval(48 * 3600) })
        #expect(Set(legs.map(\.key)).count == legs.count)
        #expect(legs.allSatisfy { LeaveBy.kilometres(from: $0.from, to: $0.to) > 0.3 })

        // Once looked up, nothing is asked again that day.
        var routes = RouteTimes()
        for leg in legs { routes.record(leg, seconds: 1200, at: now) }
        #expect(routes.legsToLookUp(in: plan, now: now.addingTimeInterval(3600)).isEmpty)
        // A month on, the trip is over.
        #expect(RouteTimes().legsToLookUp(in: plan, now: at("2027-04-01T00:00:00Z")).isEmpty)
    }

    @Test func aLeaveByReminderUsesTheRoutedTime() throws {
        let plan = try plan()
        let now = at("2027-03-07T20:00:00Z")
        // The sunset cruise at 18:30 is about 10 minutes from the stop before it.
        let start = at("2027-03-08T18:30:00+11:00")
        let leg = try #require(RouteTimes.legs(in: plan).first { $0.departure == start.addingTimeInterval(-600) })
        var routes = RouteTimes()
        routes.record(leg, seconds: 25 * 60, at: now)

        let reminders = ReminderPlanner.reminders(for: plan, now: now, routes: routes, locale: gb)
        let cruise = try #require(reminders.first { $0.kind == .leaveBy && $0.title.contains("Sunset cruise") })
        #expect(cruise.title == "Leave by \(shown("18:00")) for Sunset cruise")
        #expect(cruise.body == "25 min drive · starts \(shown("18:30"))")
    }

    @Test func replanUsesTheRoutedTimeButDoesNotSendIt() throws {
        let day = CalendarDate("2027-03-08")!
        let walk = Replan.Stop(rowID: "row-walk", itemID: "walk", title: "Cape Tourville walk", kind: .location,
                               start: at("2027-03-08T16:00:00+11:00"), end: at("2027-03-08T17:00:00+11:00"),
                               zone: hobart, isBooked: false, coordinate: tourville)
        let now = at("2027-03-08T16:20:00+11:00")
        #expect(Replan.delay(now: now, position: carPark, target: walk) == 30, "the estimate: 10 min")
        var routes = RouteTimes()
        routes.record(.init(from: carPark, to: tourville, departure: now), seconds: 18 * 60, at: now)
        #expect(Replan.delay(now: now, position: carPark, target: walk, routes: routes) == 38)

        let situation = Replan.Situation(date: day, now: now, stops: [walk], delayMinutes: 38, position: carPark,
                                         zone: hobart, routes: routes)
        let data = try JSONEncoder().encode(situation)
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(!json.contains("routes") && !json.contains("fetched"))
        let decoded = try JSONDecoder().decode(Replan.Situation.self, from: data)
        #expect(decoded.routes == RouteTimes())
        #expect(decoded.stops == situation.stops && decoded.delayMinutes == 38)
    }
}
