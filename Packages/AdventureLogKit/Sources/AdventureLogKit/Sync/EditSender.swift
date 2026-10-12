// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// The server calls the outbox needs. `AdventureLogClient` is the real one; tests use a fake that
/// keeps AdventureLog's quirks.
public protocol TripServer: Sendable {
    func collection(id: String) async throws -> CollectionDetail
    func checklist(id: String) async throws -> Checklist
    func updateChecklist(id: String, _ patch: ChecklistPatch) async throws -> Checklist
    func note(id: String) async throws -> Note
    func updateNote(id: String, _ patch: NotePatch) async throws -> Note
    func reorderItinerary(_ request: ItineraryReorderRequest) async throws -> [ItineraryRow]
    func location(id: String) async throws -> Location
    func updateLocation(id: String, _ patch: ItemPatch) async throws -> Location
    func visit(id: String) async throws -> Visit
    func updateVisit(id: String, _ patch: ItemPatch) async throws -> Visit
    func transportation(id: String) async throws -> Transportation
    func updateTransportation(id: String, _ patch: ItemPatch) async throws -> Transportation
    func lodging(id: String) async throws -> Lodging
    func updateLodging(id: String, _ patch: ItemPatch) async throws -> Lodging
    func createNote(_ note: NoteCreate) async throws -> Note
    func createItineraryRow(_ row: ItineraryRowCreate) async throws -> ItineraryRow
    func deleteItineraryRow(id: String) async throws
}

extension AdventureLogClient: TripServer {}

/// Both sides changed a note: the server's text when the edit was sent.
public struct NoteConflict: Codable, Sendable, Hashable {
    public var serverContent: String
    public var serverUpdatedAt: Date?

    public init(serverContent: String, serverUpdatedAt: Date?) {
        self.serverContent = serverContent
        self.serverUpdatedAt = serverUpdatedAt
    }
}

/// What happened when an edit was sent.
public enum SyncOutcome: Sendable, Hashable {
    /// The server has the change, either just now or already.
    case done
    /// A note made on the phone is on the server now, with these ids. Edits queued for it
    /// meanwhile are pointed at them.
    case added(noteID: String, rowID: String)
    /// The edit no longer applies (its item was deleted, or the day left the trip). Says why.
    case dropped(String)
    /// Someone else changed the same note; the person picks a version.
    case conflict(NoteConflict)
    /// Someone else changed some of the same fields of an item. The edit's other fields were saved;
    /// the person picks a version of these.
    case fieldConflict(FieldConflict)
    /// The server couldn't be reached or had a temporary problem. Try again later.
    case retry(String)
    /// The server refused the change. Says why.
    case failed(String)
    /// The API key stopped working. Keep everything and stop sending.
    case unauthorized(String)
}

/// Sends one edit by replaying it onto the server's current copy.
///
/// Every edit is idempotent: sending it again after a lost response finds the server already
/// matching and reports `.done`.
public struct EditSender: Sendable {
    public let server: any TripServer

    public init(server: any TripServer) {
        self.server = server
    }

    /// - Parameter tripID: the collection the edit belongs to; sent with every PATCH so
    ///   collaborators on a shared trip are allowed to save.
    public func send(_ edit: TripEdit, tripID: String) async -> SyncOutcome {
        do {
            switch edit {
            case .checkItem(let edit): return try await send(edit, tripID: tripID)
            case .editNote(let edit): return try await send(edit, tripID: tripID)
            case .moveRow(let edit): return try await send(edit, tripID: tripID)
            case .editItem(let edit): return try await send(edit, tripID: tripID)
            case .appendNote(let edit): return try await send(edit, tripID: tripID)
            case .addNote(let edit): return try await send(edit, tripID: tripID)
            case .removeRow(let edit): return try await send(edit, tripID: tripID)
            }
        } catch let error as APIError {
            return Self.outcome(for: error, edit: edit)
        } catch is CancellationError {
            return .retry("Cancelled.")
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func send(_ edit: TripEdit.CheckItem, tripID: String) async throws -> SyncOutcome {
        let list = try await server.checklist(id: edit.checklistID)
        guard let index = edit.index(in: list.items) else {
            return .dropped("“\(edit.itemName)” is no longer on \(list.name).")
        }
        if list.items[index].isChecked == edit.isChecked { return .done }
        var patch = ChecklistPatch(list, collection: tripID)
        patch.items[index].isChecked = edit.isChecked
        _ = try await server.updateChecklist(id: list.id, patch)
        return .done
    }

    private func send(_ edit: TripEdit.EditNote, tripID: String) async throws -> SyncOutcome {
        let note = try await server.note(id: edit.noteID)
        let current = note.content ?? ""
        if current == edit.content { return .done }
        if current != edit.baseContent {
            return .conflict(NoteConflict(serverContent: current, serverUpdatedAt: note.updatedAt))
        }
        _ = try await server.updateNote(id: note.id, NotePatch(collection: note.collection ?? tripID, content: edit.content))
        return .done
    }

    private func send(_ edit: TripEdit.MoveRow, tripID: String) async throws -> SyncOutcome {
        let trip = try await server.collection(id: tripID)
        if let date = edit.toDate, let start = trip.startDate, let end = trip.endDate, date < start || date > end {
            return .dropped("“\(edit.title)” wasn't moved: \(date) is no longer part of the trip.")
        }
        guard let moved = ItineraryLayout.move(edit.rowID, to: edit.toDate, at: edit.toIndex, in: trip.itinerary) else {
            return .dropped("“\(edit.title)” is no longer in the trip's plan.")
        }
        guard let request = ItineraryLayout.request(for: moved) else { return .done }
        _ = try await server.reorderItinerary(request)
        return .done
    }

    /// The server's current values of an item's fields, by reading the objects that hold them.
    private func current(_ fields: [ItemField], kind: ItemKind, itemID: String, visitID: String?) async throws -> [ItemField: FieldValue] {
        var values: [ItemField: FieldValue] = [:]
        switch kind {
        case .location:
            if fields.contains(where: { !$0.isOnVisit }) {
                let place = try await server.location(id: itemID)
                for field in fields where !field.isOnVisit { values[field] = ItemValues.read(field, of: place) }
            }
            if let visitID, fields.contains(where: \.isOnVisit) {
                let visit = try await server.visit(id: visitID)
                for field in fields where field.isOnVisit { values[field] = ItemValues.read(field, of: visit) }
            }
        case .transportation:
            let leg = try await server.transportation(id: itemID)
            for field in fields { values[field] = ItemValues.read(field, of: leg) }
        case .lodging:
            let stay = try await server.lodging(id: itemID)
            for field in fields { values[field] = ItemValues.read(field, of: stay) }
        default:
            break
        }
        return values
    }

    /// Saves fields: a place's go to the location and its visit, everything else to the one object.
    private func save(_ fields: [ItemField: FieldValue], kind: ItemKind, itemID: String, visitID: String?, tripID: String) async throws {
        switch kind {
        case .location:
            let onPlace = fields.filter { !$0.key.isOnVisit }
            let onVisit = fields.filter { $0.key.isOnVisit }
            if !onPlace.isEmpty { _ = try await server.updateLocation(id: itemID, ItemPatch(kind: .location, fields: onPlace, collection: nil)) }
            if !onVisit.isEmpty, let visitID { _ = try await server.updateVisit(id: visitID, ItemPatch(kind: .visit, fields: onVisit, collection: nil)) }
        case .transportation:
            _ = try await server.updateTransportation(id: itemID, ItemPatch(kind: kind, fields: fields, collection: tripID))
        case .lodging:
            _ = try await server.updateLodging(id: itemID, ItemPatch(kind: kind, fields: fields, collection: tripID))
        default:
            break
        }
    }

    private func send(_ edit: TripEdit.EditItem, tripID: String) async throws -> SyncOutcome {
        let fields = edit.changes.map(\.field)
        if edit.kind == .location, edit.visitID == nil, fields.contains(where: \.isOnVisit) {
            return .dropped("“\(edit.title)” has no visit on this trip any more, so its times and visit notes weren't saved.")
        }
        let onServer = try await current(fields, kind: edit.kind, itemID: edit.itemID, visitID: edit.visitID)
        var toSave: [ItemField: FieldValue] = [:]
        var clashes: [FieldClash] = []
        for change in edit.changes {
            let now: FieldValue = onServer[change.field] ?? (change.field.isTime ? .time(nil) : .text(nil))
            if now.matches(change.value) { continue }
            if now.matches(change.base) {
                toSave[change.field] = change.value
            } else {
                clashes.append(FieldClash(field: change.field, server: now))
            }
        }
        if !toSave.isEmpty {
            try await save(toSave, kind: edit.kind, itemID: edit.itemID, visitID: edit.visitID, tripID: tripID)
        }
        return clashes.isEmpty ? .done : .fieldConflict(FieldConflict(clashes: clashes))
    }

    private func send(_ edit: TripEdit.AppendNote, tripID: String) async throws -> SyncOutcome {
        let field = edit.field
        let onServer = try await current([field], kind: edit.kind, itemID: edit.itemID, visitID: edit.visitID)
        let text = onServer[field]?.text
        if edit.isIn(text) { return .done }
        try await save([field: .text(edit.appended(to: text))], kind: edit.kind, itemID: edit.itemID, visitID: edit.visitID, tripID: tripID)
        return .done
    }

    private func send(_ edit: TripEdit.AddNote, tripID: String) async throws -> SyncOutcome {
        var trip = try await server.collection(id: tripID)
        // A day that left the trip: the note goes trip-wide rather than being lost.
        var date = edit.date
        if let day = date, let start = trip.startDate, let end = trip.endDate, day < start || day > end { date = nil }
        // Sent before but the answer was lost: the note is already there.
        let note: Note
        if let existing = trip.notes.first(where: { $0.name == edit.title && ($0.content ?? "") == edit.content && $0.date == edit.date }) {
            note = existing
        } else {
            note = try await server.createNote(NoteCreate(collection: tripID, name: edit.title, content: edit.content, date: edit.date))
            trip.notes.append(note)
        }
        if let row = trip.itinerary.first(where: { $0.objectId == note.id }) {
            return .added(noteID: note.id, rowID: row.id)
        }
        let order = (ItineraryLayout.group(date, in: trip.itinerary).map(\.order).max() ?? -1) + 1
        let row = try await server.createItineraryRow(ItineraryRowCreate(collection: tripID, contentType: "note", objectId: note.id, order: order, date: date))
        return .added(noteID: note.id, rowID: row.id)
    }

    private func send(_ edit: TripEdit.RemoveRow, tripID: String) async throws -> SyncOutcome {
        do {
            try await server.deleteItineraryRow(id: edit.rowID)
        } catch APIError.notFound {
            // Already gone.
        }
        return .done
    }

    static func outcome(for error: APIError, edit: TripEdit) -> SyncOutcome {
        switch error {
        case .transport(_, let description):
            return .retry(description)
        case .server(let status, let message):
            if status >= 500 || status == 408 || status == 429 { return .retry(message.summary) }
            return .failed(error.localizedDescription)
        case .unauthorized(let message):
            return .unauthorized(message.summary)
        case .notFound:
            switch edit {
            case .checkItem(let edit): return .dropped("“\(edit.checklistName)” was deleted, or the trip is no longer shared with you.")
            case .editNote(let edit): return .dropped("“\(edit.noteName)” was deleted, or the trip is no longer shared with you.")
            case .moveRow, .addNote, .removeRow: return .dropped("The trip was deleted, or it is no longer shared with you.")
            case .editItem(let edit): return .dropped("“\(edit.title)” was deleted, or the trip is no longer shared with you.")
            case .appendNote(let edit): return .dropped("“\(edit.title)” was deleted, or the trip is no longer shared with you.")
            }
        case .forbidden(let message), .invalid(let message), .subscriptionRequired(let message):
            return .failed(message.summary)
        case .decoding(let description):
            return .failed("Unexpected response from the server. \(description)")
        case .badServerURL:
            return .failed(error.localizedDescription)
        }
    }
}
