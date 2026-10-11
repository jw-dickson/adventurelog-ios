// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import XCTest

/// Stage 2 with no server: Today, and edits that are kept on the phone until the server can be
/// reached. The seeded (synthetic) trip, at 18:00 on Mon 8 Mar 2027 in Tasmania.
@MainActor
final class OfflineEditingUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    private func openTripDay(_ app: XCUIApplication) {
        app.tabBars.buttons["Trip"].tap()
        XCTAssertTrue(app.staticTexts["day.title"].waitForExistence(timeout: 15))
    }

    func testTodayShowsTheCruiseNextAndSkipMovesOn() throws {
        let app = try OfflineBrowseUITests.launchOffline()

        // Today is the first tab.
        let title = app.staticTexts["today.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "D2 · Hobart → Freycinet")
        XCTAssertTrue(element(app, containing: "Day 4 of 19").exists)
        XCTAssertEqual(app.staticTexts["today.next.title"].label, "Sunset cruise")
        let label = app.staticTexts["today.next.label"]
        XCTAssertTrue(label.label.localizedCaseInsensitiveContains("in 30 min"), label.label)
        XCTAssertTrue(app.staticTexts["today.next.leave"].label.contains("Leave by"), "leave-by from the lookout")

        // Skip: nothing else is ahead today, and the cruise moves to Earlier.
        app.buttons["today.skip"].tap()
        XCTAssertTrue(app.staticTexts["today.next.title"].waitForNonExistence(timeout: 5))
        let cruise = element(app, containing: "Sunset cruise")
        XCTAssertTrue(cruise.waitForExistence(timeout: 5))

        // Undo from the row's menu.
        cruise.press(forDuration: 1.0)
        let undo = app.buttons["Undo skip"]
        XCTAssertTrue(undo.waitForExistence(timeout: 5))
        undo.tap()
        XCTAssertTrue(app.staticTexts["today.next.title"].waitForExistence(timeout: 5))
    }

    func testTodayOffersRemindersOnceAndSettingsOpen() throws {
        let app = try OfflineBrowseUITests.launchOffline()
        XCTAssertTrue(app.staticTexts["today.title"].waitForExistence(timeout: 15))
        let offer = app.descendants(matching: .any)["reminders.offer"]
        if !offer.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(offer.waitForExistence(timeout: 5))
        app.buttons["Not now"].tap()
        XCTAssertTrue(offer.waitForNonExistence(timeout: 5))

        // Settings, from the account menu; turning them on would ask for permission, so stop here.
        let account = app.navigationBars["Today"].buttons["Account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        account.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Reminders"].tap()
        let toggle = app.switches["reminders.enabled"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0")
    }

    func testTickingAChecklistItemIsKeptUntilTheServerIsBack() throws {
        let app = try OfflineBrowseUITests.launchOffline()
        openTripDay(app)

        element(app, containing: "Car pickup").tap()
        XCTAssertTrue(app.staticTexts["item.title"].waitForExistence(timeout: 5))
        let spare = app.buttons["checklist.item.Check the spare tyre"]
        XCTAssertTrue(spare.waitForExistence(timeout: 5))
        XCTAssertEqual(spare.value as? String, "Not done")
        spare.tap()
        XCTAssertEqual(spare.value as? String, "Done")
        XCTAssertTrue(app.descendants(matching: .any)["item.waiting"].waitForExistence(timeout: 5))

        // The day says a change is waiting.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let waiting = app.descendants(matching: .any)["sync.waiting"]
        if !waiting.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
        XCTAssertTrue(waiting.label.contains("1 change waiting to sync") || waiting.label.contains("Saving"), waiting.label)

        // Signing out now warns that the change would be lost.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Today has an Account button too; use the one on the screen in front.
        let account = app.navigationBars["Trips"].buttons["Account"]
        XCTAssertTrue(account.waitForExistence(timeout: 5))
        // A toolbar menu can't be "scrolled to visible", so tap where it is.
        account.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        app.buttons["Sign out"].tap()
        XCTAssertTrue(element(app, containing: "1 change hasn't synced").waitForExistence(timeout: 5))
    }

    func testEditingANoteOffline() throws {
        let app = try OfflineBrowseUITests.launchOffline()
        openTripDay(app)
        app.segmentedControls["trip.scope"].buttons["Whole trip"].tap()
        element(app, containing: "Trip essentials").tap()
        XCTAssertTrue(app.staticTexts["item.title"].waitForExistence(timeout: 5))

        app.buttons["note.edit"].tap()
        let editor = app.textViews["note.editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\nPick up the hire car before 10.")
        app.buttons["note.save"].tap()

        XCTAssertTrue(element(app, containing: "Pick up the hire car before 10.").waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["item.waiting"].exists)
    }

    func testMovingARowToAnotherDay() throws {
        let app = try OfflineBrowseUITests.launchOffline()
        openTripDay(app)

        app.buttons["trip.reorder"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["reorder.sheet"].waitForExistence(timeout: 5))
        app.buttons["reorder.move.Sunset cruise"].tap()
        let day1 = app.buttons["move.to.2027-03-07"]
        XCTAssertTrue(day1.waitForExistence(timeout: 5))
        day1.tap()
        XCTAssertTrue(app.buttons["reorder.move.Sunset cruise"].waitForNonExistence(timeout: 5), "gone from 8 Mar")
        app.buttons["Done"].tap()

        // On the previous day now, and waiting to sync.
        app.buttons["day.2027-03-07"].tap()
        XCTAssertTrue(element(app, containing: "Sunset cruise").waitForExistence(timeout: 5))
        let waiting = app.descendants(matching: .any)["sync.waiting"]
        if !waiting.waitForExistence(timeout: 3) { app.swipeUp() }
        XCTAssertTrue(waiting.waitForExistence(timeout: 5))
    }
}
