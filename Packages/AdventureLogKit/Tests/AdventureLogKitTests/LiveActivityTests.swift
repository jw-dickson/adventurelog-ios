// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Live Activities")
struct LiveActivityTests {
    func plan() throws -> TripPlan {
        TripPlan(try Fixture.trip(), fallbackTimeZone: TimeZone(identifier: "Australia/Hobart")!)
    }

    func at(_ iso: String) -> Date { ISO8601.parse(iso)! }

    /// The Lock Screen mockup: 05:03 in Sydney, 1 h 12 before EX 1501 boards for Hobart.
    @Test func theSydneyConnectionMatchesTheMockup() throws {
        let now = at("2027-03-06T18:03:00Z") // 05:03 AEDT
        let current = try #require(LiveActivityPlanner.current(for: try plan(), now: now))
        #expect(current.info.kind == .flight)
        #expect(current.info.eyebrow == "Connection · SYD")
        #expect(current.info.title == "EX 1501 to Hobart")
        #expect(current.info.detail == "Domestic connection. Re-check bags at SYD after customs.")
        #expect(current.info.zoneIdentifier == "Australia/Sydney")
        #expect(current.info.windowStart == at("2027-03-06T17:00:00Z")) // 3 h before departure
        #expect(current.state.phase == .upcoming)
        #expect(current.state.target == at("2027-03-06T19:15:00Z"))     // boards 06:15
        #expect(current.state.countdownTarget.timeIntervalSince(now) == 72 * 60)
        #expect(current.end == at("2027-03-06T20:00:00Z"))
        // 63 of the 135 minutes between the start and boarding have passed.
        let progress = current.state.progress(windowStart: current.info.windowStart, now: now)
        #expect(abs(progress - 63.0 / 135.0) < 0.001)
    }

    @Test func boardingCountsDownToDepartureThenTheActivityEnds() throws {
        let plan = try plan()
        let boarding = try #require(LiveActivityPlanner.current(for: plan, now: at("2027-03-06T19:30:00Z")))
        #expect(boarding.state.phase == .boarding)
        #expect(boarding.state.countdownTarget == at("2027-03-06T20:00:00Z"))
        #expect(LiveActivityPlanner.current(for: plan, now: at("2027-03-06T20:00:00Z")) == nil)
    }

    @Test func theFirstFlightIsNotAConnection() throws {
        let current = try #require(LiveActivityPlanner.current(for: try plan(), now: at("2027-03-05T18:00:00Z")))
        #expect(current.info.eyebrow == "Flight · DEN")
        #expect(current.info.title == "EX 101 to Los Angeles")
    }

    @Test func aBookedTourGetsAnHourAndUnbookedPlacesNone() throws {
        let plan = try plan()
        // Harbour kayak tour (tagged booked) at 11:00 Hobart, 7 Mar.
        let tour = try #require(LiveActivityPlanner.current(for: plan, now: at("2027-03-06T23:30:00Z")))
        #expect(tour.info.kind == .tour)
        #expect(tour.info.eyebrow == "Booked tour")
        #expect(tour.info.title == "Harbour kayak tour")
        #expect(tour.state.target == at("2027-03-07T00:00:00Z"))
        #expect(LiveActivityPlanner.current(for: plan, now: at("2027-03-06T22:59:00Z")) == nil)
        // Wineglass Bay Lookout at 16:00 on 8 Mar is not booked.
        #expect(LiveActivityPlanner.current(for: plan, now: at("2027-03-08T04:30:00Z")) == nil)
    }

    @Test func skippingTheRowDropsItsActivityAndNextStartLooksAhead() throws {
        let plan = try plan()
        let now = at("2027-03-06T18:03:00Z")
        let current = try #require(LiveActivityPlanner.current(for: plan, now: now))
        #expect(LiveActivityPlanner.current(for: plan, now: now, skipped: [current.info.rowID]) == nil)
        // After EX 1501, the next one to start is the kayak tour's hour.
        #expect(LiveActivityPlanner.nextStart(for: plan, after: now) == at("2027-03-06T23:00:00Z"))
    }

    @Test func statesRoundTripAsPushContentState() throws {
        let json = #"{"phase":"boarding","target":1804360500,"departure":1804363200,"note":"Gate 23"}"#
        // A plain decoder, as ActivityKit uses: the times are still read as Unix seconds.
        let state = try JSONDecoder().decode(LiveActivityState.self, from: Data(json.utf8))
        #expect(state.phase == .boarding && state.note == "Gate 23")
        #expect(state.target == at("2027-03-06T19:15:00Z"))
        #expect(state.departure.timeIntervalSince(state.target) == 45 * 60)
        let again = try JSONDecoder().decode(LiveActivityState.self, from: JSONEncoder().encode(state))
        #expect(again == state)
    }

    /// What a push-to-start push carries as `attributes.info` (the companion builds it in Python).
    @Test func infoDecodesFromPushAttributes() throws {
        let json = #"{"tripID":"t","rowID":"r","kind":"flight","eyebrow":"Connection · SYD","title":"EX 1501 to Hobart","zoneIdentifier":"Australia/Sydney","windowStart":1804352400}"#
        let info = try JSONDecoder().decode(LiveActivityInfo.self, from: Data(json.utf8))
        #expect(info.windowStart == at("2027-03-06T17:00:00Z") && info.detail == nil)
        #expect(try JSONDecoder().decode(LiveActivityInfo.self, from: JSONEncoder().encode(info)) == info)
    }

    @Test func airportNamesBecomeCities() {
        #expect(LiveActivityPlanner.city("Hobart Airport (HBA)") == "Hobart")
        #expect(LiveActivityPlanner.city("Los Angeles International Airport (LAX)") == "Los Angeles")
        #expect(LiveActivityPlanner.city("Gatwick") == "Gatwick")
        #expect(LiveActivityPlanner.city("  ") == nil)
    }
}

@Suite("Live Activity push payloads")
struct LiveActivityPayloadTests {
    struct Payload: Decodable {
        struct APS: Decodable {
            let event: String
            let timestamp: Int
            let contentState: LiveActivityState

            enum CodingKeys: String, CodingKey { case event, timestamp, contentState = "content-state" }
        }
        let aps: APS
    }

    /// Every file in Fixtures/live-activity decodes into the state the widget draws.
    @Test func everyPayloadDecodes() throws {
        let folder = Fixture.root.appending(path: "Fixtures").appending(path: "live-activity")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path()).filter { $0.hasSuffix(".apns") }.sorted()
        #expect(files.count == 5)
        var phases: [LiveActivityState.Phase] = []
        for file in files {
            let payload = try JSONDecoder().decode(Payload.self, from: Data(contentsOf: folder.appending(path: file)))
            #expect(["update", "end"].contains(payload.aps.event), "\(file)")
            #expect(payload.aps.contentState.departure >= payload.aps.contentState.target, "\(file)")
            phases.append(payload.aps.contentState.phase)
        }
        #expect(Set(phases) == [.upcoming, .boarding, .cancelled])
    }
}
