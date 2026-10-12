// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import XCTest

/// Launches the app with location allowed, as it is on a phone that said yes. The runner grants it first
/// (`scripts/simulator.sh grant-location`, run by `make test-ui` and CI).
///
/// The first tracking pass after launch creates the CoreLocation monitor. Its name once held a space, CoreLocation
/// raised "Monitor name is not valid", and the app crashed on every launch after location was allowed, a crash
/// no other test could see because none of them had location allowed.
@MainActor
final class LocationAllowedUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    func testStaysUpAfterTheFirstTrackingPassWithLocationAllowed() throws {
        let app = try OfflineBrowseUITests.launchOffline()
        XCTAssertTrue(app.staticTexts["today.title"].waitForExistence(timeout: 15))
        // The pass runs a moment after the trip loads; give it time, then check the app is still there.
        sleep(6)
        XCTAssertEqual(app.state, .runningForeground, "The app died after launch with location allowed")
        XCTAssertTrue(app.staticTexts["today.title"].exists)
    }
}
