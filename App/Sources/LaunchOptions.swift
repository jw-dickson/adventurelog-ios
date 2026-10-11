// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation
import SwiftUI

/// Launch arguments used by UI tests and Simulator runs.
///
/// - `-ALResetState YES` starts signed out with nothing saved (in-memory storage).
/// - `-ALServerURL <url>` and `-ALAPIKey <key>` prefill the sign-in form.
/// - `-ALNow <ISO-8601>` pins the app's clock, so "happening now" and done items are repeatable.
/// - `-ALOfflineSeed YES` starts signed in to an unreachable server with the trips in the
///   `AL_SEED_LIST` and `AL_SEED_TRIP` environment variables (AdventureLog JSON) already saved:
///   the offline browsing test. Needs `-ALResetState YES`.
/// - `-ALAppearance light|dark` forces an appearance for screenshot runs.
struct LaunchOptions: Sendable {
    var resetState = false
    var serverURL: String?
    var apiKey: String?
    var now: Date?
    var offlineSeed = false
    var seedList: Data?
    var seedTrip: Data?
    /// "light" or "dark"; nil follows the system.
    var appearance: String?

    static var current: LaunchOptions {
        let defaults = UserDefaults.standard
        let env = ProcessInfo.processInfo.environment
        var options = LaunchOptions()
        options.resetState = defaults.bool(forKey: "ALResetState")
        options.serverURL = defaults.string(forKey: "ALServerURL")
        options.apiKey = defaults.string(forKey: "ALAPIKey")
        options.now = defaults.string(forKey: "ALNow").flatMap { ISO8601.parse($0) }
        options.offlineSeed = options.resetState && defaults.bool(forKey: "ALOfflineSeed")
        options.seedList = env["AL_SEED_LIST"].map { Data($0.utf8) }
        options.seedTrip = env["AL_SEED_TRIP"].map { Data($0.utf8) }
        options.appearance = defaults.string(forKey: "ALAppearance")
        return options
    }
}

extension LaunchOptions {
    var colorScheme: ColorScheme? {
        switch appearance {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
}
