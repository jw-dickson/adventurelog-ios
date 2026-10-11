// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Trip planning with incomplete and unusual data")
struct TripPlanEdgeCaseTests {
    private func emptyTrip() throws -> CollectionDetail {
        try ALCoding.decoder().decode(CollectionDetail.self, from: Data(#"{"id":"c","name":"Trip"}"#.utf8))
    }

    private func row(_ id: String, on date: CalendarDate?, order: Int = 0, global: Bool = false) -> ItineraryRow {
        ItineraryRow(id: id, collection: "c", objectId: "missing-\(id)", item: nil, objectName: "note",
                     date: date, isGlobal: global, order: order, startDatetime: nil, endDatetime: nil)
    }

    @Test func emptyUndatedCollectionUsesFallbackAndHasNoDays() throws {
        let fallback = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let plan = TripPlan(try emptyTrip(), fallbackTimeZone: fallback)
        #expect(plan.timeZone == fallback)
        #expect(plan.days.isEmpty)
        #expect(plan.tripWide.isEmpty)
        #expect(plan.unscheduled.isEmpty)
        let date = try #require(CalendarDate("2027-03-07"))
        #expect(plan.day(for: date) == nil)
    }

    @Test func rowsOutsideTripDatesArePreservedAndSorted() throws {
        var trip = try emptyTrip()
        let start = try #require(CalendarDate("2027-03-07"))
        trip.startDate = start
        trip.endDate = start.adding(days: 1)
        trip.itinerary = [row("after", on: start.adding(days: 2)), row("before", on: start.adding(days: -1))]
        let plan = TripPlan(trip, fallbackTimeZone: .gmt)
        #expect(plan.days.map(\.date) == start.adding(days: -1).through(start.adding(days: 2)))
        #expect(plan.days.map(\.number) == [1, 2, 3, 4])
        #expect(plan.days.flatMap(\.entries).map(\.id) == ["before", "after"])
        #expect(plan.day(for: start)?.entries.isEmpty == true)
    }

    @Test(arguments: ["missing-both", "missing-end", "reversed"])
    func invalidRangesUseTheUnionOfRowsAndDayMetadata(_ shape: String) throws {
        var trip = try emptyTrip()
        let first = try #require(CalendarDate("2027-03-07"))
        if shape != "missing-both" { trip.startDate = first.adding(days: 10) }
        if shape == "reversed" { trip.endDate = first }
        trip.itinerary = [row("day", on: first)]
        trip.itineraryDays = [
            ItineraryDayMeta(id: "m", collection: "c", date: first.adding(days: 2), name: "  \n", description: "\t"),
            ItineraryDayMeta(id: "same-day", collection: "c", date: first, name: "Arrival", description: "Keep this"),
        ]
        let plan = TripPlan(trip, fallbackTimeZone: .gmt)
        #expect(plan.days.map(\.date) == [first, first.adding(days: 2)])
        #expect(plan.days.map(\.number) == [1, 2])
        #expect(plan.days[0].name == "Arrival")
        #expect(plan.days[0].description == "Keep this")
        #expect(plan.days[1].name == nil)
        #expect(plan.days[1].description == nil)
    }

    @Test func tiedOrdersUseRowIDsAndGlobalRowsNeverBecomeDays() throws {
        var trip = try emptyTrip()
        let date = try #require(CalendarDate("2027-03-07"))
        trip.itinerary = [row("z", on: date, order: 4), row("b", on: date, order: 1),
                          row("a", on: date, order: 1), row("global", on: date, global: true),
                          row("dateless", on: nil, order: 5)]
        let plan = TripPlan(trip, fallbackTimeZone: .gmt)
        #expect(plan.days.count == 1)
        #expect(plan.days[0].entries.map(\.id) == ["a", "b", "z"])
        #expect(plan.tripWide.map(\.id) == ["global", "dateless"])
    }

    @Test(arguments: Array(ItemKind.allCases))
    func unresolvedRowsRetainTheirIdentityAndKind(_ kind: ItemKind) throws {
        var trip = try emptyTrip()
        var missing = row("row", on: nil, global: true)
        missing.objectName = kind.rawValue
        trip.itinerary = [missing]
        let plan = TripPlan(trip, fallbackTimeZone: .gmt)
        let entry = try #require(plan.tripWide.first)
        #expect(entry.id == "row")
        #expect(entry.item == .missing(kind: kind, id: "missing-row"))
        #expect(entry.item.id == "missing-row")
        #expect(entry.item.kind == kind)
        #expect(entry.item.title == "Unavailable item")
    }

    @Test func duplicatePayloadObjectsUseTheFirstAndPlacedItemsAreNotUnscheduled() throws {
        var trip = try emptyTrip()
        let json = #"[{"id":"placed","name":"First"},{"id":"placed","name":"Duplicate"},{"id":"loose","name":"Loose"}]"#
        trip.notes = try ALCoding.decoder().decode([Note].self, from: Data(json.utf8))
        var placed = row("row", on: nil, global: true)
        placed.objectId = "placed"
        trip.itinerary = [placed]
        let plan = TripPlan(trip, fallbackTimeZone: .gmt)
        #expect(plan.tripWide.map(\.item.title) == ["First"])
        #expect(plan.unscheduled.map(\.id) == ["loose"])
    }

    @Test func visitsUseTheirOwnZonesAndAllDayDatesThenSortByStart() throws {
        let json = #"""
        {"id":"l","name":"Place","visits":[
          {"id":"late","start_date":"2027-03-07T02:00:00Z","timezone":"Australia/Hobart"},
          {"id":"other-day","start_date":"2027-03-07T02:00:00Z","timezone":"America/Los_Angeles"},
          {"id":"all-day","start_date":"2027-03-07T00:00:00Z","timezone":"America/Los_Angeles"},
          {"id":"early","start_date":"2027-03-06T22:00:00Z","timezone":"Australia/Hobart"},
          {"id":"invalid-zone","start_date":"2027-03-07T01:00:00Z","timezone":"Mars/Olympus"},
          {"id":"missing-zone","start_date":"2027-03-07T03:00:00Z"},
          {"id":"no-start"}
        ]}
        """#
        let location = try ALCoding.decoder().decode(Location.self, from: Data(json.utf8))
        let day = try #require(CalendarDate("2027-03-07"))
        let visits = TripPlan.visits(of: location, on: day, fallback: .gmt)
        #expect(visits.map(\.id) == ["early", "all-day", "invalid-zone", "late", "missing-zone"])
    }

    @Test func dominantZoneTiesAreDeterministicAndDepartureZonesDoNotVote() throws {
        var trip = try emptyTrip()
        let json = #"[{"id":"a","name":"A","type":"plane","start_timezone":"Australia/Hobart","end_timezone":"Europe/London"},{"id":"b","name":"B","type":"plane","start_timezone":"Australia/Hobart","end_timezone":"America/Los_Angeles"}]"#
        trip.transportations = try ALCoding.decoder().decode([Transportation].self, from: Data(json.utf8))
        #expect(TripPlan.dominantTimeZone(trip)?.identifier == "America/Los_Angeles")
        trip.transportations.reverse()
        #expect(TripPlan.dominantTimeZone(trip)?.identifier == "America/Los_Angeles")
    }
}
