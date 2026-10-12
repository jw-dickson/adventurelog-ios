// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Everything a timeline row, the item detail screen and the map need to know about one
/// itinerary item, worked out once from AdventureLog's raw fields.
///
/// Times stay as UTC instants paired with the zone they belong to; the text helpers format them
/// in that zone, never the device's.
public struct ItemSummary: Sendable, Hashable, Identifiable {
    public struct Coordinate: Sendable, Hashable {
        public let latitude: Double
        public let longitude: Double

        public init?(_ latitude: Double?, _ longitude: Double?) {
            guard let latitude, let longitude, (-90...90).contains(latitude), (-180...180).contains(longitude),
                  !(latitude == 0 && longitude == 0)
            else { return nil }
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    public let id: String
    public let kind: ItemKind
    public let title: String
    /// SF Symbol name.
    public let symbol: String
    /// The category emoji a person picked for a location in AdventureLog.
    public let categoryIcon: String?
    public let categoryName: String?

    public let start: Date?
    public let end: Date?
    public let startZone: TimeZone
    public let endZone: TimeZone
    public let isAllDay: Bool
    /// The itinerary day the row sits on, when it sits on one.
    public let day: CalendarDate?

    /// A one-line description under the title.
    public let detail: String?
    /// A flight number or reservation number, shown in monospace and copied on tap.
    public let reference: String?
    /// Booked items are fixed: they show the accent colour and are never moved by a replan.
    public let isBooked: Bool

    public let coordinate: Coordinate?
    /// Where a transport leg ends.
    public let destination: Coordinate?
    public let address: String?
    public let link: URL?
    /// Free text: a location's description and visit notes, a note's content, a stay's description.
    public let notes: String?
    public let checklist: [ChecklistItem]
    public let imageURL: URL?

    public init(_ item: TripPlan.Item, day: CalendarDate?, tripZone: TimeZone) {
        self.id = item.id
        self.kind = item.kind
        self.title = item.title
        self.day = day

        var categoryIcon: String?
        var categoryName: String?
        var start: Date?
        var end: Date?
        var startZone = tripZone
        var endZone = tripZone
        var detail: String?
        var reference: String?
        var isBooked = false
        var coordinate: Coordinate?
        var destination: Coordinate?
        var address: String?
        var link: String?
        var notes: String?
        var checklist: [ChecklistItem] = []
        var imageURL: URL?

        switch item {
        case .location(let place, let visits):
            symbol = "mappin.and.ellipse"
            categoryIcon = place.category?.icon?.nilIfBlank
            categoryName = place.category?.displayName.nilIfBlank
            let visit = visits.first ?? place.visits.sorted { ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture) }.first
            if let visit {
                start = visit.startDate
                end = visit.endDate
                startZone = TripTime.zone(visit.timezone, fallback: tripZone)
                endZone = startZone
            }
            detail = [categoryName, place.location?.nilIfBlank].compactMap { $0 }.joined(separator: " · ").nilIfBlank
            isBooked = place.tags.contains { ItemSummary.bookedTags.contains($0.lowercased()) }
            coordinate = Coordinate(place.latitude, place.longitude)
            address = place.location?.nilIfBlank
            link = place.link
            notes = [place.description?.nilIfBlank, visit?.notes?.nilIfBlank].compactMap { $0 }.joined(separator: "\n\n").nilIfBlank
            imageURL = place.primaryImage?.url

        case .transportation(let leg):
            symbol = ItemSummary.symbol(for: leg.type)
            start = leg.date
            end = leg.endDate
            startZone = TripTime.zone(leg.startTimezone, fallback: tripZone)
            endZone = TripTime.zone(leg.endTimezone, fallback: startZone)
            var parts: [String] = []
            if let from = leg.startCode?.nilIfBlank ?? leg.fromLocation?.nilIfBlank,
               let to = leg.endCode?.nilIfBlank ?? leg.toLocation?.nilIfBlank,
               from != to, !(leg.name.contains(from) && leg.name.contains(to)) {
                parts.append("\(from) → \(to)")
            }
            // A day or more (a car hire) reads better as the end date under the time than as "361 h".
            if let minutes = leg.travelDurationMinutes, minutes > 0, minutes < 24 * 60 {
                parts.append(ItemSummary.durationText(minutes: minutes))
            }
            if let km = leg.distance, km >= 1, leg.type != .plane {
                parts.append("\(Int(km.rounded())) km")
            }
            detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
            reference = leg.flightNumber?.nilIfBlank
            isBooked = reference != nil
            coordinate = Coordinate(leg.originLatitude, leg.originLongitude)
            destination = Coordinate(leg.destinationLatitude, leg.destinationLongitude)
            address = leg.fromLocation?.nilIfBlank
            link = leg.link
            notes = leg.description?.nilIfBlank
            imageURL = leg.images.first(where: \.isPrimary)?.url ?? leg.images.first?.url

        case .lodging(let stay):
            symbol = stay.type == .campground ? "tent.fill" : "bed.double.fill"
            // A stay saved with check-out before check-in keeps only its check-in.
            start = stay.checkIn
            end = stay.hasValidStay ? stay.checkOut : nil
            startZone = TripTime.zone(stay.timezone, fallback: tripZone)
            endZone = startZone
            detail = [stay.type.flatMap { $0 == .other ? nil : $0.rawValue.capitalized }, stay.location?.nilIfBlank]
                .compactMap { $0 }.joined(separator: " · ").nilIfBlank
            reference = stay.reservationNumber?.nilIfBlank
            isBooked = reference != nil
            coordinate = Coordinate(stay.latitude, stay.longitude)
            address = stay.location?.nilIfBlank
            link = stay.link
            notes = stay.description?.nilIfBlank
            imageURL = stay.images.first(where: \.isPrimary)?.url ?? stay.images.first?.url

        case .note(let note):
            symbol = "note.text"
            detail = note.content?.split(whereSeparator: \.isNewline).first.map(String.init)?.nilIfBlank
            notes = note.content?.nilIfBlank
            link = note.links.first

        case .checklist(let list):
            symbol = "checklist"
            detail = "\(list.checkedCount) of \(list.items.count) done"
            checklist = list.items

        case .missing:
            symbol = "questionmark.circle"
            detail = "Not in this trip any more"
        }

        self.categoryIcon = categoryIcon
        self.categoryName = categoryName
        self.start = start
        self.end = end
        self.startZone = startZone
        self.endZone = endZone
        self.isAllDay = TripTime.isAllDay(start: start, end: end)
        self.detail = detail
        self.reference = reference
        self.isBooked = isBooked
        self.coordinate = coordinate
        self.destination = destination
        self.address = address
        self.link = link.flatMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        self.notes = notes
        self.checklist = checklist
        self.imageURL = imageURL
    }

    /// Location tags that mark a place as booked, until the companion service adds a real flag.
    public static let bookedTags: Set<String> = ["booked", "fixed", "reserved"]

    public static func symbol(for type: TransportationType) -> String {
        switch type {
        case .plane: return "airplane"
        case .car: return "car.fill"
        case .train: return "tram.fill"
        case .bus: return "bus.fill"
        case .boat: return "ferry.fill"
        case .bike: return "bicycle"
        case .walking: return "figure.walk"
        case .other: return "arrow.triangle.swap"
        }
    }

    /// "45 min", "2 h", "12 h 25 min".
    public static func durationText(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }

    // MARK: Time text

    /// Days between the row's day and the local start date: 1 for a 01:30 tour on the evening's row.
    public var startOffsetDays: Int {
        guard let start, let day, !isAllDay else { return 0 }
        return TripTime.dayOffset(of: start, in: startZone, from: day)
    }

    /// Days between the local start date and the local end date.
    public var spanDays: Int {
        guard let start, let end else { return 0 }
        if isAllDay { return CalendarDate(end, in: .gmt).days(since: CalendarDate(start, in: .gmt)) }
        return TripTime.localDate(of: end, in: endZone).days(since: TripTime.localDate(of: start, in: startZone))
    }

    /// The main time in the timeline's time column, or "All day".
    public func startText(locale: Locale = .autoupdatingCurrent) -> String? {
        guard let start else { return nil }
        if isAllDay { return "All day" }
        return TripTime.shortTime(start, in: startZone, locale: locale)
    }

    /// The small line under the time: "+1 day" when the item starts on a later date than its row,
    /// otherwise the end time, or the end date ("23 Mar") when it ends on a later date.
    public func secondaryTimeText(locale: Locale = .autoupdatingCurrent) -> String? {
        if let label = TripTime.offsetLabel(startOffsetDays) { return label }
        guard let end, !isAllDay else { return nil }
        if spanDays == 0 { return TripTime.shortTime(end, in: endZone, locale: locale) }
        let style = Date.FormatStyle(locale: locale, calendar: Calendar(identifier: .gregorian), timeZone: endZone).day().month(.abbreviated)
        return end.formatted(style)
    }

    /// A full line for the detail screen: "Mon 8 Mar · 18:30–20:30 AEDT".
    public func whenText(locale: Locale = .autoupdatingCurrent) -> String? {
        guard let start else { return nil }
        let calendar = Calendar(identifier: .gregorian)
        if isAllDay {
            let style = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: .gmt).weekday(.abbreviated).day().month(.abbreviated)
            var text = start.formatted(style)
            if let end, spanDays > 0 { text += " – " + end.formatted(style) }
            return text + " · All day"
        }
        let dateStyle = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: startZone).weekday(.abbreviated).day().month(.abbreviated)
        var text = start.formatted(dateStyle) + " · " + TripTime.shortTime(start, in: startZone, locale: locale)
        if let end {
            if spanDays == 0 && startZone == endZone {
                text += "–" + TripTime.shortTime(end, in: endZone, locale: locale)
            } else {
                let endDate = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: endZone).weekday(.abbreviated).day().month(.abbreviated)
                text += " → " + end.formatted(endDate) + " " + TripTime.shortTime(end, in: endZone, locale: locale)
            }
        }
        if let abbreviation = endZone.abbreviation(for: end ?? start) ?? startZone.abbreviation(for: start) {
            text += " " + abbreviation
        }
        return text
    }

    /// Whether the item is over at `now` (its end, or its start when it has no end).
    public func isPast(at now: Date) -> Bool {
        guard let last = end ?? start else { return false }
        if isAllDay { return CalendarDate(now, in: startZone) > CalendarDate(last, in: .gmt) }
        return last < now
    }
}

extension TripPlan.Entry {
    public func summary(in plan: TripPlan) -> ItemSummary {
        ItemSummary(item, day: row.date, tripZone: plan.timeZone)
    }
}
