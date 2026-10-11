// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A collection as listed (`/api/collections/`, `/all/`, `/shared/`). A collection with dates is a trip.
public struct CollectionSummary: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    /// Owner's user uuid.
    public var user: String?
    public var name: String
    public var description: String?
    public var isPublic: Bool?
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public var isArchived: Bool?
    public var link: String?
    public var locationCount: Int?
    @DefaultEmpty public var sharedWith: [String]
    @DefaultEmpty public var collaborators: [Collaborator]
    /// Computed by the server from its own local date.
    public var status: CollectionStatus?
    public var daysUntilStart: Int?
    public var createdAt: Date?
    public var updatedAt: Date?

    public var isTrip: Bool { startDate != nil && endDate != nil }
}

/// A collection with everything in it (`GET /api/collections/{id}/`), the one call that loads a trip.
public struct CollectionDetail: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var user: String?
    public var name: String
    public var description: String?
    public var isPublic: Bool?
    public var startDate: CalendarDate?
    public var endDate: CalendarDate?
    public var isArchived: Bool?
    public var link: String?
    @DefaultEmpty public var sharedWith: [String]
    @DefaultEmpty public var collaborators: [Collaborator]
    public var status: CollectionStatus?
    public var daysUntilStart: Int?
    public var createdAt: Date?
    public var updatedAt: Date?

    @DefaultEmpty public var locations: [Location]
    @DefaultEmpty public var transportations: [Transportation]
    @DefaultEmpty public var lodging: [Lodging]
    @DefaultEmpty public var notes: [Note]
    @DefaultEmpty public var checklists: [Checklist]
    /// Placement rows. Only present on `retrieve`; PATCH responses omit it, so re-GET after edits.
    @DefaultEmpty public var itinerary: [ItineraryRow]
    @DefaultEmpty public var itineraryDays: [ItineraryDayMeta]

    public var owner: Collaborator? { collaborators.first(where: { $0.isOwner == true }) }
    public var currentUserIsOwner: Bool { collaborators.first(where: { $0.isCurrentUser == true })?.isOwner ?? true }
}

public struct Collaborator: Codable, Sendable, Hashable, Identifiable {
    public var uuid: String
    public var username: String
    public var firstName: String?
    public var lastName: String?
    public var isOwner: Bool?
    public var isCurrentUser: Bool?

    public var id: String { uuid }

    public var displayName: String {
        let full = [firstName, lastName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        return full.isEmpty ? username : full
    }
}

/// One placement of an item on a day (or trip-wide). A row's day is its own `date`,
/// never derived from the item's times.
public struct ItineraryRow: Codable, Sendable, Hashable, Identifiable {
    public struct ItemReference: Codable, Sendable, Hashable {
        public var id: String
        public var type: ItemKind
    }

    public var id: String
    public var collection: String
    public var objectId: String
    public var item: ItemReference?
    public var objectName: String?
    /// `nil` exactly when `isGlobal` is true.
    public var date: CalendarDate?
    public var isGlobal: Bool
    /// Ascending within one date (or within the global set). Gaps are possible.
    public var order: Int
    /// Raw string: a datetime for transport and lodging, a date for notes and checklists, null for locations.
    public var startDatetime: String?
    public var endDatetime: String?

    public var kind: ItemKind {
        if let item { return item.type }
        return objectName.flatMap(ItemKind.init(rawValue:)) ?? .unknown
    }
}

/// Per-date name and description for a trip day.
public struct ItineraryDayMeta: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var collection: String?
    public var date: CalendarDate
    public var name: String?
    public var description: String?
}

/// DRF page envelope. Only `/api/collections/` and `/api/locations/` paginate.
public struct Page<Element: Codable & Sendable & Hashable>: Codable, Sendable, Hashable {
    public var count: Int
    public var next: String?
    public var previous: String?
    public var results: [Element]
}

/// The signed-in user (`GET /auth/user-metadata/`). People are identified by `uuid`.
public struct User: Codable, Sendable, Hashable, Identifiable {
    public var uuid: String
    public var username: String
    public var firstName: String?
    public var lastName: String?
    public var publicProfile: Bool?
    public var measurementSystem: String?
    public var defaultCurrency: String?

    public var id: String { uuid }

    public var displayName: String {
        let full = [firstName, lastName].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " ")
        return full.isEmpty ? username : full
    }
}
