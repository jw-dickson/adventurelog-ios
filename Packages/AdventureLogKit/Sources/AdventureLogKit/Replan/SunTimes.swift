// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Sunrise and sunset for a place and a calendar date, worked out on the phone so a replan can
/// keep daylight plans in daylight without a network.
///
/// NOAA's simplified solar position (accurate to a minute or two away from the poles), with the
/// standard −0.833° altitude for refraction and the sun's radius.
public enum SunTimes {
    /// Sunset on `date` at the place, or `nil` when the sun doesn't set (or rise) that day.
    /// `date` is the local calendar date in `zone`.
    public static func sunset(on date: CalendarDate, latitude: Double, longitude: Double, zone: TimeZone) -> Date? {
        times(on: date, latitude: latitude, longitude: longitude, zone: zone)?.sunset
    }

    /// Sunrise on `date` at the place, or `nil` in polar day or night.
    public static func sunrise(on date: CalendarDate, latitude: Double, longitude: Double, zone: TimeZone) -> Date? {
        times(on: date, latitude: latitude, longitude: longitude, zone: zone)?.sunrise
    }

    static func times(on date: CalendarDate, latitude: Double, longitude: Double, zone: TimeZone) -> (sunrise: Date, sunset: Date)? {
        // The solar day whose noon falls on that local date: measured from local noon and corrected
        // by longitude, so it's right in any zone (UTC+13 and +14 included).
        let localNoon = date.startOfDay(in: zone).addingTimeInterval(12 * 3600)
        let julianDay = localNoon.timeIntervalSince1970 / 86_400 + 2_440_587.5
        let n = (julianDay - 2_451_545.0 + 0.0008 + longitude / 360).rounded()
        let meanNoon = n - longitude / 360
        let meanAnomaly = (357.5291 + 0.98560028 * meanNoon).truncatingRemainder(dividingBy: 360)
        let m = meanAnomaly * .pi / 180
        let center = 1.9148 * sin(m) + 0.0200 * sin(2 * m) + 0.0003 * sin(3 * m)
        let eclipticLongitude = (meanAnomaly + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360) * .pi / 180
        let transit = 2_451_545.0 + meanNoon + 0.0053 * sin(m) - 0.0069 * sin(2 * eclipticLongitude)
        let declination = asin(sin(eclipticLongitude) * sin(23.4397 * .pi / 180))
        let phi = latitude * .pi / 180
        let cosHourAngle = (sin(-0.833 * .pi / 180) - sin(phi) * sin(declination)) / (cos(phi) * cos(declination))
        guard (-1...1).contains(cosHourAngle) else { return nil }
        let hourAngle = acos(cosHourAngle) * 180 / .pi
        func instant(_ julian: Double) -> Date { Date(timeIntervalSince1970: (julian - 2_440_587.5) * 86_400) }
        return (instant(transit - hourAngle / 360), instant(transit + hourAngle / 360))
    }
}
