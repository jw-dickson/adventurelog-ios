// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A field of a place, journey or stay that can be edited in the app.
///
/// A place's fields live on two server objects: the location (name, notes about the place,
/// address, link) and this trip's visit to it (start, end and notes for the visit).
public enum ItemField: String, Codable, Sendable, Hashable, CaseIterable {
    case name
    /// Notes: a journey's or stay's description, a place's general description.
    case description
    case link
    /// Free-text address (a place's or stay's `location`).
    case address
    /// Notes for this visit to a place.
    case visitNotes
    /// A visit's start, a journey's departure, a stay's check-in.
    case start
    /// A visit's end, a journey's arrival, a stay's check-out.
    case end
    case flightNumber
    case reservationNumber

    /// The fields each kind of item has.
    public static func fields(for kind: ItemKind) -> [ItemField] {
        switch kind {
        case .location: return [.name, .description, .link, .address, .visitNotes, .start, .end]
        case .transportation: return [.name, .description, .link, .start, .end, .flightNumber]
        case .lodging: return [.name, .description, .link, .address, .start, .end, .reservationNumber]
        default: return []
        }
    }

    /// For a place: whether the field is stored on its visit rather than on the place itself.
    public var isOnVisit: Bool { self == .visitNotes || self == .start || self == .end }

    /// How the field is named in the app, for conflicts: "start time", "notes".
    public func label(for kind: ItemKind) -> String {
        switch self {
        case .name: return "name"
        case .description: return kind == .location ? "place notes" : "notes"
        case .link: return "link"
        case .address: return "address"
        case .visitNotes: return "notes"
        case .start:
            switch kind {
            case .transportation: return "departure"
            case .lodging: return "check-in"
            default: return "start time"
            }
        case .end:
            switch kind {
            case .transportation: return "arrival"
            case .lodging: return "check-out"
            default: return "end time"
            }
        case .flightNumber: return "flight number"
        case .reservationNumber: return "booking reference"
        }
    }

    /// The JSON key on the server object that holds this field.
    func wireKey(for kind: ItemKind) -> String {
        switch self {
        case .name: return "name"
        case .description: return "description"
        case .link: return "link"
        case .address: return "location"
        case .visitNotes: return "notes"
        case .start:
            switch kind {
            case .transportation: return "date"
            case .lodging: return "check_in"
            default: return "start_date"
            }
        case .end:
            switch kind {
            case .transportation: return "end_date"
            case .lodging: return "check_out"
            default: return "end_date"
            }
        case .flightNumber: return "flight_number"
        case .reservationNumber: return "reservation_number"
        }
    }

    var isTime: Bool { self == .start || self == .end }
}

/// A field's value: text for most fields, an instant for times. Blank text counts as no value.
public enum FieldValue: Codable, Sendable, Hashable {
    case text(String?)
    case time(Date?)

    /// Treats "", whitespace and nil as the same empty value, and compares times to the second
    /// (the server keeps whole seconds).
    public func matches(_ other: FieldValue) -> Bool {
        switch (self, other) {
        case (.text(let a), .text(let b)):
            return Self.clean(a) == Self.clean(b)
        case (.time(let a), .time(let b)):
            return a.map { $0.timeIntervalSince1970.rounded() } == b.map { $0.timeIntervalSince1970.rounded() }
        default:
            return false
        }
    }

    public var text: String? {
        if case .text(let value) = self { return Self.clean(value) }
        return nil
    }

    public var time: Date? {
        if case .time(let value) = self { return value }
        return nil
    }

    /// `text`, or `nil` when it's empty or only whitespace.
    public static func clean(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }
}

/// One field's change: the value it started from and the new value.
public struct FieldChange: Codable, Sendable, Hashable {
    public var field: ItemField
    /// What the field held when the edit was made. If the server has something else when the edit
    /// is sent, someone else changed it and the person chooses.
    public var base: FieldValue
    public var value: FieldValue

    public init(field: ItemField, base: FieldValue, value: FieldValue) {
        self.field = field
        self.base = base
        self.value = value
    }
}

/// A field where the server's value differs from both the edit's starting point and the edit.
public struct FieldClash: Codable, Sendable, Hashable {
    public var field: ItemField
    public var server: FieldValue

    public init(field: ItemField, server: FieldValue) {
        self.field = field
        self.server = server
    }
}

/// Someone else changed fields this edit also changes. The edit's other fields were saved.
public struct FieldConflict: Codable, Sendable, Hashable {
    public var clashes: [FieldClash]

    public init(clashes: [FieldClash]) {
        self.clashes = clashes
    }
}

extension TripEdit {
    /// Change fields of a place, journey or stay.
    public struct EditItem: Codable, Sendable, Hashable {
        public var kind: ItemKind
        public var itemID: String
        /// This trip's visit, for a place's visit fields.
        public var visitID: String?
        public var title: String
        public var changes: [FieldChange]

        public init(kind: ItemKind, itemID: String, visitID: String?, title: String, changes: [FieldChange]) {
            self.kind = kind
            self.itemID = itemID
            self.visitID = visitID
            self.title = title
            self.changes = changes
        }

        /// The edit that turns `item` into the given values, keeping only fields that changed.
        /// `nil` when nothing changed or the item can't be edited.
        public init?(item: TripPlan.Item, visitID: String?, values: [ItemField: FieldValue]) {
            guard let kind = Self.editableKind(item) else { return nil }
            let changes = ItemField.fields(for: kind).compactMap { field -> FieldChange? in
                guard let value = values[field], let base = ItemValues.read(field, of: item, visitID: visitID),
                      !value.matches(base) else { return nil }
                // A place's times and visit notes need its visit; journeys and stays keep theirs on the item.
                if kind == .location, field.isOnVisit, visitID == nil { return nil }
                return FieldChange(field: field, base: base, value: value)
            }
            guard !changes.isEmpty else { return nil }
            self.init(kind: kind, itemID: item.id, visitID: visitID, title: item.title, changes: changes)
        }

        /// The kind of edit an item takes, or `nil` for notes, checklists and missing items.
        public static func editableKind(_ item: TripPlan.Item) -> ItemKind? {
            switch item {
            case .location: return .location
            case .transportation: return .transportation
            case .lodging: return .lodging
            default: return nil
            }
        }

        /// Whether `other` edits the same item.
        func sameItem(as other: EditItem) -> Bool {
            kind == other.kind && itemID == other.itemID
        }

        /// After `saved` reached the server: its fields now start from what was saved, and any
        /// that still hold that value are done.
        mutating func rebase(onSaved saved: EditItem) {
            for done in saved.changes {
                guard let index = changes.firstIndex(where: { $0.field == done.field }) else { continue }
                changes[index].base = done.value
            }
            changes.removeAll { $0.value.matches($0.base) }
        }

        /// Folds a later edit of the same item into this one: each field keeps the earliest
        /// starting point and the latest value; fields edited back to where they started go.
        mutating func absorb(_ later: EditItem) {
            title = later.title
            visitID = visitID ?? later.visitID
            for change in later.changes {
                if let index = changes.firstIndex(where: { $0.field == change.field }) {
                    changes[index].value = change.value
                } else {
                    changes.append(change)
                }
            }
            changes.removeAll { $0.value.matches($0.base) }
        }
    }

    /// Add a line to the end of an item's notes. Never conflicts: it goes after whatever the
    /// server's notes say when it is sent.
    public struct AppendNote: Codable, Sendable, Hashable {
        public var kind: ItemKind
        public var itemID: String
        /// For a place: the visit whose notes get the line. Without one, the place's own notes do.
        public var visitID: String?
        public var title: String
        /// The finished line, e.g. "**10:42** · Moved to the 13:00 slot."
        public var line: String

        public init(kind: ItemKind, itemID: String, visitID: String?, title: String, line: String) {
            self.kind = kind
            self.itemID = itemID
            self.visitID = visitID
            self.title = title
            self.line = line
        }

        /// The field the line goes into.
        public var field: ItemField { kind == .location && visitID != nil ? .visitNotes : .description }

        /// `text` with the line added after a blank line.
        public func appended(to text: String?) -> String {
            guard let existing = FieldValue.clean(text) else { return line }
            var trimmed = existing
            while trimmed.last?.isNewline == true { trimmed.removeLast() }
            return trimmed + "\n\n" + line
        }

        /// Whether `text` already ends with this line, i.e. it was sent before.
        func isIn(_ text: String?) -> Bool {
            guard let text else { return false }
            return text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(line.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        /// The line as a timestamped entry: "**10:42** · text", the time in `zone`.
        public static func line(_ text: String, at date: Date, in zone: TimeZone) -> String {
            let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: Locale(identifier: "en_GB"), timeZone: zone)
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "**\(date.formatted(style))** · \(clean)"
        }
    }

    /// A new note on a day (or trip-wide), made on the phone. Until it is sent it has a local id.
    public struct AddNote: Codable, Sendable, Hashable {
        /// The note's id on this phone, `local-…`; its row is `local-row-…`.
        public var localID: String
        public var name: String
        public var content: String
        /// `nil` for trip-wide.
        public var date: CalendarDate?

        public init(localID: String = "local-" + UUID().uuidString.lowercased(), name: String, content: String, date: CalendarDate?) {
            self.localID = localID
            self.name = name
            self.content = content
            self.date = date
        }

        public var rowID: String { "local-row-" + localID.dropFirst("local-".count) }

        public var title: String { FieldValue.clean(name) ?? "Note" }

        public static func isLocal(_ id: String) -> Bool { id.hasPrefix("local-") }
    }

    /// Take a row off its day. The item stays in the trip, under Not on a day, and a place keeps
    /// its visit.
    public struct RemoveRow: Codable, Sendable, Hashable {
        public var rowID: String
        public var title: String
        public var date: CalendarDate?

        public init(rowID: String, title: String, date: CalendarDate?) {
            self.rowID = rowID
            self.title = title
            self.date = date
        }
    }
}

/// Reads and writes item fields on the trip's copies of places, journeys and stays.
public enum ItemValues {
    /// The field's value on a planned item. `nil` when the item doesn't have the field (or a visit
    /// field is asked for without a visit).
    public static func read(_ field: ItemField, of item: TripPlan.Item, visitID: String?) -> FieldValue? {
        switch item {
        case .location(let place, let visits):
            if field.isOnVisit {
                guard let visit = visits.first(where: { $0.id == visitID }) ?? place.visits.first(where: { $0.id == visitID }) else { return nil }
                return read(field, of: visit)
            }
            return read(field, of: place)
        case .transportation(let leg): return read(field, of: leg)
        case .lodging(let stay): return read(field, of: stay)
        default: return nil
        }
    }

    static func read(_ field: ItemField, of place: Location) -> FieldValue? {
        switch field {
        case .name: return .text(place.name)
        case .description: return .text(place.description)
        case .link: return .text(place.link)
        case .address: return .text(place.location)
        default: return nil
        }
    }

    static func read(_ field: ItemField, of visit: Visit) -> FieldValue? {
        switch field {
        case .visitNotes: return .text(visit.notes)
        case .start: return .time(visit.startDate)
        case .end: return .time(visit.endDate)
        default: return nil
        }
    }

    static func read(_ field: ItemField, of leg: Transportation) -> FieldValue? {
        switch field {
        case .name: return .text(leg.name)
        case .description: return .text(leg.description)
        case .link: return .text(leg.link)
        case .start: return .time(leg.date)
        case .end: return .time(leg.endDate)
        case .flightNumber: return .text(leg.flightNumber)
        default: return nil
        }
    }

    static func read(_ field: ItemField, of stay: Lodging) -> FieldValue? {
        switch field {
        case .name: return .text(stay.name)
        case .description: return .text(stay.description)
        case .link: return .text(stay.link)
        case .address: return .text(stay.location)
        case .start: return .time(stay.checkIn)
        case .end: return .time(stay.checkOut)
        case .reservationNumber: return .text(stay.reservationNumber)
        default: return nil
        }
    }

    static func write(_ value: FieldValue, to field: ItemField, of place: inout Location) {
        switch field {
        case .name: if let text = value.text { place.name = text }
        case .description: place.description = value.text
        case .link: place.link = value.text
        case .address: place.location = value.text
        default: break
        }
    }

    static func write(_ value: FieldValue, to field: ItemField, of visit: inout Visit) {
        switch field {
        case .visitNotes: visit.notes = value.text
        case .start: visit.startDate = value.time
        case .end: visit.endDate = value.time
        default: break
        }
    }

    static func write(_ value: FieldValue, to field: ItemField, of leg: inout Transportation) {
        switch field {
        case .name: if let text = value.text { leg.name = text }
        case .description: leg.description = value.text
        case .link: leg.link = value.text
        case .start: leg.date = value.time
        case .end: leg.endDate = value.time
        case .flightNumber: leg.flightNumber = value.text
        default: break
        }
    }

    static func write(_ value: FieldValue, to field: ItemField, of stay: inout Lodging) {
        switch field {
        case .name: if let text = value.text { stay.name = text }
        case .description: stay.description = value.text
        case .link: stay.link = value.text
        case .address: stay.location = value.text
        case .start: stay.checkIn = value.time
        case .end: stay.checkOut = value.time
        case .reservationNumber: stay.reservationNumber = value.text
        default: break
        }
    }

    /// Sets fields on the trip's copy of an item. A missing item or visit leaves the trip as it is.
    public static func write(_ values: [(ItemField, FieldValue)], kind: ItemKind, itemID: String, visitID: String?, in trip: inout CollectionDetail) {
        switch kind {
        case .location:
            guard let index = trip.locations.firstIndex(where: { $0.id == itemID }) else { return }
            for (field, value) in values {
                if field.isOnVisit {
                    guard let visit = trip.locations[index].visits.firstIndex(where: { $0.id == visitID }) else { continue }
                    write(value, to: field, of: &trip.locations[index].visits[visit])
                } else {
                    write(value, to: field, of: &trip.locations[index])
                }
            }
        case .transportation:
            guard let index = trip.transportations.firstIndex(where: { $0.id == itemID }) else { return }
            for (field, value) in values { write(value, to: field, of: &trip.transportations[index]) }
        case .lodging:
            guard let index = trip.lodging.firstIndex(where: { $0.id == itemID }) else { return }
            for (field, value) in values { write(value, to: field, of: &trip.lodging[index]) }
        default:
            return
        }
    }

    /// The field's value on the trip's copy of an item.
    public static func read(_ field: ItemField, kind: ItemKind, itemID: String, visitID: String?, in trip: CollectionDetail) -> FieldValue? {
        switch kind {
        case .location:
            guard let place = trip.locations.first(where: { $0.id == itemID }) else { return nil }
            if field.isOnVisit {
                guard let visit = place.visits.first(where: { $0.id == visitID }) else { return nil }
                return read(field, of: visit)
            }
            return read(field, of: place)
        case .transportation:
            return trip.transportations.first(where: { $0.id == itemID }).flatMap { read(field, of: $0) }
        case .lodging:
            return trip.lodging.first(where: { $0.id == itemID }).flatMap { read(field, of: $0) }
        default:
            return nil
        }
    }
}

extension TripPlan.Item {
    /// The visit whose times and notes a place's edits change: the one placed on this day, else the
    /// earliest (the same one `ItemSummary` shows).
    public var editableVisit: Visit? {
        guard case .location(let place, let visits) = self else { return nil }
        return visits.first ?? place.visits.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }.first
    }
}
