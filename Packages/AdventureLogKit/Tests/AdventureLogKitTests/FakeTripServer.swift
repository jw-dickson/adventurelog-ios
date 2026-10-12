// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

/// An in-memory AdventureLog that keeps the server behaviour the outbox has to survive
/// (Fixtures/adventurelog-v0.13.0/README.md):
/// - a checklist PATCH rebuilds every item with a new id, and one without `items` empties the list;
/// - a PATCH without `collection` is refused, as it is for a collaborator on a shared trip;
/// - reorder rejects unknown rows and dates outside the trip, and orders must stay unique per day.
actor FakeTripServer: TripServer {
    private(set) var trip: CollectionDetail
    var offline = false
    var failure: APIError?
    private(set) var writes = 0
    private var clock = Date(timeIntervalSince1970: 1_900_000_000)

    init(trip: CollectionDetail) {
        self.trip = trip
    }

    func setOffline(_ value: Bool) { offline = value }
    func setFailure(_ error: APIError?) { failure = error }

    /// Changes made "on the web" or by a third device, straight to the server.
    func mutate(_ change: @Sendable (inout CollectionDetail) -> Void) {
        change(&trip)
    }

    private func check() throws {
        if offline { throw APIError.transport(code: -1009, description: "The Internet connection appears to be offline.") }
        if let failure { throw failure }
    }

    private func tick() -> Date {
        clock = clock.addingTimeInterval(1)
        return clock
    }

    private static func notFound() -> APIError { .notFound(ServerMessage(summary: "Not found.")) }

    func collection(id: String) async throws -> CollectionDetail {
        try check()
        guard id == trip.id else { throw Self.notFound() }
        return trip
    }

    func checklist(id: String) async throws -> Checklist {
        try check()
        guard let list = trip.checklists.first(where: { $0.id == id }) else { throw Self.notFound() }
        return list
    }

    func updateChecklist(id: String, _ patch: ChecklistPatch) async throws -> Checklist {
        try check()
        guard let index = trip.checklists.firstIndex(where: { $0.id == id }) else { throw Self.notFound() }
        guard patch.collection != nil else {
            throw APIError.forbidden(ServerMessage(summary: "You cannot remove the collection as you are not the owner."))
        }
        writes += 1
        trip.checklists[index].name = patch.name
        trip.checklists[index].items = patch.items.map {
            ChecklistItem(id: UUID().uuidString.lowercased(), name: $0.name, isChecked: $0.isChecked, checklist: id)
        }
        trip.checklists[index].updatedAt = tick()
        return trip.checklists[index]
    }

    func note(id: String) async throws -> Note {
        try check()
        guard let note = trip.notes.first(where: { $0.id == id }) else { throw Self.notFound() }
        return note
    }

    func updateNote(id: String, _ patch: NotePatch) async throws -> Note {
        try check()
        guard let index = trip.notes.firstIndex(where: { $0.id == id }) else { throw Self.notFound() }
        guard patch.collection != nil else {
            throw APIError.forbidden(ServerMessage(summary: "You cannot remove the collection as you are not the owner."))
        }
        writes += 1
        trip.notes[index].content = patch.content
        trip.notes[index].updatedAt = tick()
        return trip.notes[index]
    }

    func reorderItinerary(_ request: ItineraryReorderRequest) async throws -> [ItineraryRow] {
        try check()
        guard !request.items.isEmpty else { throw APIError.invalid(ServerMessage(summary: "items: This field is required and must not be empty.")) }
        var rows = trip.itinerary
        var updated: [ItineraryRow] = []
        for entry in request.items {
            guard let index = rows.firstIndex(where: { $0.id == entry.id }) else {
                throw APIError.invalid(ServerMessage(summary: "items: One or more items not found."))
            }
            if let date = entry.date, let start = trip.startDate, let end = trip.endDate, date < start || date > end {
                throw APIError.invalid(ServerMessage(summary: "items: date \(date) is outside the collection."))
            }
            rows[index].isGlobal = entry.isGlobal
            rows[index].date = entry.isGlobal ? nil : entry.date
            rows[index].order = entry.order
            updated.append(rows[index])
        }
        var seen = Set<String>()
        for row in rows {
            let key = "\(row.isGlobal ? "global" : row.date?.description ?? "?")#\(row.order)"
            guard seen.insert(key).inserted else {
                throw APIError.server(status: 500, ServerMessage(summary: "duplicate key value violates unique constraint (\(key))"))
            }
        }
        writes += 1
        trip.itinerary = rows
        return updated
    }

    // MARK: Items

    private func requireCollection(_ patch: ItemPatch) throws {
        guard patch.collection != nil else {
            throw APIError.forbidden(ServerMessage(summary: "You cannot remove the collection as you are not the owner."))
        }
    }

    /// Applies a patch the way the server does: only the fields sent change; a blank name is refused.
    private func patched(_ patch: ItemPatch, kind: ItemKind, id: String, visitID: String? = nil) throws {
        if case .text(let name)? = patch.fields[.name], FieldValue.clean(name) == nil {
            throw APIError.invalid(ServerMessage(summary: "name: This field may not be blank."))
        }
        writes += 1
        ItemValues.write(patch.fields.map { ($0.key, $0.value) }, kind: kind, itemID: id, visitID: visitID, in: &trip)
    }

    func location(id: String) async throws -> Location {
        try check()
        guard let place = trip.locations.first(where: { $0.id == id }) else { throw Self.notFound() }
        return place
    }

    func updateLocation(id: String, _ patch: ItemPatch) async throws -> Location {
        try check()
        guard trip.locations.contains(where: { $0.id == id }) else { throw Self.notFound() }
        try patched(patch, kind: .location, id: id)
        return try await location(id: id)
    }

    private func placeID(ofVisit id: String) -> String? {
        trip.locations.first { $0.visits.contains { $0.id == id } }?.id
    }

    func visit(id: String) async throws -> Visit {
        try check()
        guard let visit = trip.locations.lazy.flatMap(\.visits).first(where: { $0.id == id }) else { throw Self.notFound() }
        return visit
    }

    func updateVisit(id: String, _ patch: ItemPatch) async throws -> Visit {
        try check()
        guard let place = placeID(ofVisit: id) else { throw Self.notFound() }
        writes += 1
        ItemValues.write(patch.fields.map { ($0.key, $0.value) }, kind: .location, itemID: place, visitID: id, in: &trip)
        return try await visit(id: id)
    }

    func transportation(id: String) async throws -> Transportation {
        try check()
        guard let leg = trip.transportations.first(where: { $0.id == id }) else { throw Self.notFound() }
        return leg
    }

    func updateTransportation(id: String, _ patch: ItemPatch) async throws -> Transportation {
        try check()
        guard trip.transportations.contains(where: { $0.id == id }) else { throw Self.notFound() }
        try requireCollection(patch)
        try patched(patch, kind: .transportation, id: id)
        return try await transportation(id: id)
    }

    func lodging(id: String) async throws -> Lodging {
        try check()
        guard let stay = trip.lodging.first(where: { $0.id == id }) else { throw Self.notFound() }
        return stay
    }

    func updateLodging(id: String, _ patch: ItemPatch) async throws -> Lodging {
        try check()
        guard trip.lodging.contains(where: { $0.id == id }) else { throw Self.notFound() }
        try requireCollection(patch)
        try patched(patch, kind: .lodging, id: id)
        return try await lodging(id: id)
    }

    private(set) var createdNotes = 0

    func createNote(_ note: NoteCreate) async throws -> Note {
        try check()
        writes += 1
        createdNotes += 1
        let made = Note(id: UUID().uuidString.lowercased(), user: nil, name: note.name, content: note.content, date: note.date,
                        links: DefaultEmpty(wrappedValue: []), isPublic: false, collection: note.collection,
                        createdAt: tick(), updatedAt: tick())
        trip.notes.append(made)
        if loseAnswer {
            loseAnswer = false
            throw APIError.transport(code: -1005, description: "The network connection was lost.")
        }
        return made
    }

    func createItineraryRow(_ row: ItineraryRowCreate) async throws -> ItineraryRow {
        try check()
        if let date = row.date, let start = trip.startDate, let end = trip.endDate, date < start || date > end {
            throw APIError.invalid(ServerMessage(summary: "date: outside the collection."))
        }
        // The server bumps an order that's already taken to max + 1.
        let taken = ItineraryLayout.group(row.date, in: trip.itinerary).map(\.order)
        let order = taken.contains(row.order) ? (taken.max() ?? -1) + 1 : row.order
        writes += 1
        let made = ItineraryRow(id: UUID().uuidString.lowercased(), collection: row.collection, objectId: row.objectId,
                                item: .init(id: row.objectId, type: ItemKind(rawValue: row.contentType) ?? .unknown),
                                objectName: row.contentType, date: row.date, isGlobal: row.isGlobal, order: order,
                                startDatetime: nil, endDatetime: nil)
        trip.itinerary.append(made)
        return made
    }

    func deleteItineraryRow(id: String) async throws {
        try check()
        guard trip.itinerary.contains(where: { $0.id == id }) else { throw Self.notFound() }
        writes += 1
        trip.itinerary.removeAll { $0.id == id }
    }

    /// Makes the next `createNote` succeed on the server but lose its answer, as on a flaky network.
    func loseNextAnswer() { loseAnswer = true }
    private var loseAnswer = false
}

/// One phone: the server copy it last fetched, plus its outbox. What it shows is the copy with the
/// outbox's edits applied, which is what the app does.
struct FakeDevice {
    let tripID: String
    var saved: CollectionDetail
    var outbox = Outbox()
    var now = Date(timeIntervalSince1970: 1_900_000_000)

    init(_ trip: CollectionDetail) {
        self.tripID = trip.id
        self.saved = trip
    }

    var shown: CollectionDetail { saved.applying(outbox.visibleEdits(for: tripID)) }

    mutating func make(_ edit: TripEdit) {
        outbox.enqueue(edit, tripID: tripID, at: now)
    }

    /// Sends until the outbox is empty or a send has to wait.
    mutating func drain(to server: FakeTripServer) async {
        let sender = EditSender(server: server)
        while let entry = outbox.next(at: now) {
            let outcome = await sender.send(entry.edit, tripID: tripID)
            outbox.record(outcome, for: entry.id, sent: entry.edit, at: now)
            if case .retry = outcome { break }
            if case .unauthorized = outcome { break }
        }
    }

    mutating func refresh(from server: FakeTripServer) async throws {
        saved = try await server.collection(id: tripID)
    }

    /// The edit that ticks or unticks the named item on the named checklist, as the screen makes it.
    func tick(_ itemName: String, on listName: String, _ checked: Bool = true) throws -> TripEdit {
        let list = try #require(shown.checklists.first { $0.name == listName })
        let item = try #require(list.items.first { $0.name == itemName })
        return .checkItem(try #require(TripEdit.CheckItem(checklist: list, itemID: item.id, isChecked: checked)))
    }

    func noteEdit(_ name: String, to content: String) throws -> TripEdit {
        let note = try #require(shown.notes.first { $0.name == name })
        return .editNote(TripEdit.EditNote(noteID: note.id, noteName: note.name, baseContent: note.content ?? "", content: content))
    }

    /// The row that places the named object.
    func row(_ title: String) throws -> ItineraryRow {
        let trip = shown
        let ids = trip.locations.filter { $0.name == title }.map(\.id) + trip.transportations.filter { $0.name == title }.map(\.id)
            + trip.lodging.filter { $0.name == title }.map(\.id) + trip.notes.filter { $0.name == title }.map(\.id)
            + trip.checklists.filter { $0.name == title }.map(\.id)
        return try #require(trip.itinerary.first { ids.contains($0.objectId) })
    }

    func move(_ title: String, to date: CalendarDate?, at index: Int) throws -> TripEdit {
        .moveRow(TripEdit.MoveRow(rowID: try row(title).id, title: title, toDate: date, toIndex: index))
    }

    /// Titles on a day (nil: trip-wide), in order.
    func titles(on date: CalendarDate?) -> [String] {
        let plan = TripPlan(shown, fallbackTimeZone: TimeZone(identifier: "Australia/Hobart")!)
        let entries: [TripPlan.Entry]
        if let date {
            entries = plan.day(for: date)?.entries ?? []
        } else {
            entries = plan.tripWide
        }
        return entries.map(\.item.title)
    }
}

