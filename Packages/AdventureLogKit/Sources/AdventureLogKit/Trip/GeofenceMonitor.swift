// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// The name of the app's `CLMonitor`, and what CoreLocation accepts as one.
///
/// CoreLocation raises `NSInternalInconsistencyException: Monitor name is not valid` for a name it
/// does not like, and the app aborts. The first name, "AdventureLog stops", had a space in it, so
/// every launch with location permission granted crashed straight away. Letters and digits are safe.
public enum GeofenceMonitor {
    /// Used for the one `CLMonitor` that watches the next planned stops.
    public static let name = "AdventureLogStops"

    /// Whether `name` is made of ASCII letters and digits only, and is not empty.
    public static func isValid(_ name: String) -> Bool {
        !name.isEmpty && name.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }
}
