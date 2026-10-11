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
    /// The edit no longer applies (its item was deleted, or the day left the trip). Says why.
    case dropped(String)
    /// Someone else changed the same note; the person picks a version.
    case conflict(NoteConflict)
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
            case .moveRow: return .dropped("The trip was deleted, or it is no longer shared with you.")
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
