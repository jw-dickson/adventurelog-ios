// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Testing
@testable import AdventureLogKit

@Suite("The geofence monitor's name")
struct GeofenceMonitorTests {
    @Test func theNameTheAppUsesIsOneCoreLocationAccepts() {
        #expect(GeofenceMonitor.isValid(GeofenceMonitor.name))
    }

    /// "AdventureLog stops" was the first name; CoreLocation answered "Monitor name is not valid" and the
    /// app crashed on every launch once location was allowed.
    @Test(arguments: ["AdventureLog stops", "", " ", "stops!", "a-b", "a_b", "café"])
    func namesCoreLocationRejectsAreRefused(_ name: String) {
        #expect(!GeofenceMonitor.isValid(name))
    }

    @Test(arguments: ["AdventureLogStops", "stops1", "A"])
    func plainLettersAndDigitsAreAccepted(_ name: String) {
        #expect(GeofenceMonitor.isValid(name))
    }
}
