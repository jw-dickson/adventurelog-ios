// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import XCTest

/// Simulator smoke tests. The end-to-end test runs only when a test server is configured:
///
///     AL_TEST_SERVER=http://127.0.0.1:8000 AL_TEST_API_KEY=al_… make test-ui
///
/// (xcodebuild passes `TEST_RUNNER_`-prefixed variables through to the test process.)
@MainActor
final class SignInUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-ALResetState", "YES"] + extra
        app.launch()
        return app
    }

    func testStartsAtSignIn() {
        let app = launch()
        XCTAssertTrue(app.textFields["signin.server"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.secureTextFields["signin.apikey"].exists)
        XCTAssertFalse(app.buttons["signin.connect"].isEnabled, "Connect stays disabled until both fields are filled")
    }

    func testBadAddressShowsAnError() {
        let app = launch(["-ALServerURL", "ftp://nope", "-ALAPIKey", "al_x"])
        let connect = app.buttons["signin.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "signin.error").firstMatch.waitForExistence(timeout: 10))
    }

    func testConnectRequiresBothFields() {
        let app = launch(["-ALServerURL", "https://example.com"])
        let connect = app.buttons["signin.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertFalse(connect.isEnabled, "A server address alone is insufficient")
        let key = app.secureTextFields["signin.apikey"]
        key.tap()
        key.typeText("al_test")
        XCTAssertTrue(connect.isEnabled, "Filling the key enables Connect without starting a request")
    }

    func testWhitespaceOnlyServerKeepsConnectDisabled() {
        let app = launch(["-ALServerURL", "   ", "-ALAPIKey", "al_test"])
        let connect = app.buttons["signin.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertFalse(connect.isEnabled)
    }

    func testWhitespaceOnlyKeyKeepsConnectDisabled() {
        let app = launch(["-ALServerURL", "https://example.com", "-ALAPIKey", "   "])
        let connect = app.buttons["signin.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        XCTAssertFalse(connect.isEnabled)
    }

    func testFailedSignInKeepsFormAvailableForRetry() {
        let app = launch(["-ALServerURL", "ftp://invalid", "-ALAPIKey", "al_test"])
        let connect = app.buttons["signin.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        connect.tap()
        let error = app.descendants(matching: .any).matching(identifier: "signin.error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["signin.server"].exists)
        XCTAssertTrue(app.secureTextFields["signin.apikey"].exists)
        let retryEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: connect)
        XCTAssertEqual(XCTWaiter.wait(for: [retryEnabled], timeout: 5), .completed)
        connect.tap()
        XCTAssertTrue(error.waitForExistence(timeout: 10))
    }

    func testSignsInAndShowsTheSeededTrip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["AL_TEST_SERVER"], !server.isEmpty,
              let key = env["AL_TEST_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Set AL_TEST_SERVER and AL_TEST_API_KEY to run against a live AdventureLog.")
        }
        let app = launch(["-ALServerURL", server, "-ALAPIKey", key])
        app.buttons["signin.connect"].tap()

        let trip = app.staticTexts["Tasmania Road Trip 2027"]
        XCTAssertTrue(trip.waitForExistence(timeout: 20), "Seed the server with Fixtures/adventurelog-v0.13.0/seed.py first")
        trip.tap()
        // Outline rows combine their texts for VoiceOver, so match on part of the label.
        let flight = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "EX 7 LAX")).firstMatch
        XCTAssertTrue(flight.waitForExistence(timeout: 20))
    }
}
