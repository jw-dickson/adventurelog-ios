// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import XCTest

/// Screenshots of every Stage 1 screen in light, dark and the largest accessibility text size,
/// kept in the test results for design review 2 (they sit beside Design/review-1).
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
        let app = try OfflineBrowseUITests.launchOffline(arguments)

        XCTAssertTrue(app.staticTexts["day.title"].waitForExistence(timeout: 15))
        keep(app, "03-trip-day-\(variant)")

        let lookout = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Wineglass Bay Lookout")).firstMatch
        if !lookout.isHittable { app.swipeUp() }
        lookout.tap()
        XCTAssertTrue(app.staticTexts["item.title"].waitForExistence(timeout: 5))
        keep(app, "04-item-detail-\(variant)")
        app.navigationBars.buttons.element(boundBy: 0).tap()

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

        app.terminate()
        let signIn = XCUIApplication()
        signIn.launchArguments = ["-ALResetState", "YES", "-ALServerURL", "adventurelog.example", "-ALAPIKey", "al_example_key"] + arguments
        signIn.launch()
        XCTAssertTrue(signIn.textFields["signin.server"].waitForExistence(timeout: 10))
        keep(signIn, "01-sign-in-\(variant)")
    }

    private func keep(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
