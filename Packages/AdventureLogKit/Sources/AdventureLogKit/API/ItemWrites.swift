// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A PATCH body for a location, visit, transportation or lodging: only the fields being changed.
/// A cleared field is sent as `null`, so it is cleared on the server too.
public struct ItemPatch: Encodable, Sendable, Hashable {
    public var kind: ItemKind
    /// Field → value; encoded in a fixed order.
    public var fields: [ItemField: FieldValue]
    /// Sent for transportation and lodging: a collaborator who leaves it out gets a 403.
    public var collection: String?

    public init(kind: ItemKind, fields: [ItemField: FieldValue], collection: String?) {
        self.kind = kind
        self.fields = fields
        self.collection = collection
    }

    public var isEmpty: Bool { fields.isEmpty }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for (field, value) in fields.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let key = Key(field.wireKey(for: kind))
            switch value {
            case .text(let text):
                if let clean = FieldValue.clean(text) {
                    try container.encode(clean, forKey: key)
                } else if field == .name {
                    continue // a name can't be blank on the server; leave it as it is
                } else {
                    try container.encodeNil(forKey: key)
                }
            case .time(let date):
                if let date { try container.encode(date, forKey: key) } else { try container.encodeNil(forKey: key) }
            }
        }
        if let collection { try container.encode(collection, forKey: Key("collection")) }
    }
}

/// `POST /api/notes/`.
public struct NoteCreate: Encodable, Sendable, Hashable {
    public var collection: String
    public var name: String
    public var content: String
    public var date: CalendarDate?
    public var isPublic = false

    public init(collection: String, name: String, content: String, date: CalendarDate?) {
        self.collection = collection
        self.name = name
        self.content = content
        self.date = date
    }
}

/// `POST /api/itineraries/`: places an item on a day, or trip-wide. `date` and `is_global` are
/// exclusive (`errors/400__itinerary_both_date_and_global.json`).
public struct ItineraryRowCreate: Encodable, Sendable, Hashable {
    public var collection: String
    public var contentType: String
    public var objectId: String
    public var order: Int
    public var date: CalendarDate?
    public var isGlobal: Bool

    public init(collection: String, contentType: String, objectId: String, order: Int, date: CalendarDate?) {
        self.collection = collection
        self.contentType = contentType
        self.objectId = objectId
        self.order = order
        self.date = date
        self.isGlobal = date == nil
    }

    private enum CodingKeys: String, CodingKey { case collection, contentType, objectId, order, date, isGlobal }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(collection, forKey: .collection)
        try container.encode(contentType, forKey: .contentType)
        try container.encode(objectId, forKey: .objectId)
        try container.encode(order, forKey: .order)
        if let date {
            try container.encode(date, forKey: .date)
        } else {
            try container.encode(true, forKey: .isGlobal)
        }
    }
}

extension AdventureLogClient {
    /// One place, with its visits.
    public func location(id: String) async throws -> Location {
        try await send(makeRequest("GET", "api/locations/\(id)/"))
    }

    /// Saves some of a place's fields. Never sends `visits`, which would replace every visit.
    public func updateLocation(id: String, _ patch: ItemPatch) async throws -> Location {
        try await send(makeRequest("PATCH", "api/locations/\(id)/", body: body(patch)))
    }

    public func visit(id: String) async throws -> Visit {
        try await send(makeRequest("GET", "api/visits/\(id)/"))
    }

    public func updateVisit(id: String, _ patch: ItemPatch) async throws -> Visit {
        try await send(makeRequest("PATCH", "api/visits/\(id)/", body: body(patch)))
    }

    public func transportation(id: String) async throws -> Transportation {
        try await send(makeRequest("GET", "api/transportations/\(id)/"))
    }

    public func updateTransportation(id: String, _ patch: ItemPatch) async throws -> Transportation {
        try await send(makeRequest("PATCH", "api/transportations/\(id)/", body: body(patch)))
    }

    public func lodging(id: String) async throws -> Lodging {
        try await send(makeRequest("GET", "api/lodging/\(id)/"))
    }

    public func updateLodging(id: String, _ patch: ItemPatch) async throws -> Lodging {
        try await send(makeRequest("PATCH", "api/lodging/\(id)/", body: body(patch)))
    }

    public func createNote(_ note: NoteCreate) async throws -> Note {
        try await send(makeRequest("POST", "api/notes/", body: body(note)))
    }

    public func createItineraryRow(_ row: ItineraryRowCreate) async throws -> ItineraryRow {
        try await send(makeRequest("POST", "api/itineraries/", body: body(row)))
    }

    /// Takes a row off its day. `preserve_visits` keeps a place's visits on that date, which the
    /// server would otherwise delete with the row (`itinerary_view.py` `destroy`).
    public func deleteItineraryRow(id: String) async throws {
        _ = try await data(for: makeRequest("DELETE", "api/itineraries/\(id)/", query: [URLQueryItem(name: "preserve_visits", value: "true")]))
    }
}
