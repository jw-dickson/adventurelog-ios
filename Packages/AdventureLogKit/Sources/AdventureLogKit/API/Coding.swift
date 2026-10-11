// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// JSON coders configured for AdventureLog: snake_case keys, ISO-8601 datetimes.
/// Created per use rather than shared, so nothing depends on coder Sendability.
public enum ALCoding {
    /// Creates a decoder for snake_case keys and ISO-8601 datetimes, accepting date-only strings as UTC midnight.
    /// The date strategy throws decoding errors for non-string or unrecognized date values.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            if let date = ISO8601.parse(string) { return date }
            // A few fields carry a date-only string where a datetime is expected; treat as UTC midnight.
            if let day = CalendarDate(string), string.count == 10 {
                return day.startOfDay(in: TimeZone(secondsFromGMT: 0)!)
            }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not an ISO-8601 datetime: \(string)")
        }
        return decoder
    }

    /// Creates an encoder with sorted snake_case keys and UTC datetimes at whole-second precision.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(ISO8601.format(date))
        }
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
