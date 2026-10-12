// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Photos to the trip (Stage 6): what the companion has matched for one trip, day by day, as
/// `GET /v1/trips/{id}/photos` answers. The companion does the matching and writes the sidecars;
/// the phone only shows it, turns it on or off, and asks for a day to be undone.
public struct TripPhotos: Codable, Sendable, Equatable {
    public var enabled: Bool
    /// Minutes added to the camera's times, for a clock that ran slow (positive) or fast.
    public var cameraOffsetMinutes: Int
    /// When the companion last looked (ISO-8601), and what went wrong then, if anything.
    public var lastRun: String?
    public var lastError: String?
    public var days: [Day]

    public init(enabled: Bool, cameraOffsetMinutes: Int = 0, lastRun: String? = nil, lastError: String? = nil, days: [Day] = []) {
        self.enabled = enabled
        self.cameraOffsetMinutes = cameraOffsetMinutes
        self.lastRun = lastRun
        self.lastError = lastError
        self.days = days
    }

    public struct Day: Codable, Sendable, Equatable, Identifiable {
        public var date: CalendarDate
        /// Matched and written.
        public var photos: Int
        /// Put back by an undo.
        public var undone: Int
        /// Couldn't be written (outside the library, a sidecar that isn't XMP…).
        public var failed: Int
        /// Matched photos by stop; an empty title is the day's photos taken between stops.
        public var stops: [Stop]

        public var id: CalendarDate { date }

        public init(date: CalendarDate, photos: Int, undone: Int = 0, failed: Int = 0, stops: [Stop] = []) {
            self.date = date
            self.photos = photos
            self.undone = undone
            self.failed = failed
            self.stops = stops
        }

        /// "Wineglass Bay Lookout 3 · Sunset cruise 1 · between stops 2", largest first, the
        /// between-stops count last.
        public var stopsText: String {
            let named = stops.filter { !$0.title.isEmpty }.sorted { ($0.photos, $1.title) > ($1.photos, $0.title) }
            var parts = named.map { "\($0.title) \($0.photos)" }
            let loose = stops.filter(\.title.isEmpty).reduce(0) { $0 + $1.photos }
            if loose > 0 { parts.append("between stops \(loose)") }
            return parts.joined(separator: " · ")
        }

        /// "12 photos", with what was undone or failed: "12 photos · 3 undone · 1 not written".
        public var countText: String {
            var parts = [photos == 1 ? "1 photo" : "\(photos) photos"]
            if undone > 0 { parts.append("\(undone) undone") }
            if failed > 0 { parts.append("\(failed) not written") }
            return parts.joined(separator: " · ")
        }

        /// Something an undo would put back.
        public var canUndo: Bool { photos > 0 || failed > 0 }
    }

    public struct Stop: Codable, Sendable, Equatable {
        public var title: String
        public var photos: Int

        public init(title: String, photos: Int) {
            self.title = title
            self.photos = photos
        }
    }

    /// What an undo did, with the trip's photos after it.
    public struct Undo: Sendable, Equatable {
        /// Photos whose sidecars were put back.
        public var restored: Int
        /// Photos left as they were because Lightroom (or something else) changed the sidecar since.
        public var kept: Int
        public var photos: TripPhotos

        public init(restored: Int, kept: Int, photos: TripPhotos) {
            self.restored = restored
            self.kept = kept
            self.photos = photos
        }
    }

    public func day(_ date: CalendarDate) -> Day? {
        days.first { $0.date == date }
    }

    public var totalPhotos: Int { days.reduce(0) { $0 + $1.photos } }

    /// The camera offset as a person says it: "On time", "3 min slow", "1 h 5 min fast".
    public static func offsetText(_ minutes: Int) -> String {
        guard minutes != 0 else { return "On time" }
        let amount = abs(minutes)
        let text = amount >= 60
            ? "\(amount / 60) h" + (amount % 60 == 0 ? "" : " \(amount % 60) min")
            : "\(amount) min"
        // A positive offset is added to the camera's times: its clock was behind.
        return text + (minutes > 0 ? " slow" : " fast")
    }

    /// The companion takes offsets in this range.
    public static let offsetRange = -1440...1440
}

/// Where the phone gets a trip's photos from: the companion, or a stand-in for UI tests.
public protocol TripPhotosService: Sendable {
    func photos(tripID: String) async throws -> TripPhotos
    func setPhotos(tripID: String, enabled: Bool, cameraOffsetMinutes: Int) async throws -> TripPhotos
    func undoPhotos(tripID: String, date: CalendarDate) async throws -> TripPhotos.Undo
}
