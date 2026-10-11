// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import ActivityKit
import AdventureLogKit

/// The Live Activity for a flight or a booked tour, shared by the app (which starts, updates and
/// ends it) and the widget extension (which draws it). A push from the companion service sends
/// `LiveActivityState` as its `content-state`.
struct TripActivityAttributes: ActivityAttributes {
    typealias ContentState = LiveActivityState
    var info: LiveActivityInfo
}
