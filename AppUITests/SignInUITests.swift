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

    func testStartsAtSignInWithAPassword() {
        let app = launch()
        XCTAssertTrue(app.textFields["signin.server"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["signin.username"].exists)
        XCTAssertTrue(app.secureTextFields["signin.password"].exists)
        XCTAssertFalse(app.secureTextFields["signin.apikey"].exists, "API keys are the fallback, not the default")
        XCTAssertFalse(app.buttons["signin.connect"].isEnabled, "Sign in stays disabled until every field is filled")
    }

    func testSwitchesBetweenAPasswordAndAnAPIKey() {
        let app = launch(["-ALServerURL", "https://example.com"])
        let useKey = app.buttons["signin.useKey"]
        XCTAssertTrue(useKey.waitForExistence(timeout: 10))
        useKey.tap()
        XCTAssertTrue(app.secureTextFields["signin.apikey"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.secureTextFields["signin.password"].exists)
        app.buttons["signin.usePassword"].tap()
        XCTAssertTrue(app.secureTextFields["signin.password"].waitForExistence(timeout: 5))
    }

    func testPasswordSignInNeedsBothFields() {
        let app = launch(["-ALServerURL", "https://example.com"])
        let connect = app.buttons["signin.connect"]
        XCTAssertTrue(connect.waitForExistence(timeout: 10))
        let username = app.textFields["signin.username"]
        username.tap()
        username.typeText("alex")
        XCTAssertFalse(connect.isEnabled, "A username alone is insufficient")
        let password = app.secureTextFields["signin.password"]
        password.tap()
        password.typeText("secret")
        XCTAssertTrue(connect.isEnabled)
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
        app.buttons["signin.useKey"].tap()
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

    /// With `AL_TEST_USERNAME` and `AL_TEST_PASSWORD` for an account on the test server (never a
    /// real one): signs in with the password, so the app makes its own key.
    func testSignsInWithAPassword() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["AL_TEST_SERVER"], !server.isEmpty,
              let username = env["AL_TEST_USERNAME"], !username.isEmpty,
              let password = env["AL_TEST_PASSWORD"], !password.isEmpty else {
            throw XCTSkip("Set AL_TEST_SERVER, AL_TEST_USERNAME and AL_TEST_PASSWORD to sign in with a password.")
        }
        let app = launch(["-ALServerURL", server])
        let field = app.textFields["signin.username"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(username)
        let secret = app.secureTextFields["signin.password"]
        secret.tap()
        secret.typeText(password)
        app.buttons["signin.connect"].tap()
        let tripTab = app.tabBars.buttons["Trip"]
        XCTAssertTrue(tripTab.waitForExistence(timeout: 20), "Signed in")
    }

    func testSignsInAndShowsTheSeededTrip() throws {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["AL_TEST_SERVER"], !server.isEmpty,
              let key = env["AL_TEST_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Set AL_TEST_SERVER and AL_TEST_API_KEY to run against a live AdventureLog.")
        }
        let app = launch(["-ALServerURL", server, "-ALAPIKey", key])
        app.buttons["signin.connect"].tap()
        // The app opens on Today; the trip list is on the Trip tab.
        let tripTab = app.tabBars.buttons["Trip"]
        XCTAssertTrue(tripTab.waitForExistence(timeout: 20))
        tripTab.tap()

        // Rows combine their texts for VoiceOver, so match on part of the label.
        let trip = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Tasmania Road Trip 2027")).firstMatch
        XCTAssertTrue(trip.waitForExistence(timeout: 20), "Seed the server with Fixtures/adventurelog-v0.13.0/seed.py first")
        trip.tap()
        // Before the trip starts it opens on its first day, with the overnight flight.
        let flight = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "EX 7 LAX")).firstMatch
        XCTAssertTrue(flight.waitForExistence(timeout: 20))
    }
}
