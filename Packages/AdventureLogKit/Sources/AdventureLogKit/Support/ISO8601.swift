// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Strict, allocation-light ISO-8601 datetime parsing and formatting for AdventureLog's wire format.
///
/// The server returns every datetime in UTC with a `Z`, sometimes with microseconds
/// (`2026-10-11T01:08:01.590527Z`). It accepts offsets on write. A string with no offset
/// is treated as UTC, matching the server's own `ensure_aware_utc`.
public enum ISO8601 {
    static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Parses `YYYY-MM-DDTHH:MM:SS[.fraction][Z|±HH:MM|±HHMM]`, also allowing a space instead of `T`.
    /// Accepts hour-only offsets too; a missing offset means UTC. Returns `nil` for unrecognized input,
    /// including date-only strings (use `CalendarDate` for those).
    /// Checks basic component ranges, but calendar construction may normalize impossible dates
    /// and leap seconds; offset component ranges are not validated.
    public static func parse(_ string: String) -> Date? {
        let bytes = Array(string.utf8)

        func number(at index: Int, digits: Int) -> Int? {
            guard index >= 0, index + digits <= bytes.count else { return nil }
            var value = 0
            for position in index..<(index + digits) {
                let byte = bytes[position]
                guard byte >= 48, byte <= 57 else { return nil }
                value = value * 10 + Int(byte - 48)
            }
            return value
        }

        guard bytes.count >= 19,
              let year = number(at: 0, digits: 4), bytes[4] == 45,
              let month = number(at: 5, digits: 2), bytes[7] == 45,
              let day = number(at: 8, digits: 2),
              bytes[10] == 84 || bytes[10] == 32,
              let hour = number(at: 11, digits: 2), bytes[13] == 58,
              let minute = number(at: 14, digits: 2), bytes[16] == 58,
              let second = number(at: 17, digits: 2)
        else { return nil }

        var index = 19
        var fraction = 0.0
        if index < bytes.count, bytes[index] == 46 {
            index += 1
            let start = index
            var scale = 0.1
            while index < bytes.count, bytes[index] >= 48, bytes[index] <= 57 {
                fraction += Double(bytes[index] - 48) * scale
                scale /= 10
                index += 1
            }
            if index == start { return nil }
        }

        var offsetSeconds = 0
        if index < bytes.count {
            let sign = bytes[index]
            if sign == 90 { // Z
                index += 1
            } else if sign == 43 || sign == 45 { // + or -
                guard let offsetHours = number(at: index + 1, digits: 2) else { return nil }
                var cursor = index + 3
                if cursor < bytes.count, bytes[cursor] == 58 { cursor += 1 }
                var offsetMinutes = 0
                if let minutes = number(at: cursor, digits: 2) {
                    offsetMinutes = minutes
                    cursor += 2
                }
                offsetSeconds = (offsetHours * 3600 + offsetMinutes * 60) * (sign == 43 ? 1 : -1)
                index = cursor
            } else {
                return nil
            }
        }
        guard index == bytes.count else { return nil }
        guard (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61 else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let base = utc.date(from: components) else { return nil }
        return base.addingTimeInterval(fraction - Double(offsetSeconds))
    }

    /// Formats in the server's canonical form, `YYYY-MM-DDTHH:MM:SSZ` (whole seconds, UTC).
    public static func format(_ date: Date) -> String {
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02dZ",
            c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0
        )
    }
}
