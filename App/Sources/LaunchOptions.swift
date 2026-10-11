// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation

/// Launch arguments used by UI tests and Simulator runs.
///
/// - `-ALResetState YES` starts signed out with nothing saved (in-memory storage).
/// - `-ALServerURL <url>` and `-ALAPIKey <key>` prefill the sign-in form.
/// - `-ALNow <ISO-8601>` pins the app's clock (used from Stage 2 for Today and reminders).
struct LaunchOptions: Sendable {
    var resetState = false
    var serverURL: String?
    var apiKey: String?
    var now: Date?

    static var current: LaunchOptions {
        let defaults = UserDefaults.standard
        var options = LaunchOptions()
        options.resetState = defaults.bool(forKey: "ALResetState")
        options.serverURL = defaults.string(forKey: "ALServerURL")
        options.apiKey = defaults.string(forKey: "ALAPIKey")
        options.now = defaults.string(forKey: "ALNow").flatMap { ISO8601.parse($0) }
        return options
    }
}
