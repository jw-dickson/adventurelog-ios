// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Reminders")
struct ReminderTests {
    let hobart = TimeZone(identifier: "Australia/Hobart")!
    let gb = Locale(identifier: "en_GB")

    func plan() throws -> TripPlan {
        TripPlan(try Fixture.trip(), fallbackTimeZone: hobart)
    }

    func at(_ iso: String) -> Date { ISO8601.parse(iso)! }

    func local(_ date: Date) -> String {
        let clock = TripTime.clock(of: date, in: hobart)
        return String(format: "%02d:%02d", clock.hour, clock.minute)
    }

    /// A local time on 8 Mar as the app shows it; the platform decides "9:00" or "09:00".
    func shown(_ clock: String) -> String {
        TripTime.shortTime(at("2027-03-08T\(clock):00+11:00"), in: hobart, locale: gb)
    }

    /// Mon 8 Mar from 07:00 in Tasmania: the drive day.
    @Test func theDriveDaysRemindersFallAtTheRightLocalTimes() throws {
        let reminders = ReminderPlanner.reminders(for: try plan(), now: at("2027-03-07T20:00:00Z"), locale: gb)
        let summary = reminders.map { "\(local($0.fireDate)) \($0.kind.rawValue) \($0.title)" }
        #expect(summary == [
            "08:45 headsUp Car hire (Hobart → Hobart) at \(shown("09:00"))",
            "10:30 leaveBy Leave by \(shown("10:30")) for Drive Hobart → Freycinet",
            "10:45 headsUp Drive Hobart → Freycinet at \(shown("11:00"))",
            "14:00 headsUp Bay Holiday Park at \(shown("15:00"))",          // booked: an hour ahead
            "15:50 leaveBy Leave by \(shown("15:50")) for Wineglass Bay Lookout", // its heads-up would be 5 min later: merged
            "18:15 leaveBy Leave by \(shown("18:15")) for Sunset cruise",
        ])
        #expect(reminders.first { $0.title.contains("Bay Holiday Park") }?.body == "Starts in 1 h · BHP-0042")
        #expect(reminders.first { $0.title.contains("Sunset cruise") }?.body == "About 10 min away · starts \(shown("18:30"))")
        #expect(Set(reminders.map(\.id)).count == reminders.count)
    }

    /// The exit check in miniature: step the clock through the day, recalculating each time as the
    /// app does, and every reminder fires exactly once, at its time.
    @Test func aReplayedDayFiresEachReminderOnce() throws {
        let plan = try plan()
        let expected = Set(ReminderPlanner.reminders(for: plan, now: at("2027-03-07T13:00:00Z")).map(\.id))
        var fired: [String: Date] = [:]
        var previous = at("2027-03-07T13:00:00Z")
        while previous < at("2027-03-08T13:00:00Z") {
            let now = previous.addingTimeInterval(15 * 60)
            for reminder in ReminderPlanner.reminders(for: plan, now: previous) where reminder.fireDate <= now {
                #expect(fired[reminder.id] == nil, "\(reminder.title) fired twice")
                fired[reminder.id] = reminder.fireDate
            }
            previous = now
        }
        #expect(Set(fired.keys) == expected)
        #expect(fired.count == 6)
    }

    @Test func flightsGetAnEarlierHeadsUp() throws {
        let reminders = ReminderPlanner.reminders(for: try plan(), now: at("2027-03-06T12:00:00Z"), locale: gb)
        let flight = try #require(reminders.first { $0.title.hasPrefix("Example Air EX 1501") })
        #expect(flight.kind == .headsUp)
        #expect(local(flight.fireDate) == "04:00", "three hours before the 07:00 departure")
        #expect(flight.body == "Departs in 3 h · EX1501")
        // The booked kayak tour is 340 m from the museum before it: leave-by, plus the hour's heads-up.
        let kayak = reminders.filter { $0.title.contains("Harbour kayak tour") }.map(\.kind)
        #expect(kayak == [.headsUp, .leaveBy])
    }

    @Test func skippedRowsAndSettingsAreRespected() throws {
        let plan = try plan()
        let now = at("2027-03-08T05:40:00Z")
        let cruise = try #require(plan.day(for: CalendarDate("2027-03-08")!)?.entries.last)
        #expect(ReminderPlanner.reminders(for: plan, now: now).map(\.itemID) == [cruise.item.id])
        #expect(ReminderPlanner.reminders(for: plan, now: now, skipped: [cruise.row.id]).isEmpty)

        var settings = ReminderSettings()
        settings.leaveBy = false
        let headsUp = ReminderPlanner.reminders(for: plan, now: now, settings: settings, locale: gb)
        #expect(headsUp.map(\.title) == ["Sunset cruise at 18:30"], "without a leave-by, the heads-up comes back")
        settings.headsUp = false
        #expect(ReminderPlanner.reminders(for: plan, now: now, settings: settings).isEmpty)
    }

    @Test func onlyTheNextTwoDaysAndUnderTheLimit() throws {
        let plan = try plan()
        let now = at("2027-03-04T00:00:00Z")
        let reminders = ReminderPlanner.reminders(for: plan, now: now)
        #expect(reminders.allSatisfy { $0.fireDate > now && $0.fireDate <= now.addingTimeInterval(ReminderPlanner.window) })
        #expect(reminders.count <= ReminderPlanner.limit)
        #expect(reminders == reminders.sorted { $0.fireDate < $1.fireDate })
        #expect(ReminderPlanner.reminders(for: plan, now: at("2027-04-01T00:00:00Z")).isEmpty)
    }
}
