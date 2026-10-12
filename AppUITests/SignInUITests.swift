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

    private func fill(_ app: XCUIApplication, username: String = "alex", password: String = "secret") {
        let field = app.textFields["signin.username"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText(username)
        let secret = app.secureTextFields["signin.password"]
        secret.tap()
        secret.typeText(password)
    }

    func testStartsAtSignInWithAPasswordOrSingleSignOn() {
        let app = launch()
        XCTAssertTrue(app.textFields["signin.server"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["signin.username"].exists)
        XCTAssertTrue(app.secureTextFields["signin.password"].exists)
        XCTAssertTrue(app.buttons["signin.sso"].exists, "Single sign-on is always on offer")
        XCTAssertFalse(app.secureTextFields["signin.apikey"].exists, "There is no way to paste an API key")
        XCTAssertFalse(app.buttons["signin.useKey"].exists)
        XCTAssertFalse(app.buttons["signin.connect"].isEnabled, "Sign in stays disabled until every field is filled")
    }

    /// Issue #9: with no providers listed (or a sign-on proxy hiding them), single sign-on opens the
    /// server's own pages in the web sheet.
    func testSingleSignOnOpensTheServersPages() {
        let app = launch(["-ALServerURL", "https://example.com"])
        let sso = app.buttons["signin.sso"]
        XCTAssertTrue(sso.waitForExistence(timeout: 10))
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: sso)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        sso.tap()
        XCTAssertTrue(app.descendants(matching: .any)["signin.web"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "signin.error").firstMatch.exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.textFields["signin.server"].waitForExistence(timeout: 5))
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
        let app = launch(["-ALServerURL", "ftp://nope"])
        fill(app)
        app.buttons["signin.connect"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "signin.error").firstMatch.waitForExistence(timeout: 10))
    }

    func testWhitespaceOnlyServerKeepsSignInDisabled() {
        let app = launch(["-ALServerURL", "   "])
        fill(app)
        XCTAssertFalse(app.buttons["signin.connect"].isEnabled)
    }

    func testWhitespaceOnlyUsernameKeepsSignInDisabled() {
        let app = launch(["-ALServerURL", "https://example.com"])
        fill(app, username: "   ")
        XCTAssertFalse(app.buttons["signin.connect"].isEnabled)
    }

    func testFailedSignInKeepsFormAvailableForRetry() {
        let app = launch(["-ALServerURL", "ftp://invalid"])
        fill(app)
        let connect = app.buttons["signin.connect"]
        connect.tap()
        let error = app.descendants(matching: .any).matching(identifier: "signin.error").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["signin.server"].exists)
        XCTAssertTrue(app.secureTextFields["signin.password"].exists)
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
        // The key goes in through the launch-argument test seam; the app itself has no key field.
        let app = launch(["-ALServerURL", server, "-ALAPIKey", key])
        // The app opens on Today; the trip list is on the Trip tab.
        let tripTab = app.tabBars.buttons["Trip"]
        let tabShown = tripTab.waitForExistence(timeout: 20)
        if !tabShown { keepState(app, "no-trip-tab") }
        XCTAssertTrue(tabShown)
        tripTab.tap()

        // Rows combine their texts for VoiceOver, so match on part of the label.
        let trip = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Tasmania Road Trip 2027")).firstMatch
        let tripShown = trip.waitForExistence(timeout: 20)
        if !tripShown { keepState(app, "trip-row-missing") }
        XCTAssertTrue(tripShown, "Seed the server with Fixtures/adventurelog-v0.13.0/seed.py first")
        trip.tap()
        // Before the trip starts it opens on its first day, with the overnight flight.
        let flight = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "EX 7 LAX")).firstMatch
        let flightShown = flight.waitForExistence(timeout: 20)
        if !flightShown { keepState(app, "flight-missing") }
        XCTAssertTrue(flightShown)
    }

    /// Keeps what was on screen, and the accessibility tree, in the test result when a wait runs out,
    /// so a failure against a live server says what the app was showing.
    private func keepState(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "\(name)-screen"
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-tree"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
