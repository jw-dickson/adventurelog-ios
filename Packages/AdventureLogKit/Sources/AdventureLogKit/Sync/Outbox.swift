// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// An edit waiting for the server, or one that needs the person's attention.
public struct PendingEdit: Codable, Sendable, Hashable, Identifiable {
    public enum State: Codable, Sendable, Hashable {
        /// Will be sent when the server can be reached.
        case waiting
        /// Someone else changed the same note. Shown as the person's version until they choose.
        case conflict(NoteConflict)
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
            if let index = entries.lastIndex(where: { entry in
                guard entry.isWaiting, entry.tripID == tripID, case .checkItem(let old) = entry.edit else { return false }
                return old.sameItem(as: new)
            }) {
                entries[index].edit = .checkItem(new)
                return
            }

        case .editNote(let new):
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

        case .moveRow(let new):
            // Only the very last edit, so other moves made in between still replay in order.
            if let last = entries.indices.last, entries[last].isWaiting, entries[last].tripID == tripID,
               case .moveRow(let old) = entries[last].edit, old.rowID == new.rowID {
                entries[last].edit = .moveRow(new)
                return
            }
        }
        entries.append(PendingEdit(id: id, tripID: tripID, edit: edit, createdAt: now))
    }

    // MARK: Sending

    /// The next edit to send. Edits go strictly in order: after a temporary failure nothing is sent
    /// until the first waiting edit is due again. Conflicts and failures are skipped.
    public func next(at now: Date) -> PendingEdit? {
        guard let first = entries.first(where: \.isWaiting) else { return nil }
        if let notBefore = first.notBefore, notBefore > now { return nil }
        return first
    }

    /// When the first waiting edit may be sent again, if it is backing off.
    public var nextAttempt: Date? {
        entries.first(where: \.isWaiting)?.notBefore
    }

    /// Updates the outbox with the result of sending `id`.
    public mutating func record(_ outcome: SyncOutcome, for id: UUID, at now: Date) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        switch outcome {
        case .done:
            entries.remove(at: index)
        case .dropped(let message):
            let entry = entries.remove(at: index)
            var kept: String?
            if case .editNote(let edit) = entry.edit { kept = edit.content }
            notices.append(SyncNotice(tripID: entry.tripID, message: message, keptText: kept, createdAt: now))
        case .conflict(let conflict):
            entries[index].state = .conflict(conflict)
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
        guard let index = entries.firstIndex(where: { $0.id == id }),
              case .conflict(let conflict) = entries[index].state,
              case .editNote(var edit) = entries[index].edit
        else { return }
        edit.baseContent = conflict.serverContent
        entries[index].edit = .editNote(edit)
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
            case .moveRow: return false
            }
        }
    }

    public var isEmpty: Bool { entries.isEmpty && notices.isEmpty }
}
