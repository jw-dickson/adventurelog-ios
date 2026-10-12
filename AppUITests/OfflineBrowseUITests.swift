// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import XCTest

/// Stage 1's exit check: browse a saved trip with no server at all.
///
/// The app starts signed in to an unreachable address with the seeded (synthetic) trip already saved, the
/// way it would be after a previous session, and the clock pinned to the evening of 8 Mar 2027.
@MainActor
final class OfflineBrowseUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    static func fixture(_ name: String) throws -> String {
        let bundle = Bundle(for: OfflineBrowseUITests.self)
        let url = try XCTUnwrap(bundle.url(forResource: name, withExtension: "json"), "\(name).json is not in the test bundle")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Launches offline on Mon 8 Mar 2027, 18:00 in Tasmania.
    /// - Parameters:
    ///   - track: also seed a recorded route for the day (``SyntheticTrack``).
    ///   - photos: also give a few items, and the trip, drawn photos (``GalleryPhotos``).
    static func launchOffline(_ extra: [String] = [], track: Bool = false, photos: Bool = false) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ALResetState", "YES", "-ALOfflineSeed", "YES", "-ALNow", "2027-03-08T07:00:00Z"] + extra
        app.launchEnvironment["AL_SEED_LIST"] = try fixture("collections__all")
        let trip = try fixture("collections__detail")
        if photos {
            let seeded = try GalleryPhotos.seed(trip)
            app.launchEnvironment["AL_SEED_TRIP"] = seeded.trip
            app.launchEnvironment["AL_SEED_IMAGES"] = seeded.images
        } else {
            app.launchEnvironment["AL_SEED_TRIP"] = trip
        }
        if track { app.launchEnvironment["AL_SEED_TRACK"] = SyntheticTrack.jsonLines }
        // The phone is in the trip's zone, whatever zone the Mac running the Simulator is in.
        app.launchEnvironment["TZ"] = "Australia/Hobart"
        app.launch()
        return app
    }

    func element(_ app: XCUIApplication, containing text: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }

    func testBrowsesTheSavedTripWithNoServer() throws {
        let app = try Self.launchOffline()
        app.tabBars.buttons["Trip"].tap()

        // The trip happening now opens by itself, on today.
        let title = app.staticTexts["day.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 15), "The current trip should open on launch")
        XCTAssertEqual(title.label, "D2 · Hobart → Freycinet")
        XCTAssertTrue(app.descendants(matching: .any)["offline.banner"].waitForExistence(timeout: 10), "Says it can't reach the server")

        // A booked stay shows its reservation; an item opens its detail.
        XCTAssertTrue(element(app, containing: "BHP-0042").waitForExistence(timeout: 5))
        let lookout = element(app, containing: "Wineglass Bay Lookout")
        XCTAssertTrue(lookout.waitForExistence(timeout: 5))
        lookout.tap()
        XCTAssertTrue(app.staticTexts["item.title"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["item.title"].label, "Wineglass Bay Lookout")
        XCTAssertTrue(element(app, containing: "Freycinet National Park").exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Another day, across the date line.
        let travelDay = app.buttons["day.2027-03-05"]
        XCTAssertTrue(travelDay.waitForExistence(timeout: 5))
        travelDay.tap()
        XCTAssertTrue(element(app, containing: "D0 · Travel day").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "EX 7").exists)

        // Trip-wide notes and checklists.
        app.segmentedControls["trip.scope"].buttons["Whole trip"].tap()
        XCTAssertTrue(element(app, containing: "Trip essentials").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "Packing list").exists)

        // Places that are in the trip but on no day.
        app.segmentedControls["trip.scope"].buttons["Not on a day"].tap()
        XCTAssertTrue(element(app, containing: "Dove Lake Circuit").waitForExistence(timeout: 5))

        // The map tab shows the same trip.
        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["trip.map"].waitForExistence(timeout: 10))
    }

    func testTripListGroupsTheTripAsHappeningNow() throws {
        let app = try Self.launchOffline()
        app.tabBars.buttons["Trip"].tap()
        XCTAssertTrue(app.staticTexts["day.title"].waitForExistence(timeout: 15))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, containing: "Happening now").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, containing: "Day 4 of 19").exists)
    }
}
