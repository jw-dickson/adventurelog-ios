// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// GPX 1.1 for a recorded track, the format Lightroom Classic, AdventureLog and most mapping
/// tools read. Each day is its own track segment; stops become waypoints.
public enum GPX {
    public struct Waypoint: Sendable, Hashable {
        public var name: String
        public var latitude: Double
        public var longitude: Double
        public var time: Date?

        public init(name: String, latitude: Double, longitude: Double, time: Date? = nil) {
            self.name = name
            self.latitude = latitude
            self.longitude = longitude
            self.time = time
        }
    }

    /// - Parameter segments: points split however the caller likes, usually one array per day.
    public static func document(name: String, segments: [[TrackPoint]], waypoints: [Waypoint] = []) -> String {
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<gpx version="1.1" creator="AdventureLog for iOS" xmlns="http://www.topografix.com/GPX/1/1">"#,
            "  <metadata><name>\(escape(name))</name></metadata>",
        ]
        for waypoint in waypoints {
            var line = #"  <wpt lat="\#(coordinate(waypoint.latitude))" lon="\#(coordinate(waypoint.longitude))">"#
            if let time = waypoint.time { line += "<time>\(ISO8601.format(time))</time>" }
            line += "<name>\(escape(waypoint.name))</name></wpt>"
            lines.append(line)
        }
        lines.append("  <trk><name>\(escape(name))</name>")
        for segment in segments where !segment.isEmpty {
            lines.append("    <trkseg>")
            for point in segment.sorted(by: { $0.time < $1.time }) {
                lines.append(#"      <trkpt lat="\#(coordinate(point.latitude))" lon="\#(coordinate(point.longitude))"><time>\#(ISO8601.format(point.time))</time></trkpt>"#)
            }
            lines.append("    </trkseg>")
        }
        lines.append("  </trk>")
        lines.append("</gpx>")
        return lines.joined(separator: "\n") + "\n"
    }

    /// Six decimal places: about 10 cm, more than GPS gives.
    static func coordinate(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
