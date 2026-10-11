// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("What a timeline row shows")
struct ItemSummaryTests {
    let gb = Locale(identifier: "en_GB")

    func plan() throws -> TripPlan {
        try TripPlan(Fixture.trip(), fallbackTimeZone: .gmt)
    }

    /// The summary of the row on `date` whose item id starts with `prefix`.
    func summary(_ prefix: String, on date: String) throws -> ItemSummary {
        let plan = try plan()
        let day = try #require(CalendarDate(date))
        let tripDay = try #require(plan.day(for: day))
        let entry = try #require(tripDay.entries.first { $0.item.id.hasPrefix(prefix) })
        return entry.summary(in: plan)
    }

    @Test func overnightFlightShowsItsArrivalDate() throws {
        let flight = try summary("d8171654", on: "2027-03-05")
        #expect(flight.symbol == "airplane")
        #expect(flight.reference == "EX7")
        #expect(flight.isBooked)
        #expect(flight.startText(locale: gb) == "19:10")
        #expect(flight.startOffsetDays == 0)
        #expect(flight.spanDays == 2)
        #expect(flight.secondaryTimeText(locale: gb) == "7 Mar")
        // The name already says LAX → SYD, so the detail does not repeat it.
        let detail = try #require(flight.detail)
        #expect(detail == "14 h 50 min")
        #expect(flight.link?.host() == "example.com")
        #expect(flight.coordinate != nil && flight.destination != nil)
    }

    @Test func multiDayHireShowsItsReturnDate() throws {
        let hire = try summary("7df86ee7", on: "2027-03-08")
        #expect(hire.startText(locale: gb)?.hasSuffix("9:00") == true) // "9:00" or "09:00" depending on ICU data
        #expect(hire.secondaryTimeText(locale: gb) == "23 Mar")
        #expect(hire.isBooked == false)
        #expect(hire.detail?.contains("km") == false, "zero distance is not shown")
    }

    @Test func sameDayItemShowsItsEndTime() throws {
        let drive = try summary("e5aabe2c", on: "2027-03-08")
        #expect(drive.startText(locale: gb) == "11:00")
        #expect(drive.secondaryTimeText(locale: gb) == "14:30")
        #expect(drive.detail == "Hobart → Coles Bay · 3 h 30 min · 115 km")
    }

    @Test func taggedPlaceIsBooked() throws {
        let kayak = try summary("78978dcd", on: "2027-03-07")
        #expect(kayak.isBooked)
        #expect(kayak.reference == nil)
        #expect(kayak.startText(locale: gb) == "11:00")
        #expect(kayak.secondaryTimeText(locale: gb) == "11:45")
        #expect(kayak.categoryName == "Activity")
        #expect(kayak.notes?.contains("KAY-1001") == true)
    }

    @Test func placeNotesJoinDescriptionAndVisitNotes() throws {
        let tour = try summary("547ce065", on: "2027-03-08")
        #expect(tour.startText(locale: gb) == "18:30")
        #expect(tour.secondaryTimeText(locale: gb) == "20:30")
        #expect(tour.notes?.contains("Bring a jacket") == true)
        #expect(tour.whenText(locale: gb)?.hasPrefix("Mon 8 Mar · 18:30–20:30") == true)
        #expect(tour.isBooked == false)
    }

    @Test func campgroundUsesATentAndItsReservation() throws {
        let camp = try summary("07e61ce8", on: "2027-03-08")
        #expect(camp.symbol == "tent.fill")
        #expect(camp.reference == "BHP-0042")
        #expect(camp.isBooked)
        #expect(camp.startText(locale: gb) == "15:00")
        #expect(camp.secondaryTimeText(locale: gb) == "9 Mar")
        #expect(camp.detail == "Campground · 1 Example Rd, Coles Bay TAS 7215")
    }

    @Test func checklistCountsWhatIsDone() throws {
        let list = try summary("b1bb2988", on: "2027-03-08")
        #expect(list.detail == "3 of 5 done")
        #expect(list.checklist.count == 5)
        #expect(list.startText(locale: gb) == nil)
    }

    @Test func allDayPlaceOffTheItinerary() throws {
        let plan = try plan()
        let hike = try #require(plan.unscheduled.first { $0.id.hasPrefix("19b7a4bb") })
        let summary = ItemSummary(hike, day: nil, tripZone: plan.timeZone)
        #expect(summary.isAllDay)
        #expect(summary.startText(locale: gb) == "All day")
        #expect(summary.secondaryTimeText(locale: gb) == nil)
        let during = try #require(ISO8601.parse("2027-03-10T08:00:00Z"))
        let after = try #require(ISO8601.parse("2027-03-11T08:00:00Z"))
        #expect(summary.isPast(at: during) == false)
        #expect(summary.isPast(at: after))
    }

    @Test func timedItemsArePastOnceTheyEnd() throws {
        let drive = try summary("e5aabe2c", on: "2027-03-08")
        let during = try #require(ISO8601.parse("2027-03-08T01:00:00Z"))
        let after = try #require(ISO8601.parse("2027-03-08T03:31:00Z"))
        #expect(drive.isPast(at: during) == false)
        #expect(drive.isPast(at: after))
    }

    @Test func durations() {
        #expect(ItemSummary.durationText(minutes: 45) == "45 min")
        #expect(ItemSummary.durationText(minutes: 120) == "2 h")
        #expect(ItemSummary.durationText(minutes: 745) == "12 h 25 min")
    }

    @Test func coordinatesRejectNullIsland() {
        #expect(ItemSummary.Coordinate(0, 0) == nil)
        #expect(ItemSummary.Coordinate(91, 10) == nil)
        #expect(ItemSummary.Coordinate(nil, 10) == nil)
        #expect(ItemSummary.Coordinate(-42.9, 147.3) != nil)
    }
}

@Suite("Trips screen sections")
struct TripListSectionsTests {
    func trip(_ name: String, _ start: String?, _ end: String?, archived: Bool = false) throws -> CollectionSummary {
        var json: [String: Any] = ["id": UUID().uuidString, "name": name, "is_archived": archived]
        if let start { json["start_date"] = start }
        if let end { json["end_date"] = end }
        let data = try JSONSerialization.data(withJSONObject: json)
        return try ALCoding.decoder().decode(CollectionSummary.self, from: data)
    }

    @Test func sortsTripsAroundToday() throws {
        let today = try #require(CalendarDate("2027-03-08"))
        let owned = try [
            trip("Road trip", "2027-03-05", "2027-03-23"),
            trip("City weekend", "2027-05-06", "2027-05-08"),
            trip("Desert camping", "2027-04-10", "2027-04-12"),
            trip("Spring trip", "2026-04-01", "2026-04-10"),
            trip("Coast trip", "2026-08-01", "2026-08-05"),
            trip("Ideas", nil, nil),
            trip("Old", "2025-01-01", "2025-01-02", archived: true),
        ]
        let shared = try [trip("Friend's trip", "2027-06-01", "2027-06-05"), trip("Shared now", "2027-03-07", "2027-03-09")]
        let sections = TripListSections(owned: owned, shared: shared, today: today)
        #expect(sections.happeningNow.map(\.name) == ["Shared now", "Road trip"])
        #expect(sections.upcoming.map(\.name) == ["Desert camping", "City weekend"])
        #expect(sections.shared.map(\.name) == ["Friend's trip"])
        #expect(sections.past.map(\.name) == ["Coast trip", "Spring trip"])
        #expect(sections.collections.map(\.name) == ["Ideas"])
        #expect(sections.current?.name == "Shared now")
    }

    @Test func firstAndLastDaysCountAsNow() throws {
        let trips = try [trip("Road trip", "2027-03-05", "2027-03-23")]
        let first = try #require(CalendarDate("2027-03-05"))
        let last = try #require(CalendarDate("2027-03-23"))
        let after = try #require(CalendarDate("2027-03-24"))
        #expect(TripListSections(owned: trips, shared: [], today: first).happeningNow.count == 1)
        #expect(TripListSections(owned: trips, shared: [], today: last).happeningNow.count == 1)
        #expect(TripListSections(owned: trips, shared: [], today: after).past.count == 1)
    }

    @Test func reversedDatesStillSort() throws {
        let trips = try [trip("Backwards", "2027-03-23", "2027-03-05")]
        let today = try #require(CalendarDate("2027-03-13"))
        #expect(TripListSections(owned: trips, shared: [], today: today).happeningNow.count == 1)
    }

    @Test func searchFilters() throws {
        let trips = try [trip("Coastal loop", "2027-03-05", "2027-03-23"), trip("City weekend", "2027-05-06", "2027-05-08")]
        let today = try #require(CalendarDate("2026-10-11"))
        let sections = TripListSections(owned: trips, shared: [], today: today, matching: "coastal")
        #expect(sections.upcoming.map(\.name) == ["Coastal loop"])
        #expect(TripListSections(owned: trips, shared: [], today: today, matching: "zzz").isEmpty)
    }
}
