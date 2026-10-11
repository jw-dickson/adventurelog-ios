// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// One recorded position. Kept on the phone only.
public struct TrackPoint: Codable, Sendable, Hashable {
    public var time: Date
    public var latitude: Double
    public var longitude: Double
    /// Horizontal accuracy, metres.
    public var accuracy: Double
    /// Metres per second, when known.
    public var speed: Double?

    public init(time: Date, latitude: Double, longitude: Double, accuracy: Double = 10, speed: Double? = nil) {
        self.time = time
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.speed = speed
    }

    public var coordinate: ItemSummary.Coordinate? { ItemSummary.Coordinate(latitude, longitude) }
}

/// Arriving at or leaving a planned stop, from a geofence around it.
public struct PlaceEvent: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case arrived, left }

    public var rowID: String
    public var kind: Kind
    public var time: Date

    public init(rowID: String, kind: Kind, time: Date) {
        self.rowID = rowID
        self.kind = kind
        self.time = time
    }
}

/// Somewhere the phone stayed for a while.
public struct DetectedStop: Sendable, Hashable {
    public var start: Date
    public var end: Date
    public var latitude: Double
    public var longitude: Double

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var coordinate: ItemSummary.Coordinate? { ItemSummary.Coordinate(latitude, longitude) }
}

/// Finds stops in a track: places the phone stayed within a small radius for some minutes.
public enum StopDetector {
    /// - Parameters:
    ///   - radius: metres around the stop's centre.
    ///   - minimumDuration: shorter pauses (traffic lights, a fuel stop) aren't stops.
    ///   - maximumAccuracy: points less accurate than this are ignored.
    ///
    /// iOS sends few or no updates while the phone sits still, so a long gap between a point and
    /// the next one, at walking pace or less, counts as time spent at the earlier point.
    public static func stops(in points: [TrackPoint], radius: Double = 80, minimumDuration: TimeInterval = 5 * 60,
                             maximumAccuracy: Double = 100) -> [DetectedStop] {
        let track = points.filter { $0.accuracy <= maximumAccuracy }.sorted { $0.time < $1.time }
        var stops: [DetectedStop] = []
        var i = 0
        while i < track.count {
            var latitude = track[i].latitude, longitude = track[i].longitude, count = 1.0
            var j = i
            while j + 1 < track.count {
                let next = track[j + 1]
                if metres(latitude / count, longitude / count, next.latitude, next.longitude) <= radius {
                    latitude += next.latitude
                    longitude += next.longitude
                    count += 1
                    j += 1
                } else {
                    break
                }
            }
            var end = track[j].time
            if j + 1 < track.count {
                let gap = track[j + 1].time.timeIntervalSince(end)
                let distance = metres(track[j].latitude, track[j].longitude, track[j + 1].latitude, track[j + 1].longitude)
                if gap >= minimumDuration, distance / gap < 1.5 { end = track[j + 1].time }
            }
            if end.timeIntervalSince(track[i].time) >= minimumDuration {
                stops.append(DetectedStop(start: track[i].time, end: end, latitude: latitude / count, longitude: longitude / count))
                i = j + 1
            } else {
                i += 1
            }
        }
        return stops
    }

    /// Kilometres covered, leaving out GPS jitter while stopped.
    public static func kilometres(along points: [TrackPoint], maximumAccuracy: Double = 50) -> Double {
        let track = points.filter { $0.accuracy <= maximumAccuracy }.sorted { $0.time < $1.time }
        var total = 0.0
        var last: TrackPoint?
        for point in track {
            guard let previous = last else { last = point; continue }
            let step = metres(previous.latitude, previous.longitude, point.latitude, point.longitude)
            // Under 20 m is jitter; keep the anchor until the phone really moves.
            if step >= 20 {
                total += step
                last = point
            }
        }
        return total / 1000
    }

    static func metres(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        guard let a = ItemSummary.Coordinate(lat1, lon1), let b = ItemSummary.Coordinate(lat2, lon2) else { return .infinity }
        return LeaveBy.kilometres(from: a, to: b) * 1000
    }
}
