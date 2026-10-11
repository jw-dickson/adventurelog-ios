// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A flight, drive, ride or hire. Each endpoint has its own time zone.
public struct Transportation: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var user: String?
    public var type: TransportationType
    public var name: String
    public var description: String?
    public var rating: Double?
    public var price: String?
    public var priceCurrency: String?
    public var link: String?
    /// Departure, UTC.
    public var date: Date?
    /// Arrival, UTC.
    public var endDate: Date?
    public var flightNumber: String?
    public var fromLocation: String?
    public var toLocation: String?
    public var startCode: String?
    public var endCode: String?
    public var isPublic: Bool?
    public var collection: String?
    public var originLatitude: Double?
    public var originLongitude: Double?
    public var destinationLatitude: Double?
    public var destinationLongitude: Double?
    public var startTimezone: String?
    public var endTimezone: String?
    /// Kilometres, computed by the server.
    public var distance: Double?
    public var travelDurationMinutes: Int?
    @DefaultEmpty public var images: [ContentImage]
    public var createdAt: Date?
    public var updatedAt: Date?
}

/// A stay. One time zone covers both check-in and check-out.
public struct Lodging: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var user: String?
    public var name: String
    public var type: LodgingType?
    public var description: String?
    public var rating: Double?
    public var link: String?
    public var checkIn: Date?
    public var checkOut: Date?
    public var timezone: String?
    public var reservationNumber: String?
    public var price: String?
    public var priceCurrency: String?
    public var latitude: Double?
    public var longitude: Double?
    /// Free-text address.
    public var location: String?
    public var isPublic: Bool?
    public var collection: String?
    @DefaultEmpty public var images: [ContentImage]
    public var createdAt: Date?
    public var updatedAt: Date?

    /// The server accepts a check-out before check-in; the app must not trust the order.
    public var hasValidStay: Bool {
        guard let checkIn, let checkOut else { return true }
        return checkOut >= checkIn
    }
}

/// A markdown note, optionally dated.
public struct Note: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var user: String?
    public var name: String
    public var content: String?
    public var date: CalendarDate?
    @DefaultEmpty public var links: [String]
    public var isPublic: Bool?
    public var collection: String?
    public var createdAt: Date?
    public var updatedAt: Date?
}

/// A checklist. A PATCH that includes `items` replaces the whole set, and item ids can change:
/// always use the ids from the latest response.
public struct Checklist: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var user: String?
    public var name: String
    public var date: CalendarDate?
    public var isPublic: Bool?
    public var collection: String?
    @DefaultEmpty public var items: [ChecklistItem]
    public var createdAt: Date?
    public var updatedAt: Date?

    public var checkedCount: Int { items.filter(\.isChecked).count }
}

public struct ChecklistItem: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var isChecked: Bool
    public var checklist: String?
}
