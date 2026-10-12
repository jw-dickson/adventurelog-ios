// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A change the person made to a trip, kept until the server has it.
///
/// Edits record intent ("tick *Check the spare tyre*", "put the cruise second on 8 Mar"), not the
/// payload to send. When an edit is sent it is replayed onto the server's current copy, so two
/// phones editing one trip don't undo each other's changes.
public enum TripEdit: Codable, Sendable, Hashable {
    case checkItem(CheckItem)
    case editNote(EditNote)
    case moveRow(MoveRow)
    case editItem(EditItem)
    case appendNote(AppendNote)
    case addNote(AddNote)
    case removeRow(RemoveRow)

    /// Tick or untick one checklist item.
    public struct CheckItem: Codable, Sendable, Hashable {
        public var checklistID: String
        public var checklistName: String
        /// The item's id when the edit was made. AdventureLog gives every item a new id whenever the
        /// checklist is saved, so the name and its occurrence are what find it later.
        public var itemID: String
        public var itemName: String
        /// 0 for the first item with this name, 1 for the second, and so on.
        public var occurrence: Int
        public var isChecked: Bool

        public init(checklistID: String, checklistName: String, itemID: String, itemName: String, occurrence: Int, isChecked: Bool) {
            self.checklistID = checklistID
            self.checklistName = checklistName
            self.itemID = itemID
            self.itemName = itemName
            self.occurrence = occurrence
            self.isChecked = isChecked
        }

        /// The edit for `item` in `checklist`, with its occurrence worked out.
        public init?(checklist: Checklist, itemID: String, isChecked: Bool) {
            guard let index = checklist.items.firstIndex(where: { $0.id == itemID }) else { return nil }
            let item = checklist.items[index]
            let occurrence = checklist.items[..<index].filter { $0.name == item.name }.count
            self.init(checklistID: checklist.id, checklistName: checklist.name, itemID: item.id,
                      itemName: item.name, occurrence: occurrence, isChecked: isChecked)
        }

        /// Where this item is in `items`: by id first, then by name and occurrence.
        public func index(in items: [ChecklistItem]) -> Int? {
            if let index = items.firstIndex(where: { $0.id == itemID }) { return index }
            let named = items.indices.filter { items[$0].name == itemName }
            return occurrence < named.count ? named[occurrence] : nil
        }

        /// Whether `other` targets the same item.
        func sameItem(as other: CheckItem) -> Bool {
            checklistID == other.checklistID && (itemID == other.itemID || (itemName == other.itemName && occurrence == other.occurrence))
        }
    }

    /// Replace a note's text.
    public struct EditNote: Codable, Sendable, Hashable {
        public var noteID: String
        public var noteName: String
        /// The text the edit started from. If the server's text is neither this nor `content`,
        /// someone else changed the note meanwhile and the person chooses which to keep.
        public var baseContent: String
        public var content: String

        public init(noteID: String, noteName: String, baseContent: String, content: String) {
            self.noteID = noteID
            self.noteName = noteName
            self.baseContent = baseContent
            self.content = content
        }
    }

    /// Put an itinerary row at a position on a day, or trip-wide. Covers reordering within a day
    /// and moving between days. The item's own dates don't change (AdventureLog's reorder never
    /// touches them).
    public struct MoveRow: Codable, Sendable, Hashable {
        public var rowID: String
        public var title: String
        /// `nil` puts the row trip-wide.
        public var toDate: CalendarDate?
        /// Position among the destination's other rows; clamped to the end.
        public var toIndex: Int

        public init(rowID: String, title: String, toDate: CalendarDate?, toIndex: Int) {
            self.rowID = rowID
            self.title = title
            self.toDate = toDate
            self.toIndex = toIndex
        }
    }

    /// A short line for lists of changes: "Tick “Check the spare tyre”".
    public var summary: String {
        switch self {
        case .checkItem(let edit):
            return edit.isChecked ? "Tick “\(edit.itemName)”" : "Untick “\(edit.itemName)”"
        case .editNote(let edit):
            return "Edit “\(edit.noteName)”"
        case .moveRow(let edit):
            return "Move “\(edit.title)”"
        case .editItem(let edit):
            return "Edit “\(edit.title)”"
        case .appendNote(let edit):
            return "Add a note to “\(edit.title)”"
        case .addNote(let edit):
            return "Add “\(edit.title)”"
        case .removeRow(let edit):
            return "Remove “\(edit.title)” from its day"
        }
    }

    /// Shows the edit on a copy of the trip before the server has it. An edit whose target is gone
    /// leaves the trip unchanged.
    public func apply(to trip: inout CollectionDetail) {
        switch self {
        case .checkItem(let edit):
            guard let list = trip.checklists.firstIndex(where: { $0.id == edit.checklistID }),
                  let item = edit.index(in: trip.checklists[list].items)
            else { return }
            trip.checklists[list].items[item].isChecked = edit.isChecked

        case .editNote(let edit):
            guard let note = trip.notes.firstIndex(where: { $0.id == edit.noteID }) else { return }
            trip.notes[note].content = edit.content

        case .moveRow(let edit):
            if let moved = ItineraryLayout.move(edit.rowID, to: edit.toDate, at: edit.toIndex, in: trip.itinerary) {
                trip.itinerary = moved.rows
            }

        case .editItem(let edit):
            ItemValues.write(edit.changes.map { ($0.field, $0.value) }, kind: edit.kind, itemID: edit.itemID, visitID: edit.visitID, in: &trip)

        case .appendNote(let edit):
            guard let current = ItemValues.read(edit.field, kind: edit.kind, itemID: edit.itemID, visitID: edit.visitID, in: trip),
                  !edit.isIn(current.text) else { return }
            ItemValues.write([(edit.field, .text(edit.appended(to: current.text)))], kind: edit.kind, itemID: edit.itemID, visitID: edit.visitID, in: &trip)

        case .addNote(let edit):
            guard !trip.notes.contains(where: { $0.id == edit.localID }) else { return }
            trip.notes.append(Note(id: edit.localID, user: nil, name: edit.title, content: edit.content, date: edit.date,
                                   links: DefaultEmpty(wrappedValue: []), isPublic: false, collection: trip.id,
                                   createdAt: nil, updatedAt: nil))
            let order = (ItineraryLayout.group(edit.date, in: trip.itinerary).map(\.order).max() ?? -1) + 1
            trip.itinerary.append(ItineraryRow(id: edit.rowID, collection: trip.id, objectId: edit.localID,
                                               item: .init(id: edit.localID, type: .note), objectName: "note",
                                               date: edit.date, isGlobal: edit.date == nil, order: order,
                                               startDatetime: nil, endDatetime: nil))

        case .removeRow(let edit):
            trip.itinerary.removeAll { $0.id == edit.rowID }
        }
    }
}

extension CollectionDetail {
    /// This trip with `edits` applied in order.
    public func applying(_ edits: [TripEdit]) -> CollectionDetail {
        var copy = self
        for edit in edits { edit.apply(to: &copy) }
        return copy
    }
}

/// The ordering rules for itinerary rows, shared by the phone's own copy and what is sent.
public enum ItineraryLayout {
    public struct Moved: Sendable, Hashable {
        /// Every row, with the move applied.
        public var rows: [ItineraryRow]
        /// The rows whose day or order changed: what a reorder request has to carry.
        public var changed: [ItineraryRow]
    }

    /// The rows sharing a day (or trip-wide when `date` is nil), in display order.
    public static func group(_ date: CalendarDate?, in rows: [ItineraryRow]) -> [ItineraryRow] {
        rows.filter { key($0) == date }.sorted { ($0.order, $0.id) < ($1.order, $1.id) }
    }

    /// The day a row is on, or `nil` for trip-wide.
    public static func key(_ row: ItineraryRow) -> CalendarDate? {
        row.isGlobal ? nil : row.date
    }

    /// Takes row `id` out of its day and puts it at `index` on `date`, numbering both days from 0.
    /// Returns `nil` when the row doesn't exist.
    public static func move(_ id: String, to date: CalendarDate?, at index: Int, in rows: [ItineraryRow]) -> Moved? {
        guard var row = rows.first(where: { $0.id == id }) else { return nil }
        let from = key(row)
        let rest = rows.filter { $0.id != id }

        var destination = group(date, in: rest)
        row.date = date
        row.isGlobal = date == nil
        destination.insert(row, at: min(max(index, 0), destination.count))
        var touched = renumber(destination)
        if from != date { touched += renumber(group(from, in: rest)) }

        let original = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = touched.filter { original[$0.id] != $0 }
        let ids = Set(touched.map(\.id))
        return Moved(rows: rest.filter { !ids.contains($0.id) } + touched, changed: changed)
    }

    /// The reorder request that makes the server's rows match `moved`.
    public static func request(for moved: Moved) -> ItineraryReorderRequest? {
        guard !moved.changed.isEmpty else { return nil }
        return ItineraryReorderRequest(items: moved.changed.map {
            ItineraryReorderRequest.Entry(id: $0.id, date: key($0), order: $0.order)
        })
    }

    private static func renumber(_ rows: [ItineraryRow]) -> [ItineraryRow] {
        rows.enumerated().map { index, row in
            var copy = row
            copy.order = index
            return copy
        }
    }
}
