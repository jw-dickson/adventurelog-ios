// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import XCTest

/// Stage 3's tracking exit check, offline: a recorded day (synthetic) shows against the plan on
/// the Log tab and the map, and Today asks once per trip before recording anything.
@MainActor
final class LogUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testARecordedDayShowsAgainstThePlan() throws {
        let app = try OfflineBrowseUITests.launchOffline(track: true)
        XCTAssertTrue(app.staticTexts["today.title"].waitForExistence(timeout: 15))
        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["log.view"].waitForExistence(timeout: 10))

        // 18:00 on the drive day: every planned stop visited (already at the cruise jetty).
        let done = app.descendants(matching: .any)["log.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        XCTAssertTrue(done.label.contains("5"), done.label)
        XCTAssertTrue(app.descendants(matching: .any)["log.driven"].label.contains("km"))
        XCTAssertTrue(element(app, containing: "Stayed 55 min").waitForExistence(timeout: 5), "The car hire")
        XCTAssertTrue(element(app, containing: "Unplanned stop").exists, "The stop on the way")
        let late = element(app, containing: "20 min later than planned")
        if !late.exists { app.swipeUp() }
        XCTAssertTrue(late.waitForExistence(timeout: 5), "The lookout")
        let gpx = app.buttons["log.gpx"]
        if !gpx.isHittable { app.swipeUp() }
        XCTAssertTrue(gpx.waitForExistence(timeout: 5))

        // The whole trip, day by day; a day opens its own log.
        // The swipes above scroll the picker under the header, where isHittable still says yes: go back to the top.
        app.swipeDown()
        app.segmentedControls["log.scope"].buttons["Trip"].tap()
        let day = app.buttons["log.day.2027-03-08"]
        XCTAssertTrue(day.waitForExistence(timeout: 5))
        XCTAssertTrue(day.label.contains("unplanned stop"), day.label)
        XCTAssertTrue(app.buttons["log.day.2027-03-07"].exists, "Earlier days show with no route")
        day.tap()
        XCTAssertTrue(element(app, containing: "Stayed 55 min").waitForExistence(timeout: 5))

        // Nothing is recorded until the person agrees.
        let tracking = app.switches["log.tracking"]
        XCTAssertTrue(tracking.exists)
        XCTAssertEqual(tracking.value as? String, "0")

        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.map"].waitForExistence(timeout: 10))
    }

    func testTodayAsksOnceBeforeRecording() throws {
        let app = try OfflineBrowseUITests.launchOffline()
        XCTAssertTrue(app.staticTexts["today.title"].waitForExistence(timeout: 15))
        let offer = app.descendants(matching: .any)["tracking.offer"]
        if !offer.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(offer.waitForExistence(timeout: 5))
        // Agreeing would ask for location permission, so decline here; the Log keeps the switch.
        // The card's identifier covers its buttons too, so tap by label (as the reminder offer's test does).
        app.buttons["No thanks"].tap()
        XCTAssertTrue(offer.waitForNonExistence(timeout: 5))

        app.tabBars.buttons["Log"].tap()
        let tracking = app.switches["log.tracking"]
        XCTAssertTrue(tracking.waitForExistence(timeout: 10))
        XCTAssertEqual(tracking.value as? String, "0")
        XCTAssertTrue(element(app, containing: "No route recorded yet today").exists)
    }
}
