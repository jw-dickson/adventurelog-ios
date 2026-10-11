// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A place (AdventureLog `Location`). Times live on its `visits`, never on the location.
public struct Location: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var description: String?
    public var rating: Double?
    @DefaultEmpty public var tags: [String]
    /// Free-text address.
    public var location: String?
    public var isPublic: Bool?
    /// Collection ids this location belongs to.
    @DefaultEmpty public var collections: [String]
    @DefaultEmpty public var images: [ContentImage]
    public var link: String?
    public var latitude: Double?
    public var longitude: Double?
    @DefaultEmpty public var visits: [Visit]
    public var isVisited: Bool?
    /// Never null on v0.13 (the server falls back to a per-user "general" category), optional for safety.
    public var category: LocationCategory?
    /// Decimal string such as `"42.00"`.
    public var price: String?
    public var priceCurrency: String?
    public var createdAt: Date?
    public var updatedAt: Date?

    public var primaryImage: ContentImage? {
        images.first(where: \.isPrimary) ?? images.first
    }
}

public struct Visit: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var location: String?
    /// UTC instant. An all-day visit is UTC midnight on its calendar date (see `TripTime.isAllDay`).
    public var startDate: Date?
    public var endDate: Date?
    /// IANA zone name, a display hint only; the server does no time-zone math with it.
    public var timezone: String?
    public var notes: String?
}

public struct LocationCategory: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var displayName: String
    /// A user-chosen emoji.
    public var icon: String?
    public var numLocations: Int?
}

public struct ContentImage: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Absolute URL built from the server's PUBLIC_URL. Private images need the API key header.
    public var image: String
    public var isPrimary: Bool
    public var latitude: Double?
    public var longitude: Double?

    public var url: URL? { URL(string: image) }
}
