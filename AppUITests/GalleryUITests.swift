// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import XCTest

/// Screenshots of every screen in light, dark and the largest accessibility text size, kept in the
/// test results for the design reviews (they sit beside Design/review-1 and Design/editing).
///
/// These check that each screen renders and holds its key content at every size; the pictures are
/// for people. Extract them with `make gallery`.
@MainActor
final class GalleryUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testLight() throws { try capture(variant: "light", ["-ALAppearance", "light"]) }

    func testDark() throws { try capture(variant: "dark", ["-ALAppearance", "dark"]) }

    func testAccessibilityXXL() throws {
        try capture(variant: "xxl", ["-ALAppearance", "light", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXL"])
    }

    private func capture(variant: String, _ arguments: [String]) throws {
        let app = try OfflineBrowseUITests.launchOffline(arguments, track: true, photos: true)

        XCTAssertTrue(app.staticTexts["today.title"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["today.next.title"].waitForExistence(timeout: 5))
        keep(app, "02-today-\(variant)")

        // Replan (review-1, 08), 45 minutes late when the phone has no recent position.
        let replan = app.buttons["today.replan"]
        XCTAssertTrue(replan.waitForExistence(timeout: 5))
        replan.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.staticTexts["replan.headline"].waitForExistence(timeout: 5))
        let late = app.buttons["replan.late.45"]
        XCTAssertTrue(late.waitForExistence(timeout: 5), "no recent position in the seed, so the sheet asks how late")
        late.tap()
        XCTAssertEqual(app.staticTexts["replan.headline"].label, "You're 45 min behind")
        sleep(1) // let the chip's selection settle
        keep(app, "08-replan-\(variant)")
        app.buttons["replan.close"].tap()
        XCTAssertTrue(app.staticTexts["replan.headline"].waitForNonExistence(timeout: 5))

        // Reminders and Live Activities settings, from the account menu.
        let account = app.navigationBars["Today"].buttons["Account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Reminders"].tap()
        XCTAssertTrue(app.switches["reminders.enabled"].waitForExistence(timeout: 5))
        keep(app, "10-reminders-\(variant)")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.staticTexts["today.title"].waitForExistence(timeout: 5))

        app.tabBars.buttons["Trip"].tap()
        XCTAssertTrue(app.staticTexts["day.title"].waitForExistence(timeout: 15))
        keep(app, "03-trip-day-\(variant)")

        // The travel day: Denver → Los Angeles → Sydney, with the clock changes on the timeline.
        showDay(app, "2027-03-05", from: "2027-03-08")
        let clock = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "clocks go")).firstMatch
        XCTAssertTrue(clock.waitForExistence(timeout: 5))
        keep(app, "03c-travel-day-\(variant)")
        showDay(app, "2027-03-08", from: "2027-03-05")

        let lookout = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Wineglass Bay Lookout")).firstMatch
        if !lookout.isHittable { app.swipeUp() }
        lookout.tap()
        XCTAssertTrue(app.staticTexts["item.title"].waitForExistence(timeout: 5))
        keep(app, "04-item-detail-\(variant)")

        // Editing (Design/editing): a quick note, then the place's details.
        app.buttons["item.addNote"].tap()
        XCTAssertTrue(app.textViews["quickNote.text"].waitForExistence(timeout: 5))
        keep(app, "e02-add-a-note-\(variant)")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textViews["quickNote.text"].waitForNonExistence(timeout: 5))
        app.buttons["item.edit"].tap()
        // A text view at the largest text sizes, where the name wraps.
        let name = app.descendants(matching: .any)["edit.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        keep(app, "e04-edit-place-\(variant)")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // A new note on the day, from the add menu.
        let add = app.buttons["trip.add"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let newNote = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "New note on")).firstMatch
        XCTAssertTrue(newNote.waitForExistence(timeout: 5))
        keep(app, "e07-add-to-day-\(variant)")
        newNote.tap()
        XCTAssertTrue(app.textFields["newNote.title"].waitForExistence(timeout: 5))
        keep(app, "e08-new-note-\(variant)")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["newNote.title"].waitForNonExistence(timeout: 5))

        app.segmentedControls["trip.scope"].buttons.element(boundBy: 1).tap()
        keep(app, "03b-whole-trip-\(variant)")
        app.segmentedControls["trip.scope"].buttons.element(boundBy: 0).tap()

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.descendants(matching: .any)["trips.list"].waitForExistence(timeout: 5))
        keep(app, "06-trips-\(variant)")

        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.map"].waitForExistence(timeout: 10))
        sleep(2) // let map tiles draw
        keep(app, "05-map-\(variant)")

        app.tabBars.buttons["Log"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["log.done"].waitForExistence(timeout: 10))
        keep(app, "07-log-\(variant)")

        app.terminate()
        let signIn = XCUIApplication()
        signIn.launchArguments = ["-ALResetState", "YES", "-ALServerURL", "adventurelog.example"] + arguments
        signIn.launch()
        XCTAssertTrue(signIn.descendants(matching: .any)["signin.server"].waitForExistence(timeout: 10))
        XCTAssertTrue(signIn.secureTextFields["signin.password"].exists)
        keep(signIn, "01-sign-in-\(variant)")
    }

    /// Taps a day in the date strip, scrolling the strip to it first if it's off screen.
    private func showDay(_ app: XCUIApplication, _ date: String, from current: String) {
        let tile = app.descendants(matching: .any)["day.\(date)"].firstMatch
        let here = app.descendants(matching: .any)["day.\(current)"].firstMatch
        for _ in 0..<4 where !tile.isHittable {
            if date < current { here.swipeRight() } else { here.swipeLeft() }
        }
        tile.tap()
        XCTAssertTrue(app.staticTexts["day.title"].waitForExistence(timeout: 5))
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
