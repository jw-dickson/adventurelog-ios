// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Stage 5: a revised plan for the rest of today when you're running late (Design/review-1, 08).
///
/// The phone works one out itself (`ReplanPlanner`), offline. A companion with Claude can suggest
/// another from a free-text ask. Either way the proposal is checked with the same rules
/// (`ReplanCheck`) before it's shown, and nothing changes until the person applies it.
public enum Replan {
    /// One timed thing still ahead today, as the planner sees it.
    public struct Stop: Sendable, Hashable, Codable {
        public var rowID: String
        public var itemID: String
        public var title: String
        public var kind: ItemKind
        public var start: Date
        public var end: Date
        public var zoneID: String
        /// Booked items never move.
        public var isBooked: Bool
        public var isFlight: Bool
        public var latitude: Double?
        public var longitude: Double?
        /// Where a journey ends.
        public var endLatitude: Double?
        public var endLongitude: Double?

        public init(rowID: String, itemID: String, title: String, kind: ItemKind, start: Date, end: Date, zone: TimeZone,
                    isBooked: Bool, isFlight: Bool = false, coordinate: ItemSummary.Coordinate?, destination: ItemSummary.Coordinate? = nil) {
            self.rowID = rowID
            self.itemID = itemID
            self.title = title
            self.kind = kind
            self.start = start
            self.end = end
            self.zoneID = zone.identifier
            self.isBooked = isBooked
            self.isFlight = isFlight
            self.latitude = coordinate?.latitude
            self.longitude = coordinate?.longitude
            self.endLatitude = destination?.latitude
            self.endLongitude = destination?.longitude
        }

        public var zone: TimeZone { TimeZone(identifier: zoneID) ?? .gmt }
        public var coordinate: ItemSummary.Coordinate? { ItemSummary.Coordinate(latitude, longitude) }
        /// Where you are when it's over: a journey's end, or the place itself.
        public var exit: ItemSummary.Coordinate? { ItemSummary.Coordinate(endLatitude, endLongitude) ?? coordinate }
        public var minutes: Int { max(0, Int((end.timeIntervalSince(start) / 60).rounded())) }
        /// Places can be shortened, moved or skipped; a journey only moves in time, since it joins two places.
        public var isPlace: Bool { kind == .location }
        /// Something the planner may change at all.
        public var isFlexible: Bool { !isBooked && (kind == .location || kind == .transportation) }

        /// A stop for a row of Today, when it's a timed place or journey. Stays are left out (a
        /// check-in time is when it opens, not when you must be there), and so is anything longer
        /// than 18 hours, like a car hire.
        public init?(_ entry: TodayPlan.Entry) {
            let summary = entry.summary
            guard let start = summary.start, let end = summary.end, !summary.isAllDay, end > start,
                  end.timeIntervalSince(start) <= 18 * 3600,
                  summary.kind == .location || summary.kind == .transportation
            else { return nil }
            var isFlight = false
            if case .transportation(let leg) = entry.entry.item { isFlight = leg.type == .plane }
            self.init(rowID: entry.rowID, itemID: summary.id, title: summary.title, kind: summary.kind, start: start, end: end,
                      zone: summary.startZone, isBooked: summary.isBooked, isFlight: isFlight,
                      coordinate: summary.coordinate, destination: summary.destination)
        }
    }

    /// The next free morning on the following trip day, for moving a place there.
    public struct NextDay: Sendable, Hashable, Codable {
        public var date: CalendarDate
        /// When that day's first timed item starts, if it has one.
        public var firstStart: Date?
        public var firstTitle: String?
        public var zoneID: String

        public init(date: CalendarDate, firstStart: Date?, firstTitle: String?, zone: TimeZone) {
            self.date = date
            self.firstStart = firstStart
            self.firstTitle = firstTitle
            self.zoneID = zone.identifier
        }

        public var zone: TimeZone { TimeZone(identifier: zoneID) ?? .gmt }
    }

    /// Everything the planner needs: what's left today, how late you are, and where you are.
    public struct Situation: Sendable, Hashable, Codable {
        public var date: CalendarDate
        public var now: Date
        /// The rest of today in order: the thing you're late for first.
        public var stops: [Stop]
        /// How many minutes after its planned start you can begin the first stop.
        public var delayMinutes: Int
        /// The phone's position, when recording.
        public var latitude: Double?
        public var longitude: Double?
        public var nextDay: NextDay?
        public var zoneID: String

        public init(date: CalendarDate, now: Date, stops: [Stop], delayMinutes: Int, position: ItemSummary.Coordinate? = nil,
                    nextDay: NextDay? = nil, zone: TimeZone) {
            self.date = date
            self.now = now
            self.stops = stops
            self.delayMinutes = delayMinutes
            self.latitude = position?.latitude
            self.longitude = position?.longitude
            self.nextDay = nextDay
            self.zoneID = zone.identifier
        }

        public var zone: TimeZone { TimeZone(identifier: zoneID) ?? .gmt }
        public var position: ItemSummary.Coordinate? { ItemSummary.Coordinate(latitude, longitude) }

        /// Today's stops still ahead (or under way), from a Today plan: done and skipped rows are left out.
        public static func stops(in today: TodayPlan, now: Date) -> [Stop] {
            today.entries.filter { $0.status == .upcoming || $0.status == .now }.compactMap(Stop.init)
        }
    }

    /// One line of a proposal.
    public enum Change: Sendable, Hashable, Codable {
        /// A booked item: it stays where it is.
        case keep(rowID: String)
        /// New times today (later, or shorter).
        case retime(rowID: String, start: Date, end: Date, reason: String?)
        /// To another day of the trip, at new times there.
        case move(rowID: String, date: CalendarDate, start: Date, end: Date, reason: String?)
        /// Left out today (on this phone; the item stays in the trip).
        case skip(rowID: String, reason: String?)
        /// A new note on a day (the companion may suggest one, such as dinner).
        case add(title: String, content: String, date: CalendarDate, reason: String?)

        public var rowID: String? {
            switch self {
            case .keep(let id), .retime(let id, _, _, _), .move(let id, _, _, _, _), .skip(let id, _): return id
            case .add: return nil
            }
        }

        private enum CodingKeys: String, CodingKey { case type, rowID, start, end, date, reason, title, content }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let reason = try c.decodeIfPresent(String.self, forKey: .reason)?.nilIfBlank
            func instant(_ key: CodingKeys) throws -> Date {
                let text = try c.decode(String.self, forKey: key)
                guard let date = ISO8601.parse(text) else {
                    throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not an ISO-8601 time: \(text)")
                }
                return date
            }
            switch try c.decode(String.self, forKey: .type) {
            case "keep": self = .keep(rowID: try c.decode(String.self, forKey: .rowID))
            case "retime": self = .retime(rowID: try c.decode(String.self, forKey: .rowID), start: try instant(.start), end: try instant(.end), reason: reason)
            case "move": self = .move(rowID: try c.decode(String.self, forKey: .rowID), date: try c.decode(CalendarDate.self, forKey: .date),
                                      start: try instant(.start), end: try instant(.end), reason: reason)
            case "skip": self = .skip(rowID: try c.decode(String.self, forKey: .rowID), reason: reason)
            case "add": self = .add(title: try c.decode(String.self, forKey: .title), content: try c.decodeIfPresent(String.self, forKey: .content) ?? "",
                                    date: try c.decode(CalendarDate.self, forKey: .date), reason: reason)
            case let other:
                throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "Unknown change type: \(other)")
            }
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .keep(let id):
                try c.encode("keep", forKey: .type)
                try c.encode(id, forKey: .rowID)
            case .retime(let id, let start, let end, let reason):
                try c.encode("retime", forKey: .type)
                try c.encode(id, forKey: .rowID)
                try c.encode(ISO8601.format(start), forKey: .start)
                try c.encode(ISO8601.format(end), forKey: .end)
                try c.encodeIfPresent(reason, forKey: .reason)
            case .move(let id, let date, let start, let end, let reason):
                try c.encode("move", forKey: .type)
                try c.encode(id, forKey: .rowID)
                try c.encode(date, forKey: .date)
                try c.encode(ISO8601.format(start), forKey: .start)
                try c.encode(ISO8601.format(end), forKey: .end)
                try c.encodeIfPresent(reason, forKey: .reason)
            case .skip(let id, let reason):
                try c.encode("skip", forKey: .type)
                try c.encode(id, forKey: .rowID)
                try c.encodeIfPresent(reason, forKey: .reason)
            case .add(let title, let content, let date, let reason):
                try c.encode("add", forKey: .type)
                try c.encode(title, forKey: .title)
                try c.encode(content, forKey: .content)
                try c.encode(date, forKey: .date)
                try c.encodeIfPresent(reason, forKey: .reason)
            }
        }
    }

    /// A revised rest-of-today.
    public struct Proposal: Sendable, Hashable, Codable {
        public enum Source: String, Sendable, Hashable, Codable { case phone, claude }

        public var behindMinutes: Int
        /// One or two sentences on what it keeps and why.
        public var summary: String
        /// Booked items first, then the rest in the day's order.
        public var changes: [Change]
        public var source: Source
        /// A booked item you'd still be late for, and by how much, when nothing could be moved to fit.
        public var lateFor: String?
        public var lateMinutes: Int?

        public init(behindMinutes: Int, summary: String, changes: [Change], source: Source = .phone,
                    lateFor: String? = nil, lateMinutes: Int? = nil) {
            self.behindMinutes = behindMinutes
            self.summary = summary
            self.changes = changes
            self.source = source
            self.lateFor = lateFor
            self.lateMinutes = lateMinutes
        }

        /// Whether applying it would change anything.
        public var changesSomething: Bool {
            changes.contains { if case .keep = $0 { return false } else { return true } }
        }

        /// "You're 48 min behind", or "You're on time".
        public var headline: String {
            behindMinutes > 0 ? "You're \(ItemSummary.durationText(minutes: behindMinutes)) behind" : "You're on time"
        }
    }

    // MARK: Shared rules

    /// Minutes to be there before a booked item starts: 90 for a flight (at the airport), else 10.
    public static func buffer(before stop: Stop) -> Int {
        stop.isFlight ? 90 : 10
    }

    /// Travel minutes between two places: none within 300 m, else Today's straight-line estimate.
    public static func travelMinutes(from a: ItemSummary.Coordinate?, to b: ItemSummary.Coordinate?) -> Int {
        guard let a, let b, LeaveBy.kilometres(from: a, to: b) >= 0.3 else { return 0 }
        return LeaveBy.estimatedMinutes(from: a, to: b)
    }

    /// Nothing flexible is planned to end after this in the day's zone.
    public static let latestEndHour = 23
    /// A place moved to the next day starts here, local time.
    public static let morningHour = 8

    /// How late you are for `target` if you set off from `position` now: minutes after its planned
    /// start you'd arrive, never negative.
    public static func delay(now: Date, position: ItemSummary.Coordinate?, target: Stop) -> Int {
        let arrive = now.addingTimeInterval(Double(travelMinutes(from: position, to: target.coordinate) * 60))
        return max(0, Int((arrive.timeIntervalSince(target.start) / 60).rounded(.up)))
    }
}

extension Replan.Situation {
    /// End of the day for flexible plans, in the day's zone.
    var dayEnd: Date {
        date.startOfDay(in: zone).addingTimeInterval(Double(Replan.latestEndHour * 3600))
    }
}
