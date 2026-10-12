// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// An edit waiting for the server, or one that needs the person's attention.
public struct PendingEdit: Codable, Sendable, Hashable, Identifiable {
    public enum State: Codable, Sendable, Hashable {
        /// Will be sent when the server can be reached.
        case waiting
        /// Someone else changed the same note. Shown as the person's version until they choose.
        case conflict(NoteConflict)
        /// Someone else changed some of the same fields of an item; the edit holds only those now.
        case fieldConflict(FieldConflict)
        /// The server refused it. Not shown on the trip; the person can retry or discard it.
        case failed(String)
    }

    public var id: UUID
    public var tripID: String
    public var edit: TripEdit
    public var createdAt: Date
    public var state: State
    /// Failed sends since the last success or manual retry.
    public var attempts: Int
    /// Why the last send didn't go through.
    public var lastError: String?
    /// After a temporary failure, not before this time.
    public var notBefore: Date?

    public init(id: UUID = UUID(), tripID: String, edit: TripEdit, createdAt: Date, state: State = .waiting) {
        self.id = id
        self.tripID = tripID
        self.edit = edit
        self.createdAt = createdAt
        self.state = state
        self.attempts = 0
    }

    public var isWaiting: Bool { state == .waiting }
}

/// An edit that was dropped because it no longer applied, kept so the person hears about it.
public struct SyncNotice: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var tripID: String
    public var message: String
    /// Text that would otherwise be lost, such as an unsent note, so it can be copied.
    public var keptText: String?
    public var createdAt: Date

    public init(id: UUID = UUID(), tripID: String, message: String, keptText: String?, createdAt: Date) {
        self.id = id
        self.tripID = tripID
        self.message = message
        self.keptText = keptText
        self.createdAt = createdAt
    }
}

/// Edits made on this phone, in the order they were made, until the server has them.
///
/// A value type with no I/O, so every rule here is unit-tested: the app persists it after each
/// change and drives sending.
public struct Outbox: Codable, Sendable, Hashable {
    public private(set) var entries: [PendingEdit]
    public private(set) var notices: [SyncNotice]
    /// The entry being sent right now. Nothing is folded into it, since the server may already
    /// have the version being sent. Not saved: after a relaunch nothing is in flight.
    public private(set) var sending: UUID?

    private enum CodingKeys: String, CodingKey { case entries, notices }

    public init(entries: [PendingEdit] = [], notices: [SyncNotice] = []) {
        self.entries = entries
        self.notices = notices
    }

    // MARK: Adding

    /// Adds an edit, folding it into an earlier edit to the same thing where that keeps the result
    /// the same: a second tick of one item, more typing in one note, or dragging the row just moved.
    public mutating func enqueue(_ edit: TripEdit, tripID: String, at now: Date, id: UUID = UUID()) {
        switch edit {
        case .checkItem(let new):
            // A failed edit to the same item is superseded; retrying it later would undo this one.
            entries.removeAll { entry in
                guard case .failed = entry.state, entry.tripID == tripID, case .checkItem(let old) = entry.edit else { return false }
                return old.sameItem(as: new)
            }
            if let index = entries.lastIndex(where: { entry in
                guard entry.isWaiting, entry.tripID == tripID, case .checkItem(let old) = entry.edit else { return false }
                return old.sameItem(as: new)
            }) {
                entries[index].edit = .checkItem(new)
                return
            }

        case .editNote(let new):
            // Editing a note that hasn't been sent yet changes what will be added.
            if TripEdit.AddNote.isLocal(new.noteID), let index = entries.lastIndex(where: { entry in
                guard entry.isWaiting, entry.id != sending, entry.tripID == tripID, case .addNote(let add) = entry.edit else { return false }
                return add.localID == new.noteID
            }), case .addNote(var add) = entries[index].edit {
                add.content = new.content
                entries[index].edit = .addNote(add)
                return
            }
            if let index = entries.lastIndex(where: { entry in
                guard entry.tripID == tripID, case .editNote(let old) = entry.edit, old.noteID == new.noteID else { return false }
                if case .failed = entry.state { return false }
                return true
            }), case .editNote(var old) = entries[index].edit {
                old.content = new.content
                old.noteName = new.noteName
                if old.content == old.baseContent, entries[index].isWaiting {
                    entries.remove(at: index) // typed back to where it started
                } else {
                    entries[index].edit = .editNote(old)
                }
                return
            }
            if new.content == new.baseContent { return }

        case .editItem(let new):
            if let index = entries.lastIndex(where: { entry in
                guard entry.isWaiting, entry.tripID == tripID, case .editItem(let old) = entry.edit else { return false }
                return old.sameItem(as: new)
            }), case .editItem(var old) = entries[index].edit {
                old.absorb(new)
                if old.changes.isEmpty {
                    entries.remove(at: index) // edited back to where it started
                } else {
                    entries[index].edit = .editItem(old)
                }
                return
            }
            if new.changes.isEmpty { return }

        case .appendNote:
            break

        case .addNote:
            break

        case .removeRow(let new):
            // Removing a note that hasn't been sent yet: it simply isn't added.
            if let index = waitingAddNote(rowID: new.rowID, tripID: tripID) {
                entries.remove(at: index)
                return
            }

        case .moveRow(let new):
            // A note that hasn't been sent yet goes to its new day when it is added.
            if let index = waitingAddNote(rowID: new.rowID, tripID: tripID), case .addNote(var add) = entries[index].edit {
                add.date = new.toDate
                entries[index].edit = .addNote(add)
                return
            }
            // Only the very last edit, so other moves made in between still replay in order.
            if let last = entries.indices.last, entries[last].isWaiting, entries[last].tripID == tripID,
               case .moveRow(let old) = entries[last].edit, old.rowID == new.rowID {
                entries[last].edit = .moveRow(new)
                return
            }
        }
        entries.append(PendingEdit(id: id, tripID: tripID, edit: edit, createdAt: now))
    }

    private func waitingAddNote(rowID: String, tripID: String) -> Int? {
        entries.lastIndex { entry in
            guard entry.isWaiting, entry.id != sending, entry.tripID == tripID, case .addNote(let add) = entry.edit else { return false }
            return add.rowID == rowID
        }
    }

    // MARK: Sending

    /// The next edit to send. Edits go strictly in order: after a temporary failure nothing is sent
    /// until the first waiting edit is due again. Conflicts and failures are skipped.
    public func next(at now: Date) -> PendingEdit? {
        guard let first = entries.first(where: \.isWaiting) else { return nil }
        if let notBefore = first.notBefore, notBefore > now { return nil }
        return first
    }

    /// Marks `id` as being sent, until its outcome is recorded.
    public mutating func markSending(_ id: UUID) {
        sending = id
    }

    /// When the first waiting edit may be sent again, if it is backing off.
    public var nextAttempt: Date? {
        entries.first(where: \.isWaiting)?.notBefore
    }

    /// Updates the outbox with the result of sending `id`.
    ///
    /// - Parameter sent: the edit as it was sent. If another edit was folded into the entry while
    ///   it was being sent, the entry stays to send the newer edit, instead of being removed.
    public mutating func record(_ outcome: SyncOutcome, for id: UUID, sent: TripEdit? = nil, at now: Date) {
        if sending == id { sending = nil }
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if case .added(let noteID, let rowID) = outcome {
            // Edits queued for the note while it was being sent now go to the server's ids.
            if case .addNote(let add) = sent ?? entries[index].edit {
                retarget(note: add.localID, row: add.rowID, toNote: noteID, row: rowID)
            }
            if let current = entries.firstIndex(where: { $0.id == id }) { entries.remove(at: current) }
            return
        }
        if let sent, entries[index].edit != sent {
            switch outcome {
            case .done, .dropped, .retry:
                // The newer edit still has to go. For a note, the server now holds what was sent.
                if case .editNote(let old) = sent, case .editNote(var newer) = entries[index].edit, outcome == .done {
                    newer.baseContent = old.content
                    entries[index].edit = .editNote(newer)
                }
                if case .editItem(let old) = sent, case .editItem(var newer) = entries[index].edit, outcome == .done {
                    newer.rebase(onSaved: old)
                    if newer.changes.isEmpty {
                        entries.remove(at: index)
                        return
                    }
                    entries[index].edit = .editItem(newer)
                }
                if case .retry = outcome {
                    break
                }
                entries[index].attempts = 0
                entries[index].notBefore = nil
                entries[index].lastError = nil
                return
            case .failed:
                // The refusal was for the older edit; the newer one still gets its own try.
                entries[index].attempts = 0
                entries[index].notBefore = nil
                entries[index].lastError = nil
                return
            case .conflict, .fieldConflict, .unauthorized, .added:
                break
            }
        }
        switch outcome {
        case .done, .added:
            entries.remove(at: index)
        case .dropped(let message):
            let entry = entries.remove(at: index)
            var kept: String?
            switch entry.edit {
            case .editNote(let edit): kept = edit.content
            case .appendNote(let edit): kept = edit.line
            case .addNote(let edit): kept = edit.content
            case .editItem(let edit): kept = edit.changes.compactMap { $0.field == .description || $0.field == .visitNotes ? $0.value.text : nil }.first
            default: break
            }
            notices.append(SyncNotice(tripID: entry.tripID, message: message, keptText: kept, createdAt: now))
        case .conflict(let conflict):
            entries[index].state = .conflict(conflict)
            entries[index].notBefore = nil
            entries[index].lastError = nil
        case .fieldConflict(let conflict):
            // The other fields were saved; only the clashing ones are left to decide.
            if case .editItem(var edit) = entries[index].edit {
                let clashing = Set(conflict.clashes.map(\.field))
                if case .editItem(let old) = sent ?? entries[index].edit {
                    // Fields that were sent and didn't clash are on the server now.
                    var saved = old
                    saved.changes.removeAll { clashing.contains($0.field) }
                    edit.rebase(onSaved: saved)
                }
                entries[index].edit = .editItem(edit)
            }
            entries[index].state = .fieldConflict(conflict)
            entries[index].notBefore = nil
            entries[index].lastError = nil
        case .retry(let message), .unauthorized(let message):
            entries[index].attempts += 1
            entries[index].lastError = message
            entries[index].notBefore = now.addingTimeInterval(Self.backoff(attempts: entries[index].attempts))
        case .failed(let message):
            entries[index].state = .failed(message)
            entries[index].lastError = message
            entries[index].notBefore = nil
        }
    }

    /// Points edits made to a note before it reached the server at the server's ids.
    private mutating func retarget(note localNote: String, row localRow: String, toNote noteID: String, row rowID: String) {
        for index in entries.indices {
            switch entries[index].edit {
            case .editNote(var edit) where edit.noteID == localNote:
                edit.noteID = noteID
                entries[index].edit = .editNote(edit)
            case .moveRow(var edit) where edit.rowID == localRow:
                edit.rowID = rowID
                entries[index].edit = .moveRow(edit)
            case .removeRow(var edit) where edit.rowID == localRow:
                edit.rowID = rowID
                entries[index].edit = .removeRow(edit)
            default:
                break
            }
        }
    }

    /// Seconds to wait after `attempts` failures in a row: 5, 10, 20, 40… up to 5 minutes.
    public static func backoff(attempts: Int) -> TimeInterval {
        let exponent = min(max(attempts - 1, 0), 10)
        return min(5 * pow(2, Double(exponent)), 300)
    }

    /// Sends waiting edits as soon as possible, e.g. when the connection comes back.
    public mutating func retryNow() {
        for index in entries.indices where entries[index].isWaiting {
            entries[index].notBefore = nil
        }
    }

    // MARK: The person's choices

    /// Keeps this phone's version of a conflicting note: it is sent again over the server's version
    /// that was shown. If the note changed yet again, that is a new conflict.
    public mutating func keepMine(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        switch (entries[index].state, entries[index].edit) {
        case (.conflict(let conflict), .editNote(var edit)):
            edit.baseContent = conflict.serverContent
            entries[index].edit = .editNote(edit)
        case (.fieldConflict(let conflict), .editItem(var edit)):
            for clash in conflict.clashes {
                if let change = edit.changes.firstIndex(where: { $0.field == clash.field }) { edit.changes[change].base = clash.server }
            }
            entries[index].edit = .editItem(edit)
        default:
            return
        }
        entries[index].state = .waiting
        entries[index].attempts = 0
        entries[index].notBefore = nil
    }

    /// Sends a failed edit again.
    public mutating func retry(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].state = .waiting
        entries[index].attempts = 0
        entries[index].notBefore = nil
        entries[index].lastError = nil
    }

    /// Forgets an edit: "keep theirs" for a conflict, or giving up on a failure.
    public mutating func discard(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    public mutating func dismissNotice(_ id: UUID) {
        notices.removeAll { $0.id == id }
    }

    // MARK: Reading

    /// The edits to show on a trip: waiting ones and conflicts (the person's version), in order.
    /// Failed edits are left off, since the server refused them.
    public func visibleEdits(for tripID: String) -> [TripEdit] {
        entries.filter { entry in
            guard entry.tripID == tripID else { return false }
            if case .failed = entry.state { return false }
            return true
        }.map(\.edit)
    }

    /// Edits still to send.
    public var waitingCount: Int { entries.filter(\.isWaiting).count }

    /// Conflicts, failures and notices the person should look at.
    public var attentionCount: Int { entries.count - waitingCount + notices.count }

    public func waitingCount(for tripID: String) -> Int {
        entries.filter { $0.isWaiting && $0.tripID == tripID }.count
    }

    public func attentionCount(for tripID: String) -> Int {
        entries.filter { !$0.isWaiting && $0.tripID == tripID }.count + notices.filter { $0.tripID == tripID }.count
    }

    /// Whether an item has an edit that hasn't reached the server.
    public func hasWaitingEdit(forItem itemID: String, tripID: String) -> Bool {
        entries.contains { entry in
            guard entry.tripID == tripID, entry.isWaiting else { return false }
            switch entry.edit {
            case .checkItem(let edit): return edit.checklistID == itemID
            case .editNote(let edit): return edit.noteID == itemID
            case .editItem(let edit): return edit.itemID == itemID
            case .appendNote(let edit): return edit.itemID == itemID
            case .addNote(let edit): return edit.localID == itemID
            case .moveRow, .removeRow: return false
            }
        }
    }

    public var isEmpty: Bool { entries.isEmpty && notices.isEmpty }
}
