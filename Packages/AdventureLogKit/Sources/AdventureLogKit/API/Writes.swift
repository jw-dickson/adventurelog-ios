// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// `PATCH /api/checklists/{id}/`.
///
/// AdventureLog rebuilds a checklist's items on every PATCH (`ChecklistSerializer.update` pops
/// `items` with a default of `[]`): a PATCH that leaves `items` out deletes every item, and every
/// item comes back with a new id. So a patch always carries the whole list, by name and state.
public struct ChecklistPatch: Encodable, Sendable, Hashable {
    public struct Item: Encodable, Sendable, Hashable {
        public var name: String
        public var isChecked: Bool

        public init(name: String, isChecked: Bool) {
            self.name = name
            self.isChecked = isChecked
        }
    }

    /// Always sent when known: a collaborator on a shared trip who leaves it out gets a 403,
    /// because the server reads the missing field as "remove from the collection".
    public var collection: String?
    public var name: String
    public var items: [Item]

    public init(collection: String?, name: String, items: [Item]) {
        self.collection = collection
        self.name = name
        self.items = items
    }

    /// The patch that keeps a checklist exactly as it is.
    public init(_ checklist: Checklist, collection: String?) {
        self.init(collection: checklist.collection ?? collection, name: checklist.name,
                  items: checklist.items.map { Item(name: $0.name, isChecked: $0.isChecked) })
    }
}

/// `PATCH /api/notes/{id}/`. Only the content changes; `collection` rides along for the same
/// reason as on checklists.
public struct NotePatch: Encodable, Sendable, Hashable {
    public var collection: String?
    public var content: String

    public init(collection: String?, content: String) {
        self.collection = collection
        self.content = content
    }
}

extension AdventureLogClient {
    /// One checklist with its items. Works for checklists in trips shared with the user, which
    /// the list endpoint leaves out.
    /// - Throws: Request and response-decoding errors from `send(_:as:)`.
    public func checklist(id: String) async throws -> Checklist {
        try await send(makeRequest("GET", "api/checklists/\(id)/"))
    }

    /// Saves a checklist's name and its whole item list. Item ids in the response are new.
    /// - Throws: Request-body encoding errors, or request and response-decoding errors from `send(_:as:)`.
    public func updateChecklist(id: String, _ patch: ChecklistPatch) async throws -> Checklist {
        try await send(makeRequest("PATCH", "api/checklists/\(id)/", body: body(patch)))
    }

    /// One note.
    /// - Throws: Request and response-decoding errors from `send(_:as:)`.
    public func note(id: String) async throws -> Note {
        try await send(makeRequest("GET", "api/notes/\(id)/"))
    }

    /// Saves a note's content.
    /// - Throws: Request-body encoding errors, or request and response-decoding errors from `send(_:as:)`.
    public func updateNote(id: String, _ patch: NotePatch) async throws -> Note {
        try await send(makeRequest("PATCH", "api/notes/\(id)/", body: body(patch)))
    }
}
