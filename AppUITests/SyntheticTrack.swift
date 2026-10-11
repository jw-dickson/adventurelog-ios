// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A made-up recorded route for day 4 of the synthetic trip (Mon 8 Mar 2027, Tasmania) up to
/// 18:00, as JSON lines of track points: the car hire, the drive with a stop on the way, the
/// holiday park, a late visit to the lookout, then the cruise jetty. Same shape as the Kit's
/// `SyntheticDrive` test data.
enum SyntheticTrack {
    static let carHire = (-42.85, 147.5)
    static let hobartCBD = (-42.8821, 147.3272)
    static let swansea = (-42.1236, 148.0727)
    static let holidayPark = (-42.1247, 148.2861)
    static let lookout = (-42.15, 148.29)
    static let cruise = (-42.121, 148.283)

    /// 8 Mar at a local time in Hobart (UTC+11 in March).
    static func at(_ hour: Int, _ minute: Int) -> TimeInterval {
        var components = DateComponents(year: 2027, month: 3, day: 8, hour: hour, minute: minute)
        components.timeZone = TimeZone(secondsFromGMT: 11 * 3600)
        return Calendar(identifier: .gregorian).date(from: components)!.timeIntervalSince1970
    }

    static func line(_ time: TimeInterval, _ place: (Double, Double), speed: Double? = nil) -> String {
        let speedPart = speed.map { ",\"speed\":\($0)" } ?? ""
        return "{\"time\":\(Int(time)),\"latitude\":\(place.0),\"longitude\":\(place.1),\"accuracy\":10\(speedPart)}"
    }

    static func dwell(_ place: (Double, Double), _ start: TimeInterval, _ end: TimeInterval) -> [String] {
        stride(from: start, through: end, by: 60).enumerated().map { index, time in
            line(time, (place.0 + sin(Double(index)) * 0.00004, place.1 + cos(Double(index)) * 0.00004))
        }
    }

    static func drive(_ from: (Double, Double), _ to: (Double, Double), _ start: TimeInterval, _ end: TimeInterval,
                      includeStart: Bool = true) -> [String] {
        stride(from: includeStart ? start : start + 30, through: end, by: 30).map { time in
            let f = (time - start) / (end - start)
            return line(time, (from.0 + (to.0 - from.0) * f, from.1 + (to.1 - from.1) * f), speed: 20)
        }
    }

    static var jsonLines: String {
        let lines = dwell(carHire, at(8, 55), at(9, 50))
            + drive(carHire, hobartCBD, at(9, 50), at(10, 20))
            + drive(hobartCBD, swansea, at(10, 58), at(12, 20), includeStart: false)
            + dwell(swansea, at(12, 20), at(12, 42))
            + drive(swansea, holidayPark, at(12, 42), at(13, 5))
            + dwell(holidayPark, at(13, 5), at(16, 10))
            + drive(holidayPark, lookout, at(16, 10), at(16, 20))
            + dwell(lookout, at(16, 20), at(16, 50))
            + drive(lookout, cruise, at(16, 50), at(17, 0))
            + dwell(cruise, at(17, 0), at(18, 0))
        return lines.joined(separator: "\n") + "\n"
    }
}
