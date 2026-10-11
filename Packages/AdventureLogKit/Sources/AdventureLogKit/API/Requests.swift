// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// `POST /api/itineraries/reorder/`. Moves rows between days, to and from trip-wide, and reorders.
/// Reordering never changes the underlying object's own date.
public struct ItineraryReorderRequest: Encodable, Sendable, Hashable {
    public struct Entry: Encodable, Sendable, Hashable {
        public var id: String
        /// `nil` together with `isGlobal == true` places the row trip-wide.
        public var date: CalendarDate?
        public var isGlobal: Bool
        public var order: Int

        /// Targets an existing row by ID; a `nil` date sets `isGlobal` for trip-wide placement.
        public init(id: String, date: CalendarDate?, order: Int) {
            self.id = id
            self.date = date
            self.isGlobal = date == nil
            self.order = order
        }

        private enum CodingKeys: String, CodingKey { case id, date, isGlobal, order }

        // `date` is always sent, as `null` for trip-wide rows: the server enforces date XOR global.
        /// Encodes every field, including `null` for a missing date; propagates encoder errors.
        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(date, forKey: .date)
            try container.encode(isGlobal, forKey: .isGlobal)
            try container.encode(order, forKey: .order)
        }
    }

    public var items: [Entry]

    public init(items: [Entry]) {
        self.items = items
    }
}

/// `POST /api/itineraries/`. Places an existing object on a day or trip-wide.
public struct ItineraryCreateRequest: Encodable, Sendable, Hashable {
    public var collection: String
    /// Sent as the model name string (`"location"` …); never the install-specific integer.
    public var contentType: ItemKind
    public var objectId: String
    public var date: CalendarDate?
    public var isGlobal: Bool
    public var order: Int

    /// Prepares placement of an existing object in the collection; a `nil` date sets `isGlobal`.
    public init(collection: String, kind: ItemKind, objectId: String, date: CalendarDate?, order: Int) {
        self.collection = collection
        self.contentType = kind
        self.objectId = objectId
        self.date = date
        self.isGlobal = date == nil
        self.order = order
    }
}
