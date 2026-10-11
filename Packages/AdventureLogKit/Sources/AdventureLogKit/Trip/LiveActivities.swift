// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// What a Live Activity is about (Design/review-1, 09). Fixed for the activity's life.
///
/// Plain values so the planner can be tested anywhere; the app wraps them in ActivityKit's
/// attributes, and the companion service sends `LiveActivityState` as the push content state.
public struct LiveActivityInfo: Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable { case flight, tour }

    public var tripID: String
    public var rowID: String
    public var kind: Kind
    /// "Connection · SYD", "Flight · DEN", "Booked tour".
    public var eyebrow: String
    /// "EX 1501 to Hobart", "Harbour kayak tour".
    public var title: String
    /// The first line of the item's notes: what to do on the way.
    public var detail: String?
    /// A booking reference, when the item has one besides the flight number.
    public var reference: String?
    /// Times on the activity are shown in this zone (the departure's or the place's).
    public var zoneIdentifier: String
    /// When the activity began, so its bar can show how much of the wait has passed.
    public var windowStart: Date

    public init(tripID: String, rowID: String, kind: Kind, eyebrow: String, title: String, detail: String?,
                reference: String?, zoneIdentifier: String, windowStart: Date) {
        self.tripID = tripID
        self.rowID = rowID
        self.kind = kind
        self.eyebrow = eyebrow
        self.title = title
        self.detail = detail
        self.reference = reference
        self.zoneIdentifier = zoneIdentifier
        self.windowStart = windowStart
    }

    public var zone: TimeZone { TimeZone(identifier: zoneIdentifier) ?? .gmt }

    private enum CodingKeys: String, CodingKey {
        case tripID, rowID, kind, eyebrow, title, detail, reference, zoneIdentifier, windowStart
    }

    // A push-to-start push carries these attributes, decoded by ActivityKit's plain JSONDecoder,
    // so `windowStart` is Unix seconds here too rather than the default seconds since 2001.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tripID = try c.decode(String.self, forKey: .tripID)
        rowID = try c.decode(String.self, forKey: .rowID)
        kind = try c.decode(Kind.self, forKey: .kind)
        eyebrow = try c.decode(String.self, forKey: .eyebrow)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decodeIfPresent(String.self, forKey: .detail)
        reference = try c.decodeIfPresent(String.self, forKey: .reference)
        zoneIdentifier = try c.decode(String.self, forKey: .zoneIdentifier)
        windowStart = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .windowStart))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tripID, forKey: .tripID)
        try c.encode(rowID, forKey: .rowID)
        try c.encode(kind, forKey: .kind)
        try c.encode(eyebrow, forKey: .eyebrow)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(detail, forKey: .detail)
        try c.encodeIfPresent(reference, forKey: .reference)
        try c.encode(zoneIdentifier, forKey: .zoneIdentifier)
        try c.encode(windowStart.timeIntervalSince1970, forKey: .windowStart)
    }
}

/// What a Live Activity shows now. Changes over its life, from the phone or from a push.
///
/// The JSON keys are the push payload's `content-state` (see `Fixtures/live-activity/`).
public struct LiveActivityState: Codable, Sendable, Hashable {
    public enum Phase: String, Codable, Sendable {
        /// Counting down to boarding, or to the start of a tour.
        case upcoming
        /// Boarding has started; counting down to departure.
        case boarding
        /// The flight is cancelled or the tour called off; the note says what to do.
        case cancelled
    }

    public var phase: Phase
    /// Boarding for a flight, the start for a tour: what the countdown counts to.
    public var target: Date
    /// When the flight leaves (the same as `target` for a tour).
    public var departure: Date
    /// "Gate 23", "Delayed 25 min", "Called off: rough sea". Set by a push; the phone never guesses.
    public var note: String?

    public init(phase: Phase, target: Date, departure: Date, note: String? = nil) {
        self.phase = phase
        self.target = target
        self.departure = departure
        self.note = note
    }

    private enum CodingKeys: String, CodingKey { case phase, target, departure, note }

    // Times are Unix seconds whatever the decoder's date strategy: ActivityKit decodes push
    // content with a plain JSONDecoder, whose default would read them as seconds since 2001.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        phase = try container.decode(Phase.self, forKey: .phase)
        target = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .target))
        departure = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .departure))
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(phase, forKey: .phase)
        try container.encode(target.timeIntervalSince1970, forKey: .target)
        try container.encode(departure.timeIntervalSince1970, forKey: .departure)
        try container.encodeIfPresent(note, forKey: .note)
    }

    /// How much of the wait has passed, 0 to 1, for the three-part bar.
    public func progress(windowStart: Date, now: Date) -> Double {
        let total = target.timeIntervalSince(windowStart)
        guard total > 0 else { return 1 }
        return min(max(now.timeIntervalSince(windowStart) / total, 0), 1)
    }

    /// What the countdown counts to right now.
    public var countdownTarget: Date { phase == .boarding ? departure : target }
}

/// Picks the flight or booked tour that should have a Live Activity now.
///
/// A flight's activity starts three hours before departure and counts down to boarding (45
/// minutes before), then to departure; it ends when the flight leaves. A booked tour's starts an
/// hour before and ends when the tour starts. When two overlap, the sooner one wins.
public enum LiveActivityPlanner {
    public static let flightLead: TimeInterval = 3 * 3600
    public static let tourLead: TimeInterval = 3600
    public static let boardingBefore: TimeInterval = 45 * 60

    public struct Plan: Sendable, Hashable {
        public let info: LiveActivityInfo
        public let state: LiveActivityState
        /// When the activity should end.
        public let end: Date
    }

    /// The activity that should be showing at `now`, if any.
    public static func current(for plan: TripPlan, now: Date, skipped: Set<String> = []) -> Plan? {
        candidates(in: plan, skipped: skipped)
            .filter { $0.info.windowStart <= now && now < $0.end }
            .min { $0.end < $1.end }
            .map { candidate in
                var state = candidate.state
                if now >= state.target, candidate.info.kind == .flight { state.phase = .boarding }
                return Plan(info: candidate.info, state: state, end: candidate.end)
            }
    }

    /// When the next activity after `now` should start, so the app can ask to run then.
    public static func nextStart(for plan: TripPlan, after now: Date, skipped: Set<String> = []) -> Date? {
        candidates(in: plan, skipped: skipped).map(\.info.windowStart).filter { $0 > now }.min()
    }

    static func candidates(in plan: TripPlan, skipped: Set<String>) -> [Plan] {
        let tripID = plan.collection.id
        let entries = plan.days.flatMap(\.entries).filter { !skipped.contains($0.row.id) }
        var plans: [Plan] = []
        var seen = Set<String>()
        for (index, entry) in entries.enumerated() {
            // An item on several days (a stay, a hire) appears once per day; one activity is enough.
            guard seen.insert(entry.item.id).inserted else { continue }
            let summary = entry.summary(in: plan)
            guard let start = summary.start, !summary.isAllDay else { continue }
            switch entry.item {
            case .transportation(let leg) where leg.type == .plane:
                let origin = leg.startCode?.nilIfBlank ?? leg.fromLocation?.nilIfBlank
                let connecting = entries[..<index].contains { earlier in
                    guard case .transportation(let previous) = earlier.item, previous.type == .plane,
                          let arrival = previous.endDate, start.timeIntervalSince(arrival) < 12 * 3600 else { return false }
                    return previous.endCode?.nilIfBlank != nil && previous.endCode == leg.startCode
                }
                let eyebrow = [connecting ? "Connection" : "Flight", origin].compactMap { $0 }.joined(separator: " · ")
                let info = LiveActivityInfo(
                    tripID: tripID, rowID: entry.row.id, kind: .flight, eyebrow: eyebrow,
                    title: flightTitle(leg) ?? summary.title, detail: firstLine(summary.notes),
                    reference: nil, zoneIdentifier: summary.startZone.identifier,
                    windowStart: start.addingTimeInterval(-flightLead))
                let state = LiveActivityState(phase: .upcoming, target: start.addingTimeInterval(-boardingBefore), departure: start)
                plans.append(Plan(info: info, state: state, end: start))
            case .location where summary.isBooked:
                let info = LiveActivityInfo(
                    tripID: tripID, rowID: entry.row.id, kind: .tour, eyebrow: "Booked tour",
                    title: summary.title, detail: firstLine(summary.notes), reference: summary.reference,
                    zoneIdentifier: summary.startZone.identifier, windowStart: start.addingTimeInterval(-tourLead))
                plans.append(Plan(info: info, state: LiveActivityState(phase: .upcoming, target: start, departure: start), end: start))
            default:
                continue
            }
        }
        return plans
    }

    /// "EX 1501 to Hobart", from the flight number and the arrival airport's city.
    static func flightTitle(_ leg: Transportation) -> String? {
        guard let number = leg.flightNumber?.nilIfBlank else { return nil }
        let spaced = number.replacingOccurrences(of: #"^([A-Za-z]{2,3})\s*(\d+)$"#, with: "$1 $2", options: .regularExpression)
        guard let place = city(leg.toLocation) ?? leg.endCode?.nilIfBlank else { return spaced }
        return "\(spaced) to \(place)"
    }

    /// "Hobart Airport (HBA)" → "Hobart"; "Los Angeles International Airport (LAX)" → "Los Angeles".
    static func city(_ airport: String?) -> String? {
        guard var name = airport?.nilIfBlank else { return nil }
        name = name.replacingOccurrences(of: #"\s*\([A-Z]{3}\)$"#, with: "", options: .regularExpression)
        for suffix in [" International Airport", " Airport"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name.nilIfBlank
    }

    static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first.map { String($0).trimmingCharacters(in: .whitespaces) }?.nilIfBlank
    }
}
