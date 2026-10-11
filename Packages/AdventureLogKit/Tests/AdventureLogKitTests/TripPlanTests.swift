// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Laying a trip out by day")
struct TripPlanTests {
    func makePlan() throws -> TripPlan {
        try TripPlan(Fixture.trip(), fallbackTimeZone: .gmt)
    }

    /// A day of the seeded trip. Bound in steps: Swift Testing macros cannot nest.
    func tripDay(_ text: String, in plan: TripPlan? = nil) throws -> TripPlan.Day {
        let date = try #require(CalendarDate(text))
        let resolved = try plan ?? makePlan()
        return try #require(resolved.day(for: date))
    }

    @Test func everyDateFromStartToEndIsADay() throws {
        let plan = try makePlan()
        #expect(plan.days.count == 19)
        #expect(plan.days.first?.date == CalendarDate("2027-03-05"))
        #expect(plan.days.last?.date == CalendarDate("2027-03-23"))
        #expect(plan.days.map(\.number) == Array(1...19))
    }

    @Test func tripZoneIsInferredFromItems() throws {
        let plan = try makePlan()
        #expect(plan.timeZone.identifier == "Australia/Hobart")
    }

    @Test func dateLineDayIsEmptyButPresent() throws {
        let day = try tripDay("2027-03-06")
        #expect(day.entries.isEmpty)
        #expect(day.name == nil)
    }

    @Test func dayNamesComeFromItineraryDays() throws {
        let plan = try makePlan()
        #expect(plan.days[0].name?.hasPrefix("D0") == true)
        #expect(plan.day(for: CalendarDate("2027-03-08")!)?.number == 4)
    }

    @Test func entriesFollowServerOrder() throws {
        let day = try tripDay("2027-03-07")
        #expect(day.entries.map(\.item.title) == [
            "Example Air EX 1501 SYD → HBA",
            "Taxi: HBA airport → Harbourside Hotel",
            "Harbourside Hotel",
            "Tasmanian Museum and Art Gallery",
            "Harbour kayak tour",
            "Hobart day tips",
        ])
        #expect(day.entries.map(\.row.order) == [0, 1, 2, 3, 4, 5])
    }

    @Test func locationEntriesCarryThatDaysVisits() throws {
        let day = try tripDay("2027-03-08")
        let lookout = try #require(day.entries.first { $0.item.title == "Wineglass Bay Lookout" })
        guard case .location(_, let visits) = lookout.item else {
            Issue.record("expected a location")
            return
        }
        #expect(visits.count == 1)
    }

    @Test func tripWideAndUnscheduled() throws {
        let plan = try makePlan()
        #expect(plan.tripWide.map(\.item.title) == ["Trip essentials", "Packing list"])
        #expect(plan.unscheduled.map(\.title) == ["Dove Lake Circuit"])
    }

    @Test func rowsPointingAtMissingObjectsAreKept() throws {
        var trip = try Fixture.trip()
        trip.notes.removeAll()
        let plan = TripPlan(trip, fallbackTimeZone: .gmt)
        let day = try tripDay("2027-03-07", in: plan)
        #expect(day.entries.count == 6)
        #expect(day.entries.last?.item == .missing(kind: .note, id: day.entries.last!.row.objectId))
    }
}
