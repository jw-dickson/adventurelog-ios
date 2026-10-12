// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

/// Golden scenarios for the replan planner, on an afternoon at Freycinet (synthetic, like the
/// fixture trip: Mon 8 Mar 2027, AEDT, sunset about 19:41).
@Suite("Replan")
struct ReplanTests {
    let hobart = TimeZone(identifier: "Australia/Hobart")!
    let day = CalendarDate("2027-03-08")!
    let nextDate = CalendarDate("2027-03-09")!

    // Places a few minutes' drive apart.
    let carPark = ItemSummary.Coordinate(-42.120, 148.300)!
    let tourville = ItemSummary.Coordinate(-42.120, 148.340)!
    let lookout = ItemSummary.Coordinate(-42.150, 148.290)!
    let honeymoon = ItemSummary.Coordinate(-42.160, 148.300)!
    let tourBase = ItemSummary.Coordinate(-42.125, 148.300)!

    func time(_ hour: Int, _ minute: Int = 0, on date: CalendarDate? = nil) -> Date {
        (date ?? day).startOfDay(in: hobart).addingTimeInterval(Double(hour * 3600 + minute * 60))
    }

    func place(_ id: String, _ title: String, _ start: (Int, Int), _ end: (Int, Int), at point: ItemSummary.Coordinate,
               booked: Bool = false) -> Replan.Stop {
        Replan.Stop(rowID: "row-" + id, itemID: id, title: title, kind: .location, start: time(start.0, start.1),
                    end: time(end.0, end.1), zone: hobart, isBooked: booked, coordinate: point)
    }

    var afternoon: [Replan.Stop] {
        [place("walk", "Cape Tourville walk", (16, 0), (17, 0), at: tourville),
         place("lookout", "Wineglass Bay Lookout", (17, 15), (18, 15), at: lookout),
         place("bay", "Honeymoon Bay", (18, 30), (19, 15), at: honeymoon),
         place("tour", "Night wildlife tour", (21, 0), (22, 30), at: tourBase, booked: true)]
    }

    var nextDay: Replan.NextDay {
        Replan.NextDay(date: nextDate, firstStart: time(11, 0, on: nextDate), firstTitle: "Drive to Bicheno", zone: hobart)
    }

    func situation(_ stops: [Replan.Stop], delay: Int, now: Date? = nil, nextDay: Replan.NextDay? = nil) -> Replan.Situation {
        Replan.Situation(date: day, now: now ?? stops[0].start.addingTimeInterval(Double(delay * 60)), stops: stops,
                         delayMinutes: delay, nextDay: nextDay, zone: hobart)
    }

    func times(_ proposal: Replan.Proposal, _ rowID: String) -> (start: Date, end: Date)? {
        for change in proposal.changes {
            if case .retime(rowID, let start, let end, _) = change { return (start, end) }
        }
        return nil
    }

    func check(_ proposal: Replan.Proposal, _ situation: Replan.Situation) -> [ReplanCheck.Problem] {
        ReplanCheck.problems(proposal, situation: situation, tripDays: [day, nextDate])
    }

    // MARK: Golden scenarios

    @Test func aFewMinutesLateChangesNothing() {
        let s = situation(afternoon, delay: 3)
        let proposal = ReplanPlanner.propose(s)
        #expect(proposal.behindMinutes == 0)
        #expect(!proposal.changesSomething)
        #expect(proposal.headline == "You're on time")
        #expect(proposal.changes == [.keep(rowID: "row-tour")])
    }

    @Test func slackInThePlanAbsorbsTheDelay() {
        // An hour's gap after the walk: 20 minutes late for it costs nothing later.
        let stops = [place("walk", "Cape Tourville walk", (14, 0), (15, 0), at: tourville),
                     place("lookout", "Wineglass Bay Lookout", (16, 15), (17, 0), at: lookout)]
        let s = situation(stops, delay: 20)
        let proposal = ReplanPlanner.propose(s)
        #expect(proposal.behindMinutes == 20)
        let walk = times(proposal, "row-walk")
        #expect(walk?.start == time(14, 20) && walk?.end == time(15, 20))
        #expect(times(proposal, "row-lookout") == nil, "the lookout keeps its time")
        #expect(check(proposal, s).isEmpty)
    }

    @Test func everythingShiftsLaterWhenThereIsRoom() {
        let stops = [place("walk", "Cape Tourville walk", (10, 0), (11, 0), at: tourville),
                     place("lookout", "Wineglass Bay Lookout", (11, 10), (12, 0), at: lookout)]
        let s = situation(stops, delay: 30)
        let proposal = ReplanPlanner.propose(s)
        let walk = times(proposal, "row-walk")
        let lookout = times(proposal, "row-lookout")
        #expect(walk?.start == time(10, 30) && walk?.end == time(11, 30))
        // 10 minutes' drive after the walk (5.3 km).
        #expect(lookout?.start == time(11, 40) && lookout?.end == time(12, 30))
        #expect(!proposal.summary.isEmpty)
        #expect(check(proposal, s).isEmpty)
    }

    @Test func anEveningPlaceThatOnlyMovesLaterStillSaysSo() {
        // Nothing booked, and the cruise ends after dark anyway: the sentence names what moves.
        let s = situation([place("cruise", "Sunset cruise", (18, 30), (20, 30), at: honeymoon)], delay: 45)
        let proposal = ReplanPlanner.propose(s)
        #expect(times(proposal, "row-cruise")?.start == time(19, 15))
        #expect(proposal.summary == "Sunset cruise starts later.")
    }

    @Test func theMockupDayKeepsTheTourAndDaylight() throws {
        // 48 minutes behind at the walk: the tour is booked, Honeymoon Bay was planned for daylight.
        let s = situation(afternoon, delay: 48, nextDay: nextDay)
        let proposal = ReplanPlanner.propose(s)
        #expect(proposal.headline == "You're 48 min behind")
        #expect(proposal.changes.first == .keep(rowID: "row-tour"), "booked items come first")
        #expect(proposal.lateFor == nil)
        #expect(check(proposal, s).isEmpty, "\(check(proposal, s))")

        let sunset = try #require(SunTimes.sunset(on: day, latitude: honeymoon.latitude, longitude: honeymoon.longitude, zone: hobart))
        if let bay = times(proposal, "row-bay") {
            #expect(bay.end <= sunset, "Honeymoon Bay still ends before sunset")
        }
        // Nothing booked moves, and every place starts no earlier than planned.
        for change in proposal.changes {
            if case .retime(let id, let start, _, _) = change {
                let stop = try #require(afternoon.first { $0.rowID == id })
                #expect(!stop.isBooked)
                #expect(start >= stop.start)
            }
        }
        #expect(proposal.summary.contains("This keeps Night wildlife tour"))
    }

    @Test func aBookedItemMakesRoomByShortening() {
        // Two places then a booked cruise; 40 minutes late. Shortening the places is enough.
        let stops = [place("walk", "Cape Tourville walk", (14, 0), (15, 30), at: tourville),
                     place("lookout", "Wineglass Bay Lookout", (15, 40), (16, 40), at: lookout),
                     place("cruise", "Sunset cruise", (17, 0), (18, 30), at: honeymoon, booked: true)]
        let s = situation(stops, delay: 40)
        let proposal = ReplanPlanner.propose(s)
        #expect(proposal.lateFor == nil)
        let lookout = times(proposal, "row-lookout")
        // At the cruise 10 minutes early: the lookout ends by 16:50 minus the drive.
        #expect(lookout.map { $0.end <= time(16, 45) } == true)
        #expect(!proposal.changes.contains { if case .move = $0 { return true }; if case .skip = $0 { return true }; return false })
        #expect(check(proposal, s).isEmpty, "\(check(proposal, s))")
    }

    @Test func whenShorteningIsntEnoughTheLongestPlaceMovesToTomorrowMorning() {
        let stops = [place("walk", "Cape Tourville walk", (14, 0), (16, 0), at: tourville),
                     place("lookout", "Wineglass Bay Lookout", (16, 10), (16, 40), at: lookout),
                     place("cruise", "Sunset cruise", (17, 0), (18, 30), at: honeymoon, booked: true)]
        let s = situation(stops, delay: 90, nextDay: nextDay)
        let proposal = ReplanPlanner.propose(s)
        #expect(proposal.changes.contains(.move(rowID: "row-walk", date: nextDate, start: time(8, 0, on: nextDate),
                                                end: time(10, 0, on: nextDate), reason: "Before Drive to Bicheno")))
        #expect(proposal.summary.contains("Cape Tourville walk moves to tomorrow."))
        #expect(proposal.lateFor == nil)
        #expect(check(proposal, s).isEmpty, "\(check(proposal, s))")
    }

    @Test func onTheLastDayAPlaceIsLeftOutInstead() {
        let stops = [place("walk", "Cape Tourville walk", (14, 0), (16, 0), at: tourville),
                     place("cruise", "Sunset cruise", (17, 0), (18, 30), at: honeymoon, booked: true)]
        let s = situation(stops, delay: 120, nextDay: nil)
        let proposal = ReplanPlanner.propose(s)
        #expect(proposal.changes.contains(.skip(rowID: "row-walk", reason: "No time left today")))
        #expect(proposal.summary.contains("Cape Tourville walk is left out today."))
        #expect(check(proposal, s).isEmpty)
    }

    @Test func aMorningTooShortForThePlaceMeansLeavingItOut() {
        let stops = [place("walk", "Cape Tourville walk", (14, 0), (17, 0), at: tourville),
                     place("cruise", "Sunset cruise", (17, 30), (18, 30), at: honeymoon, booked: true)]
        let early = Replan.NextDay(date: nextDate, firstStart: time(9, 0, on: nextDate), firstTitle: "Ferry", zone: hobart)
        let proposal = ReplanPlanner.propose(situation(stops, delay: 200, nextDay: early))
        #expect(proposal.changes.contains(.skip(rowID: "row-walk", reason: "No time left today")))
    }

    @Test func nothingLeftToChangeSaysWhichBookedItemYoullBeLateFor() {
        let stops = [place("cruise", "Sunset cruise", (17, 0), (18, 30), at: honeymoon, booked: true)]
        let s = situation(stops, delay: 25)
        let proposal = ReplanPlanner.propose(s)
        #expect(proposal.lateFor == "Sunset cruise" && proposal.lateRowID == "row-cruise")
        #expect(proposal.lateMinutes == 25, "minutes after it starts, not counting the buffer")
        #expect(proposal.summary.contains("Even so, you'd reach Sunset cruise about 25 min late."))
        #expect(!proposal.changesSomething)
    }

    @Test func aDaylightPlaceIsntPushedPastSunset() throws {
        let stops = [place("bay", "Honeymoon Bay", (18, 30), (19, 30), at: honeymoon)]
        let s = situation(stops, delay: 20, nextDay: nextDay)
        let proposal = ReplanPlanner.propose(s)
        let sunset = try #require(SunTimes.sunset(on: day, latitude: honeymoon.latitude, longitude: honeymoon.longitude, zone: hobart))
        let bay = try #require(times(proposal, "row-bay"))
        #expect(bay.start == time(18, 50))
        #expect(bay.end <= sunset && bay.end >= time(19, 30), "shortened to end by sunset")
        #expect(proposal.summary.contains("gets you to Honeymoon Bay before sunset"))
    }

    @Test func aDaylightPlaceTooShortBeforeSunsetMovesToTomorrow() {
        // 45 minutes late leaves under half an hour of light: better tomorrow morning.
        let stops = [place("bay", "Honeymoon Bay", (18, 30), (19, 30), at: honeymoon)]
        let proposal = ReplanPlanner.propose(situation(stops, delay: 45, nextDay: nextDay))
        #expect(proposal.changes == [.move(rowID: "row-bay", date: nextDate, start: time(8, 0, on: nextDate),
                                           end: time(9, 0, on: nextDate), reason: "Before Drive to Bicheno")])
    }

    @Test func movingAPlaceUndoesShorteningThatIsNoLongerNeeded() {
        let stops = [place("walk", "Cape Tourville walk", (14, 0), (16, 0), at: tourville),
                     place("lookout", "Wineglass Bay Lookout", (16, 10), (16, 40), at: lookout),
                     place("cruise", "Sunset cruise", (17, 0), (18, 30), at: honeymoon, booked: true)]
        let proposal = ReplanPlanner.propose(situation(stops, delay: 90, nextDay: nextDay))
        #expect(times(proposal, "row-lookout") == nil, "the lookout keeps its full half hour")
    }

    @Test func anEveningPlaceMayRunAfterDarkButNotPast23() {
        let stops = [place("pub", "Dinner in Coles Bay", (20, 0), (21, 30), at: carPark),
                     place("stars", "Stargazing", (21, 45), (22, 45), at: honeymoon)]
        let proposal = ReplanPlanner.propose(situation(stops, delay: 30, nextDay: nextDay))
        if let stars = times(proposal, "row-stars") {
            #expect(stars.end <= time(23, 0))
        }
        #expect(proposal.lateFor == nil)
    }

    @Test func aJourneyMovesInTimeButIsNeverShortened() {
        let drive = Replan.Stop(rowID: "row-drive", itemID: "drive", title: "Drive to Bicheno", kind: .transportation,
                                start: time(15, 0), end: time(16, 0), zone: hobart, isBooked: false,
                                coordinate: carPark, destination: ItemSummary.Coordinate(-41.87, 148.30))
        let stops = [drive, place("blowhole", "Bicheno Blowhole", (16, 15), (17, 0), at: ItemSummary.Coordinate(-41.88, 148.31)!)]
        let proposal = ReplanPlanner.propose(situation(stops, delay: 30))
        let moved = times(proposal, "row-drive")
        #expect(moved?.start == time(15, 30) && moved?.end == time(16, 30))
    }

    @Test func aPositionGivesTheDelayAndTheStartingPoint() {
        // At the car park at 16:20, the walk 4 km away was due at 16:00.
        let walk = afternoon[0]
        let delay = Replan.delay(now: time(16, 20), position: carPark, target: walk)
        #expect(delay == 30, "20 minutes plus a 10-minute drive (3.3 km)")
        let s = Replan.Situation(date: day, now: time(16, 20), stops: afternoon, delayMinutes: delay, position: carPark,
                                 nextDay: nextDay, zone: hobart)
        let proposal = ReplanPlanner.propose(s)
        #expect(times(proposal, "row-walk")?.start == time(16, 30))
        #expect(check(proposal, s).isEmpty)
    }

    @Test func stopsAreTakenInTimeOrderWhateverTheRowOrder() {
        // The booked dinner's row sits above the afternoon walk.
        let stops = [place("dinner", "Dinner", (19, 0), (20, 30), at: honeymoon, booked: true),
                     place("walk", "Cape Tourville walk", (15, 0), (16, 0), at: tourville)]
        let s = situation(stops, delay: 20, now: time(15, 20))
        let proposal = ReplanPlanner.propose(s)
        #expect(times(proposal, "row-walk")?.start == time(15, 20))
        #expect(proposal.lateFor == nil)
        #expect(!proposal.changes.contains(.skip(rowID: "row-walk", reason: "No time left today")))
    }

    @Test func aBookedTourWithLunchInsideKeepsTheLunch() {
        // A short place, then a booked day tour with a lunch stop inside it.
        let stops = [place("cafe", "Coffee in Coles Bay", (8, 0), (8, 45), at: tourville),
                     place("tour", "Day tour", (9, 0), (17, 0), at: tourBase, booked: true),
                     place("lunch", "Lunch at the beach", (12, 0), (13, 0), at: honeymoon),
                     place("bay", "Honeymoon Bay", (17, 30), (18, 30), at: honeymoon)]
        let s = situation(stops, delay: 10, nextDay: nextDay)
        let proposal = ReplanPlanner.propose(s)
        #expect(times(proposal, "row-lunch") == nil, "lunch inside the tour keeps its time")
        #expect(times(proposal, "row-bay") == nil)
        #expect(proposal.lateFor == nil)
        #expect(times(proposal, "row-cafe").map { $0.end <= time(8, 45) } == true, "coffee gives way for the tour")
        #expect(check(proposal, s).isEmpty, "\(check(proposal, s))")
    }

    @Test func tightnessThePlanAlreadyHadIsntTheDelaysFault() {
        // A morning walk 10 minutes late, and an evening that was already tight by the estimate:
        // museum until 18:45, a booked dinner at 19:00 a 10-minute drive away.
        let stops = [place("walk", "Cape Tourville walk", (10, 0), (11, 0), at: carPark),
                     place("museum", "Museum", (18, 0), (18, 45), at: lookout),
                     place("dinner", "Dinner", (19, 0), (20, 30), at: tourville, booked: true)]
        let proposal = ReplanPlanner.propose(situation(stops, delay: 10))
        #expect(times(proposal, "row-museum") == nil, "the museum isn't cut")
        #expect(proposal.lateFor == nil)
    }

    @Test func aLateJourneyWithNothingToGiveWaySaysSoAndStillPasses() {
        let drive = Replan.Stop(rowID: "row-drive", itemID: "drive", title: "Drive to Bicheno", kind: .transportation,
                                start: time(17, 0), end: time(19, 0), zone: hobart, isBooked: false,
                                coordinate: carPark, destination: ItemSummary.Coordinate(-41.87, 148.30))
        let dinner = place("dinner", "Dinner in Bicheno", (20, 0), (21, 30), at: ItemSummary.Coordinate(-41.871, 148.301)!, booked: true)
        let s = situation([drive, dinner], delay: 75)
        let proposal = ReplanPlanner.propose(s)
        #expect(times(proposal, "row-drive")?.start == time(18, 15))
        #expect(proposal.lateRowID == "row-dinner" && proposal.lateMinutes == 15)
        #expect(proposal.summary.contains("about 15 min late"))
        #expect(!proposal.summary.contains("This keeps Dinner"))
        #expect(check(proposal, s).isEmpty, "the late dinner's overlap is expected: \(check(proposal, s))")
    }

    @Test func sunsetIsOnTheRightDayFarEastOfGreenwich() throws {
        // Tonga is UTC+13: noon there is still yesterday in UTC.
        let tonga = TimeZone(identifier: "Pacific/Tongatapu")!
        let sunset = try #require(SunTimes.sunset(on: day, latitude: -21.14, longitude: -175.2, zone: tonga))
        #expect(TripTime.localDate(of: sunset, in: tonga) == day)
        let clock = TripTime.clock(of: sunset, in: tonga)
        #expect(clock.hour == 19 && (0...7).contains(clock.minute))
    }

    @Test func dayEndFollowsDaylightSaving() {
        // 5 Apr 2026: Hobart goes back from AEDT to AEST at 03:00.
        let changeover = CalendarDate("2026-04-05")!
        let end = Replan.clock(23, on: changeover, in: hobart)
        let clock = TripTime.clock(of: end, in: hobart)
        #expect(clock.hour == 23 && clock.minute == 0)
    }

    // MARK: The checker

    @Test func theCheckerRejectsMovingABookedItem() {
        let s = situation(afternoon, delay: 30, nextDay: nextDay)
        let bad = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .retime(rowID: "row-tour", start: time(21, 30), end: time(23, 0), reason: nil)])
        #expect(check(bad, s) == [.changesBooked("Night wildlife tour")])
        let skip = Replan.Proposal(behindMinutes: 30, summary: "", changes: [.skip(rowID: "row-tour", reason: nil)])
        #expect(check(skip, s) == [.changesBooked("Night wildlife tour")])
    }

    @Test func theCheckerRejectsWhatItCantPlace() {
        let s = situation(afternoon, delay: 30, nextDay: nextDay)
        let changes: [Replan.Change] = [
            .retime(rowID: "row-nope", start: time(17, 0), end: time(18, 0), reason: nil),
            .retime(rowID: "row-walk", start: time(17, 0), end: time(16, 0), reason: nil),
            .retime(rowID: "row-lookout", start: time(12, 0), end: time(13, 0), reason: nil),
            .move(rowID: "row-bay", date: CalendarDate("2027-03-20")!, start: time(8, 0, on: CalendarDate("2027-03-20")!),
                  end: time(9, 0, on: CalendarDate("2027-03-20")!), reason: nil),
            .add(title: " ", content: "", date: day, reason: nil),
        ]
        let problems = check(Replan.Proposal(behindMinutes: 30, summary: "", changes: changes), s)
        #expect(problems.contains(.unknownRow("row-nope")))
        #expect(problems.contains(.endNotAfterStart("Cape Tourville walk")))
        #expect(problems.contains(.startsInThePast("Wineglass Bay Lookout")))
        #expect(problems.contains(.notALaterTripDay("Honeymoon Bay")))
        #expect(problems.contains(.blankTitle))
    }

    @Test func aClaimedLateItemOnlyExcusesTheLatenessItStates() {
        let s = situation(afternoon, delay: 30, nextDay: nextDay)
        // Running into the tour by 15 minutes, as stated: allowed.
        let stated = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .retime(rowID: "row-bay", start: time(20, 0), end: time(21, 5), reason: nil)],
            lateFor: "Night wildlife tour", lateRowID: "row-tour", lateMinutes: 5)
        #expect(check(stated, s).isEmpty)
        // Sitting on top of the tour isn't, whatever the proposal claims.
        let over = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .retime(rowID: "row-bay", start: time(20, 30), end: time(22, 30), reason: nil)],
            lateFor: "Night wildlife tour", lateRowID: "row-tour", lateMinutes: 5)
        #expect(check(over, s) == [.overlap("Honeymoon Bay", "Night wildlife tour")])
        // Nor is a row claimed late that isn't booked.
        let notBooked = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .retime(rowID: "row-lookout", start: time(18, 0), end: time(18, 45), reason: nil)],
            lateRowID: "row-bay", lateMinutes: 60)
        #expect(check(notBooked, s) == [.overlap("Wineglass Bay Lookout", "Honeymoon Bay")])
    }

    @Test func theCheckerHoldsJourneysAndTheDaysEnd() {
        let drive = Replan.Stop(rowID: "row-drive", itemID: "drive", title: "Drive to Bicheno", kind: .transportation,
                                start: time(15, 0), end: time(16, 0), zone: hobart, isBooked: false, coordinate: carPark)
        let s = situation([drive] + afternoon, delay: 30, now: time(15, 0), nextDay: nextDay)
        let shorter = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .retime(rowID: "row-drive", start: time(15, 30), end: time(16, 0), reason: nil)])
        #expect(check(shorter, s) == [.changesJourney("Drive to Bicheno")])
        let moved = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .move(rowID: "row-drive", date: nextDate, start: time(8, 0, on: nextDate), end: time(9, 0, on: nextDate), reason: nil)])
        #expect(check(moved, s) == [.changesJourney("Drive to Bicheno")])
        let late = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .retime(rowID: "row-bay", start: time(22, 45), end: time(23, 30), reason: nil)])
        #expect(check(late, s) == [.endsTooLate("Honeymoon Bay")])
    }

    @Test func theCheckerRejectsOverlapsAndDuplicates() {
        let s = situation(afternoon, delay: 30, nextDay: nextDay)
        let overlap = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .retime(rowID: "row-bay", start: time(20, 30), end: time(21, 30), reason: nil)])
        #expect(check(overlap, s) == [.overlap("Honeymoon Bay", "Night wildlife tour")])
        let twice = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .skip(rowID: "row-walk", reason: nil), .skip(rowID: "row-walk", reason: nil)])
        #expect(check(twice, s) == [.duplicate("Cape Tourville walk")])
        #expect(ReplanCheck.Problem.overlap("A", "B").message == "It puts A and B at the same time.")
    }

    // MARK: Wire format (the companion's)

    @Test func proposalsRoundTripAsJSON() throws {
        let proposal = Replan.Proposal(behindMinutes: 48, summary: "Keeps the tour.", changes: [
            .keep(rowID: "row-tour"),
            .retime(rowID: "row-bay", start: time(18, 45), end: time(19, 30), reason: "More light"),
            .move(rowID: "row-walk", date: nextDate, start: time(8, 0, on: nextDate), end: time(9, 0, on: nextDate), reason: nil),
            .skip(rowID: "row-lookout", reason: nil),
            .add(title: "Dinner at the campsite", content: "Rest before the tour", date: day, reason: "New"),
        ], source: .claude)
        let data = try JSONEncoder().encode(proposal)
        #expect(try JSONDecoder().decode(Replan.Proposal.self, from: data) == proposal)
    }

    @Test func companionJSONDecodes() throws {
        let json = """
        {"behindMinutes": 48, "summary": "Keeps the tour.", "source": "claude", "changes": [
          {"type": "keep", "rowID": "row-tour"},
          {"type": "retime", "rowID": "row-bay", "start": "2027-03-08T07:45:00Z", "end": "2027-03-08T08:30:00Z", "reason": " "},
          {"type": "add", "title": "Dinner", "date": "2027-03-08"}
        ]}
        """
        let proposal = try JSONDecoder().decode(Replan.Proposal.self, from: Data(json.utf8))
        #expect(proposal.changes[1] == .retime(rowID: "row-bay", start: time(18, 45), end: time(19, 30), reason: nil))
        #expect(proposal.changes[2] == .add(title: "Dinner", content: "", date: day, reason: nil))
        let unknown = #"{"behindMinutes": 1, "summary": "", "source": "claude", "changes": [{"type": "teleport", "rowID": "x"}]}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Replan.Proposal.self, from: Data(unknown.utf8)) }
    }

    // MARK: From the fixture trip

    @Test func stopsComeFromTodaysTimedPlacesAndJourneys() throws {
        let plan = TripPlan(try Fixture.trip(), fallbackTimeZone: hobart)
        // 10:00 AEDT on day 4: the drive, the stay, the lookout and the cruise are ahead.
        let today = try #require(TodayPlan(plan: plan, today: day, now: time(10, 0)))
        let stops = Replan.Situation.stops(in: today, now: time(10, 0))
        #expect(stops.map(\.title) == ["Drive Hobart → Freycinet", "Wineglass Bay Lookout", "Sunset cruise"],
                "no car hire (two weeks), no stay, no checklist")
        #expect(stops.allSatisfy { !$0.isBooked })
    }

    @Test func theSituationComesFromThePlanAndTheLastPosition() throws {
        let plan = TripPlan(try Fixture.trip(), fallbackTimeZone: hobart)
        // 18:40 at the lookout; the cruise (18:30) is a 10-minute drive away.
        let point = TrackPoint(time: time(18, 38), latitude: -42.15, longitude: 148.29)
        let s = try #require(Replan.Situation.current(plan: plan, today: day, now: time(18, 40), lastPoint: point))
        #expect(s.stops.map(\.title) == ["Sunset cruise"])
        #expect(s.delayMinutes == 20)
        #expect(s.position != nil)
        #expect(s.nextDay?.date == nextDate)

        // A position from half an hour ago says nothing; what the person says counts instead.
        let stale = TrackPoint(time: time(18, 10), latitude: -42.15, longitude: 148.29)
        #expect(Replan.Situation.current(plan: plan, today: day, now: time(18, 40), lastPoint: stale)?.delayMinutes == 0)
        let told = try #require(Replan.Situation.current(plan: plan, today: day, now: time(18, 40), lastPoint: point, reportedDelay: 45))
        #expect(told.delayMinutes == 45)
        #expect(told.position == nil)
    }

    @Test func atAStopYouAreThereUntilItEnds() throws {
        let plan = TripPlan(try Fixture.trip(), fallbackTimeZone: hobart)
        let today = try #require(TodayPlan(plan: plan, today: day, now: time(19, 0)))
        let cruise = try #require(today.entries.first { $0.summary.title == "Sunset cruise" })
        let at = try #require(cruise.summary.coordinate)
        // On the cruise at 19:00: nothing timed is left after it today.
        let point = TrackPoint(time: time(18, 59), latitude: at.latitude, longitude: at.longitude)
        #expect(Replan.Situation.current(plan: plan, today: day, now: time(19, 0), lastPoint: point) == nil)
    }

    @Test func atABookedTourTheRowsInsideItFollowFromItsStart() {
        // At the tour base at 09:10; lunch at 12:00 is inside the 09:00–17:00 tour.
        let tour = place("tour", "Day tour", (9, 0), (17, 0), at: tourBase, booked: true)
        let lunch = place("lunch", "Lunch at the beach", (12, 0), (13, 0), at: honeymoon)
        let inside = Replan.Situation.afterStop(tour, next: lunch, now: time(9, 10), position: tourBase)
        #expect(inside.delay == 0, "on time, not five hours behind")
        #expect(inside.startingPoint == tourBase)
        // After a place with nothing inside it, you're free when it ends.
        let walk = place("walk", "Cape Tourville walk", (16, 0), (17, 0), at: tourville)
        let after = Replan.Situation.afterStop(walk, next: afternoon[1], now: time(17, 10), position: tourville)
        #expect(after.delay == 5, "17:10 plus a 10-minute drive, for the 17:15 lookout")
    }

    @Test func linesReadLikeTheMockup() throws {
        let s = situation(afternoon, delay: 48, nextDay: nextDay)
        let proposal = Replan.Proposal(behindMinutes: 48, summary: "", changes: [
            .keep(rowID: "row-tour"),
            .move(rowID: "row-walk", date: nextDate, start: time(8, 0, on: nextDate), end: time(9, 0, on: nextDate), reason: "Before Drive to Bicheno"),
            .retime(rowID: "row-lookout", start: time(19, 0), end: time(19, 30), reason: nil),
            .retime(rowID: "row-bay", start: time(18, 45), end: time(19, 30), reason: "More light"),
            .skip(rowID: "row-nope", reason: nil),
            .add(title: "Dinner at the campsite", content: "", date: day, reason: "Rest before the tour"),
        ])
        let lines = ReplanText.lines(proposal, situation: s, locale: Locale(identifier: "en_GB"))
        #expect(lines.map(\.detail) == [
            "Booked · stays at 21:00",
            "Moved to tomorrow 8:00, before Drive to Bicheno",
            "60 → 30 min · 19:00–19:30",
            "18:30 → 18:45 · More light",
            "New · Today · Rest before the tour",
        ], "an unknown row is left out")
        #expect(lines.map(\.mark) == [.locked, .moved, .shortened, .moved, .added])
    }

    @Test func applyingTurnsChangesIntoEdits() throws {
        let plan = TripPlan(try Fixture.trip(), fallbackTimeZone: hobart)
        let today = try #require(TodayPlan(plan: plan, today: day, now: time(10, 0)))
        let cruise = try #require(today.entries.first { $0.summary.title == "Sunset cruise" })
        let lookout = try #require(today.entries.first { $0.summary.title == "Wineglass Bay Lookout" })
        let proposal = Replan.Proposal(behindMinutes: 30, summary: "", changes: [
            .retime(rowID: cruise.rowID, start: time(19, 0), end: time(21, 0), reason: nil),
            .move(rowID: lookout.rowID, date: nextDate, start: time(8, 0, on: nextDate), end: time(9, 0, on: nextDate), reason: nil),
            .skip(rowID: "row-gone", reason: nil),
            .add(title: "Dinner", content: "", date: day, reason: nil),
        ])
        let actions = ReplanApply.actions(for: proposal, plan: plan, today: day)
        #expect(actions.count == 3, "a row that isn't on today is left out")
        #expect(actions[0] == .retime(item: cruise.entry.item, start: time(19, 0), end: time(21, 0)))
        guard case .move(let entry, _, let date, let index, let start, _) = actions[1] else {
            Issue.record("expected a move")
            return
        }
        #expect(entry.row.id == lookout.rowID && date == nextDate && start == time(8, 0, on: nextDate))
        let tomorrow = try #require(plan.day(for: nextDate))
        #expect(index >= 0 && index <= tomorrow.entries.count)
        #expect(actions[2] == .addNote(title: "Dinner", content: "", date: day))

        // Two places moved to the same morning keep their order there.
        let both = Replan.Proposal(behindMinutes: 90, summary: "", changes: [
            .move(rowID: lookout.rowID, date: nextDate, start: time(8, 0, on: nextDate), end: time(9, 0, on: nextDate), reason: nil),
            .move(rowID: cruise.rowID, date: nextDate, start: time(9, 15, on: nextDate), end: time(11, 15, on: nextDate), reason: nil),
        ])
        let indices = ReplanApply.actions(for: both, plan: plan, today: day).compactMap { action -> Int? in
            if case .move(_, _, _, let index, _, _) = action { return index }
            return nil
        }
        #expect(indices.count == 2 && indices[1] > indices[0], "the 09:15 place goes after the 08:00 one")
    }

    // MARK: Sun

    @Test func sunsetAtFreycinetInMarch() throws {
        let sunset = try #require(SunTimes.sunset(on: day, latitude: -42.15, longitude: 148.29, zone: hobart))
        let clock = TripTime.clock(of: sunset, in: hobart)
        #expect(clock.hour == 19 && (38...44).contains(clock.minute))
        // West of Greenwich too: Edinburgh at midsummer, about 22:02 BST.
        let london = TimeZone(identifier: "Europe/London")!
        let june = try #require(SunTimes.sunset(on: CalendarDate("2026-06-21")!, latitude: 55.95, longitude: -3.19, zone: london))
        let edinburgh = TripTime.clock(of: june, in: london)
        #expect(edinburgh.hour == 22 && (0...5).contains(edinburgh.minute))
        #expect(SunTimes.sunset(on: CalendarDate("2026-06-21")!, latitude: 78.2, longitude: 15.6, zone: .gmt) == nil, "midnight sun")
    }
}
