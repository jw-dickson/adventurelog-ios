// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

/// A string enum that decodes unknown server values to a fallback instead of failing the whole
/// response. A newer AdventureLog can add choices without breaking older app builds.
public protocol LenientStringEnum: RawRepresentable, Codable, Sendable, Hashable, CaseIterable where RawValue == String {
    static var fallback: Self { get }
}

extension LenientStringEnum {
    /// Uses `fallback` for an unknown string; propagates decoding errors for missing or non-string values.
    public init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: raw) ?? Self.fallback
    }

    /// Encodes the current raw string, including a fallback value; propagates encoder errors.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum TransportationType: String, LenientStringEnum {
    case car, plane, train, bus, boat, bike, walking, other
    public static var fallback: Self { .other }
}

public enum LodgingType: String, LenientStringEnum {
    case hotel, hostel, resort, bnb, campground, cabin, apartment, house, villa, motel, other
    public static var fallback: Self { .other }
}

public enum CollectionStatus: String, LenientStringEnum {
    case folder
    case upcoming
    case inProgress = "in_progress"
    case completed
    public static var fallback: Self { .folder }
}

/// The kind of object an itinerary row points at (`item.type` / `object_name` on the wire).
public enum ItemKind: String, LenientStringEnum {
    case location, transportation, lodging, note, checklist, visit, unknown
    public static var fallback: Self { .unknown }
}
