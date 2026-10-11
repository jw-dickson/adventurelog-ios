// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

/// A made-up drive for day 4 of the synthetic trip (Mon 8 Mar 2027, Tasmania), sampled the way
/// the phone records it: every 30 s while driving, every minute while stopped, and sometimes
/// nothing at all while parked.
enum SyntheticDrive {
    static let hobart = TimeZone(identifier: "Australia/Hobart")!
    static let carHire = (-42.85, 147.5)
    static let hobartCBD = (-42.8821, 147.3272)
    static let swansea = (-42.1236, 148.0727)
    static let holidayPark = (-42.1247, 148.2861)
    static let lookout = (-42.15, 148.29)
    static let cruise = (-42.121, 148.283)

    /// 8 Mar at a local time ("16:20").
    static func at(_ clock: String) -> Date {
        let parts = clock.split(separator: ":").compactMap { Int($0) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = hobart
        return calendar.date(from: DateComponents(year: 2027, month: 3, day: 8, hour: parts[0], minute: parts[1],
                                                  second: parts.count > 2 ? parts[2] : 0))!
    }

    static func dwell(_ place: (Double, Double), from start: String, to end: String) -> [TrackPoint] {
        var points: [TrackPoint] = []
        var time = at(start), index = 0.0
        while time <= at(end) {
            // A few metres of GPS wander.
            points.append(TrackPoint(time: time, latitude: place.0 + sin(index) * 0.00004, longitude: place.1 + cos(index) * 0.00004))
            time = time.addingTimeInterval(60)
            index += 1
        }
        return points
    }

    static func drive(_ from: (Double, Double), _ to: (Double, Double), from start: String, to end: String,
                      includeStart: Bool = true) -> [TrackPoint] {
        let t0 = at(start), t1 = at(end)
        let total = t1.timeIntervalSince(t0)
        var points: [TrackPoint] = []
        var elapsed = includeStart ? 0.0 : 30.0
        while elapsed <= total {
            let f = elapsed / total
            points.append(TrackPoint(time: t0.addingTimeInterval(elapsed), latitude: from.0 + (to.0 - from.0) * f,
                                     longitude: from.1 + (to.1 - from.1) * f, speed: 20))
            elapsed += 30
        }
        return points
    }

    static var day: [TrackPoint] {
        dwell(carHire, from: "08:55", to: "09:50")
            + drive(carHire, hobartCBD, from: "09:50", to: "10:20")
            // Parked in town: one point on arrival, then nothing until the car moves again.
            + drive(hobartCBD, swansea, from: "10:58", to: "12:20", includeStart: false)
            + dwell(swansea, from: "12:20", to: "12:42")
            + drive(swansea, holidayPark, from: "12:42", to: "13:05")
            + dwell(holidayPark, from: "13:05", to: "16:10")
            + drive(holidayPark, lookout, from: "16:10", to: "16:20")
            + dwell(lookout, from: "16:20", to: "16:50")
            + drive(lookout, cruise, from: "16:50", to: "17:00")
            + dwell(cruise, from: "17:00", to: "20:35")
    }
}

@Suite("Tracking")
struct TrackingTests {
    let d2 = CalendarDate("2027-03-08")!

    func plan() throws -> TripPlan {
        TripPlan(try Fixture.trip(), fallbackTimeZone: SyntheticDrive.hobart)
    }

    func local(_ date: Date?) -> String {
        guard let date else { return "–" }
        let clock = TripTime.clock(of: date, in: SyntheticDrive.hobart)
        return String(format: "%02d:%02d", clock.hour, clock.minute)
    }

    @Test func findsTheStopsIncludingOneWithNoPointsWhileParked() {
        let stops = StopDetector.stops(in: SyntheticDrive.day)
        #expect(stops.map { "\(local($0.start))–\(local($0.end))" } == [
            "08:55–09:50", "10:20–10:58", "12:20–12:42", "13:05–16:10", "16:20–16:50", "17:00–20:35",
        ])
    }

    /// The exit check in miniature: a replayed drive detects the planned stops, in the trip's zone.
    @Test func theReplayedDayMatchesThePlan() throws {
        let log = TripLog.day(d2, plan: try plan(), points: SyntheticDrive.day, now: SyntheticDrive.at("21:00"))
        let rows = log.rows.map { "\(local($0.actualStart)) \($0.title) · \($0.detail)" }
        #expect(rows == [
            "08:55 Car hire (Hobart → Hobart) · Stayed 55 min",
            "10:58 Drive Hobart → Freycinet · Took 2 h 7 min",
            "12:20 Unplanned stop · Unplanned stop · 22 min",
            "13:05 Bay Holiday Park · Stayed 3 h 5 min",
            "16:20 Wineglass Bay Lookout · 20 min later than planned",
            "17:00 Sunset cruise · Stayed 3 h 35 min",
        ])
        #expect(log.plannedDone == 5 && log.plannedCount == 5)
        #expect((135...150).contains(Int(log.drivenKilometres)), "\(log.drivenKilometres) km")
        #expect(log.plannedKilometres.map(Int.init) == 115)
    }

    @Test func partWayThroughTheDay() throws {
        let morning = SyntheticDrive.day.filter { $0.time <= SyntheticDrive.at("12:00") }
        let log = TripLog.day(d2, plan: try plan(), points: morning, now: SyntheticDrive.at("12:00"))
        let status = Dictionary(uniqueKeysWithValues: log.rows.compactMap { row in row.rowID.map { ($0, row.status) } })
        let plan = try plan()
        let entries = try #require(plan.day(for: d2)?.entries)
        let byTitle = Dictionary(uniqueKeysWithValues: entries.compactMap { entry in status[entry.row.id].map { (entry.item.title, $0) } })
        #expect(byTitle["Car hire (Hobart → Hobart)"] == .done)
        #expect(byTitle["Drive Hobart → Freycinet"] == .done)
        #expect(byTitle["Bay Holiday Park"] == .upcoming)
        #expect(byTitle["Sunset cruise"] == .upcoming)
        #expect(log.plannedDone == 2)
    }

    @Test func skipsGeofencesAndMissedVisits() throws {
        let plan = try plan()
        let entries = try #require(plan.day(for: d2)?.entries)
        let lookout = try #require(entries.first { $0.item.title == "Wineglass Bay Lookout" })
        let cruise = try #require(entries.first { $0.item.title == "Sunset cruise" })
        let events = [
            PlaceEvent(rowID: cruise.row.id, kind: .arrived, time: SyntheticDrive.at("18:20")),
            PlaceEvent(rowID: cruise.row.id, kind: .left, time: SyntheticDrive.at("20:40")),
        ]
        let log = TripLog.day(d2, plan: plan, points: SyntheticDrive.day, events: events, skipped: [lookout.row.id],
                              now: SyntheticDrive.at("21:00"))
        #expect(log.rows.first { $0.rowID == lookout.row.id }?.status == .skipped)
        // The geofence beats the track: arrived 18:20, ten minutes before the 18:30 start.
        let cruiseRow = try #require(log.rows.first { $0.rowID == cruise.row.id })
        #expect(local(cruiseRow.actualStart) == "18:20" && cruiseRow.status == .done)
        // The skipped lookout's stop now shows as unplanned.
        #expect(log.rows.contains { $0.status == .unplanned && local($0.actualStart) == "16:20" })

        let empty = TripLog.day(d2, plan: plan, points: [], now: SyntheticDrive.at("21:00"))
        #expect(empty.rows.allSatisfy { $0.status == .missed })
        #expect(empty.plannedDone == 0 && empty.drivenKilometres == 0)
    }

    @Test func watchesTheStopsStillToComeButNotJourneys() throws {
        let plan = try plan()
        let entries = try #require(plan.day(for: d2)?.entries)
        func titles(_ places: [WatchedPlace]) -> [String] {
            places.compactMap { place in entries.first { $0.row.id == place.rowID }?.item.title }
        }
        #expect(titles(TripLog.placesToWatch(on: d2, plan: plan, now: SyntheticDrive.at("07:00"))) == [
            "Car hire (Hobart → Hobart)", "Bay Holiday Park", "Wineglass Bay Lookout", "Sunset cruise",
        ])
        let lookout = try #require(entries.first { $0.item.title == "Wineglass Bay Lookout" })
        let midday = TripLog.placesToWatch(on: d2, plan: plan, skipped: [lookout.row.id], now: SyntheticDrive.at("12:00"))
        #expect(titles(midday) == ["Bay Holiday Park", "Sunset cruise"])
        #expect(midday.first?.radius == 250 && midday.last?.radius == 150)
        #expect(TripLog.placesToWatch(on: d2, plan: plan, now: SyntheticDrive.at("07:00"), limit: 2).count == 2)
    }

    @Test func gpxIsWellFormed() throws {
        let points = Array(SyntheticDrive.day.prefix(3))
        let text = GPX.document(name: "Day 4 & more", segments: [Array(points.prefix(2)), [points[2]]],
                                waypoints: [GPX.Waypoint(name: "Swansea <stop>", latitude: -42.1236, longitude: 148.0727)])
        #expect(text.components(separatedBy: "<trkpt ").count - 1 == 3)
        #expect(text.components(separatedBy: "<trkseg>").count - 1 == 2)
        #expect(text.contains(#"<trkpt lat="-42.850000" lon="147.500040">"#) || text.contains(#"lat="-42.850000""#))
        #expect(text.contains("<time>2027-03-07T21:55:00Z</time>"))
        #expect(text.contains("Day 4 &amp; more") && text.contains("Swansea &lt;stop&gt;"))
        let parser = XMLParser(data: Data(text.utf8))
        #expect(parser.parse(), "\(parser.parserError.map(String.init(describing:)) ?? "")")
    }
}
