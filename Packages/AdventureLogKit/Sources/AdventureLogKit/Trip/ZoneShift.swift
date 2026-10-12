// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// Where a day's clock changes: between two items in different zones, or across a journey that
/// lands in another zone. Every time in the timeline is already in its own place's zone; this
/// says where that zone changes, and by how much.
public struct ZoneShift: Sendable, Hashable {
    public let from: TimeZone
    public let to: TimeZone
    /// When the change takes effect: the later item's start, or the journey's arrival.
    public let at: Date
    /// How far clocks move, in minutes: positive forward, negative back.
    public let minutes: Int

    /// Nil when the two zones keep the same time at that moment (Sydney and Hobart, say).
    public init?(from: TimeZone, to: TimeZone, at: Date) {
        let difference = (to.secondsFromGMT(for: at) - from.secondsFromGMT(for: at)) / 60
        guard difference != 0 else { return nil }
        self.from = from
        self.to = to
        self.at = at
        self.minutes = difference
    }

    /// "Now on Sydney time · clocks go forward 19 h".
    public var text: String {
        let amount = ItemSummary.durationText(minutes: abs(minutes))
        return "Now on \(Self.place(of: to)) time · clocks go \(minutes > 0 ? "forward" : "back") \(amount)"
    }

    /// The zone's city ("Los Angeles" for America/Los_Angeles), or its abbreviation for zones
    /// without one (fixed offsets, "UTC").
    static func place(of zone: TimeZone) -> String {
        let parts = zone.identifier.split(separator: "/")
        guard parts.count > 1, let city = parts.last else { return zone.abbreviation() ?? zone.identifier }
        return city.replacingOccurrences(of: "_", with: " ")
    }

    /// For each item of a timeline, in order: a change before it (it starts in a different zone
    /// from where the one before ended) and a change within it (it ends in a different zone from
    /// where it started, like a flight). Untimed and all-day items don't move the clock.
    public static func marks(_ items: [ItemSummary]) -> [(before: ZoneShift?, within: ZoneShift?)] {
        var current: TimeZone?
        return items.map { item in
            guard let start = item.start, !item.isAllDay else { return (nil, nil) }
            let before = current.flatMap { ZoneShift(from: $0, to: item.startZone, at: start) }
            let within = ZoneShift(from: item.startZone, to: item.endZone, at: item.end ?? start)
            current = item.end == nil ? item.startZone : item.endZone
            return (before, within)
        }
    }

    /// The same changes as notes under each item: what changes during it, then what changes
    /// before the next one. Nil where the clock stays put.
    public static func notes(_ items: [ItemSummary]) -> [String?] {
        let all = marks(items)
        return all.indices.map { index in
            let next = index + 1 < all.count ? all[index + 1].before : nil
            let lines = [all[index].within, next].compactMap { $0?.text }
            return lines.isEmpty ? nil : lines.joined(separator: "\n")
        }
    }
}
