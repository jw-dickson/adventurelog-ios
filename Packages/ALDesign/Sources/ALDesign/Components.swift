// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import SwiftUI

// SwiftUI versions of the AdventureLog iOS design system's components, matched to the signed-off
// mockups in Design/review-1. They take plain values, so they know nothing about AdventureLog
// models and preview on their own.

// MARK: Card and group

extension View {
    /// The design system's card: surface-200, 16pt corners, the card shadow.
    public func alCard(padding: CGFloat = ALSpace.space3) -> some View {
        self.padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(ALColor.surface200, in: RoundedRectangle(cornerRadius: ALRadius.box, style: .continuous))
            .shadow(color: .black.opacity(0.06), radius: 2, y: 1)
    }
}

/// A grouped block of rows with hairline dividers, like the item detail screen's facts.
public struct ALGroup<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group(subviews: content) { subviews in
                ForEach(Array(subviews.enumerated()), id: \.offset) { index, subview in
                    if index > 0 { Divider().overlay(ALColor.hairline).padding(.horizontal, ALSpace.space3) }
                    subview
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ALColor.surface200, in: RoundedRectangle(cornerRadius: ALRadius.box, style: .continuous))
    }
}

/// A label on the left and a value on the right, inside an `ALGroup`.
public struct KeyValueRow<Value: View>: View {
    private let key: String
    private let value: Value

    public init(_ key: String, @ViewBuilder value: () -> Value) {
        self.key = key
        self.value = value()
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: ALSpace.space3) {
                Text(key).foregroundStyle(ALColor.inkMuted)
                Spacer(minLength: ALSpace.space2)
                value.foregroundStyle(ALColor.ink).multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(key).foregroundStyle(ALColor.inkMuted)
                value.foregroundStyle(ALColor.ink)
            }
        }
        .font(ALFont.subheadline)
        .padding(ALSpace.space3)
        .accessibilityElement(children: .combine)
    }
}

extension KeyValueRow where Value == Text {
    public init(_ key: String, _ value: String) {
        self.init(key) { Text(value) }
    }
}

/// Small uppercase section label ("LATER TODAY", "NOTES").
public struct Overline: View {
    private let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(ALFont.overline)
            .textCase(.uppercase)
            .kerning(0.6)
            .foregroundStyle(ALColor.inkMuted)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: DateTile

/// The day tile: weekday, day number, month. `isSelected` fills it with the primary colour.
public struct DateTile: View {
    private let weekday: String
    private let day: String
    private let month: String
    private let isSelected: Bool
    private let compact: Bool
    @ScaledMetric(relativeTo: .title2) private var width: CGFloat = 56
    @ScaledMetric(relativeTo: .title2) private var height: CGFloat = 64

    public init(weekday: String, day: String, month: String, isSelected: Bool = false, compact: Bool = false) {
        self.weekday = weekday
        self.day = day
        self.month = month
        self.isSelected = isSelected
        self.compact = compact
    }

    public var body: some View {
        VStack(spacing: 0) {
            Text(weekday).font(.system(.caption2, weight: .semibold)).textCase(.uppercase)
            Text(day).font(compact ? .system(.title3, weight: .bold) : ALFont.tileDay).monospacedDigit()
            Text(month).font(.system(.caption2, weight: .semibold)).textCase(.uppercase)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(isSelected ? ALColor.onPrimary : ALColor.ink)
        .frame(width: compact ? width * 0.86 : width, height: compact ? height * 0.9 : height)
        .background(isSelected ? ALColor.primary : ALColor.surface300,
                    in: RoundedRectangle(cornerRadius: compact ? ALRadius.tile : ALRadius.tile, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(weekday) \(day) \(month)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: Badge and pill

public struct ALBadge: View {
    public enum Style: Sendable {
        /// Booked: accent fill.
        case fixed
        case info, neutral, drift, done, skipped
    }

    private let text: String
    private let style: Style
    private let systemImage: String?

    public init(_ text: String, style: Style, systemImage: String? = nil) {
        self.text = text
        self.style = style
        self.systemImage = systemImage
    }

    public static func booked(_ text: String = "Booked") -> ALBadge {
        ALBadge(text, style: .fixed, systemImage: "lock.fill")
    }

    public var body: some View {
        HStack(spacing: ALSpace.space1) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text)
        }
        .font(ALFont.caption)
        .lineLimit(1)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .foregroundStyle(ink)
        .background(fill, in: Capsule())
        .overlay {
            if style == .skipped { Capsule().strokeBorder(ALColor.hairline) }
        }
    }

    private var ink: Color {
        switch style {
        case .fixed: return ALColor.onAccent
        case .info: return ALColor.secondaryText
        case .neutral: return ALColor.ink
        case .drift: return ALColor.warningText
        case .done: return ALColor.successText
        case .skipped: return ALColor.inkMuted
        }
    }

    private var fill: Color {
        switch style {
        case .fixed: return ALColor.accent
        case .skipped: return .clear
        default: return ALColor.badgeFill
        }
    }
}

/// A category label over a photo, e.g. "🔭 Tours".
public struct CategoryPill: View {
    private let text: String
    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(ALFont.caption)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .foregroundStyle(ALColor.onPill)
            .background(ALColor.pillFill, in: Capsule())
    }
}

// MARK: Buttons

public struct ALButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, plain }

    private let kind: Kind
    private let small: Bool

    public init(_ kind: Kind, small: Bool = false) {
        self.kind = kind
        self.small = small
    }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(small ? .system(.subheadline, weight: .semibold) : ALFont.headline)
            .lineLimit(1)
            .padding(.horizontal, kind == .plain ? ALSpace.space2 : (small ? 14 : ALSpace.space4))
            .frame(minHeight: small ? 34 : 44)
            .foregroundStyle(labelColor)
            .background(fillColor(pressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: ALRadius.btn, style: .continuous))
            .contentShape(Rectangle())
    }

    private var labelColor: Color {
        switch kind {
        case .primary: return ALColor.onPrimary
        case .secondary: return ALColor.ink
        case .plain: return ALColor.primaryText
        }
    }

    private func fillColor(pressed: Bool) -> Color {
        switch kind {
        case .primary: return pressed ? ALColor.primaryFocus : ALColor.primary
        case .secondary: return ALColor.surface300
        case .plain: return .clear
        }
    }
}

// MARK: Timeline

/// One row of a day: time column, rail with a dot, and a card.
public struct TimelineRow: View {
    public enum Status: Sendable {
        case planned, booked, done, now, skipped
    }

    public struct Content: Sendable, Hashable {
        public var time: String?
        public var secondaryTime: String?
        public var symbol: String
        public var title: String
        public var reference: String?
        public var detail: String?
        public var isBooked: Bool

        public init(time: String?, secondaryTime: String?, symbol: String, title: String, reference: String? = nil, detail: String? = nil, isBooked: Bool = false) {
            self.time = time
            self.secondaryTime = secondaryTime
            self.symbol = symbol
            self.title = title
            self.reference = reference
            self.detail = detail
            self.isBooked = isBooked
        }
    }

    private let content: Content
    private let state: Status
    private let isFirst: Bool
    private let isLast: Bool
    private let fitsTimes: Bool
    private let thumbnail: AnyView?
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var thumbnailSize: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var typeSize

    /// - Parameters:
    ///   - fitsTimes: false for a list with no times in it (trip-wide notes), whose time column can
    ///     then stay narrow; every row of a list passes the same value.
    ///   - thumbnail: the item's photo, filled into a rounded square at the card's trailing edge
    ///     (a strip across the top at the accessibility sizes). Nil for items without one.
    public init(_ content: Content, state: Status, isFirst: Bool = false, isLast: Bool = false, fitsTimes: Bool = true,
                thumbnail: AnyView? = nil) {
        self.content = content
        self.state = state
        self.isFirst = isFirst
        self.isLast = isLast
        self.fitsTimes = fitsTimes
        self.thumbnail = thumbnail
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            // At the largest sizes the time moves into the card so titles keep their width.
            card(showTime: true)
                .padding(.bottom, ALSpace.space2)
                .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .top, spacing: ALSpace.space2) {
                TimeColumn(alignment: .trailing) {
                    TimeText(content.time, alignment: .trailing, fitsTimes: fitsTimes)
                        .frame(minWidth: timeWidth, alignment: .trailing)
                        .foregroundStyle(ALColor.ink)
                    if let secondary = content.secondaryTime {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(ALColor.inkMuted)
                            .minimumScaleFactor(0.75)
                    }
                }
                .lineLimit(1)
                .padding(.top, 14)

                rail.frame(width: 20)

                card(showTime: false).padding(.bottom, ALSpace.space2)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var rail: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(ALColor.hairline)
                .frame(width: 2)
                .padding(.top, isFirst ? 18 : 0)
                .frame(maxHeight: .infinity, alignment: .top)
                .opacity(isFirst && isLast ? 0 : 1)
            dot.padding(.top, state == .now ? 16 : 18)
        }
    }

    @ViewBuilder private var dot: some View {
        switch state {
        case .booked:
            Circle().fill(ALColor.itemFixed).frame(width: 12, height: 12)
        case .done:
            Circle().fill(ALColor.success).frame(width: 12, height: 12)
        case .now:
            Circle().fill(ALColor.primary).frame(width: 16, height: 16)
                .padding(4).background(Circle().fill(ALColor.surface100))
                .overlay(Circle().strokeBorder(ALColor.primary, lineWidth: 2))
        case .skipped:
            Circle().fill(ALColor.surface100).frame(width: 12, height: 12).overlay(Circle().strokeBorder(ALColor.hairline, lineWidth: 2))
        case .planned:
            Circle().fill(ALColor.surface100).frame(width: 12, height: 12).overlay(Circle().strokeBorder(ALColor.primary, lineWidth: 2))
        }
    }

    private func card(showTime: Bool) -> some View {
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            if typeSize.isAccessibilitySize, let thumbnail {
                // A strip across the top, so the title keeps the card's full width.
                Color.clear
                    .frame(height: thumbnailSize * 1.6)
                    .frame(maxWidth: .infinity)
                    .overlay { thumbnail }
                    .clipShape(RoundedRectangle(cornerRadius: ALRadius.btn, style: .continuous))
                    .accessibilityHidden(true)
            }
            cardRow(showTime: showTime)
        }
        .alCard()
        .opacity(state == .done ? 0.72 : 1)
    }

    private func cardRow(showTime: Bool) -> some View {
        HStack(alignment: .top, spacing: ALSpace.space2) {
            Image(systemName: content.symbol)
                .font(.system(size: iconSize * 0.5, weight: .semibold))
                .foregroundStyle(ALColor.ink)
                .frame(width: iconSize, height: iconSize)
                .background(ALColor.surface300, in: RoundedRectangle(cornerRadius: ALRadius.btn, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                if showTime, let time = content.time {
                    Text([time, content.secondaryTime].compactMap { $0 }.joined(separator: " – "))
                        .font(ALFont.time)
                        .foregroundStyle(ALColor.inkMuted)
                }
                Text(content.title)
                    .font(ALFont.headline)
                    .foregroundStyle(state == .skipped ? ALColor.inkMuted : ALColor.ink)
                    .strikethrough(state == .skipped)
                if let reference = content.reference {
                    Text(reference)
                        .font(ALFont.reference)
                        .foregroundStyle(ALColor.accentText)
                        .padding(.top, 2)
                }
                if let detail = content.detail {
                    Text(detail)
                        .font(ALFont.subheadline)
                        .foregroundStyle(ALColor.inkMuted)
                }
                if content.isBooked {
                    ALBadge.booked().padding(.top, ALSpace.space1)
                }
            }
            Spacer(minLength: 0)
            if !typeSize.isAccessibilitySize, let thumbnail {
                Color.clear
                    .frame(width: thumbnailSize, height: thumbnailSize)
                    .overlay { thumbnail }
                    .clipShape(RoundedRectangle(cornerRadius: ALRadius.btn, style: .continuous))
                    .accessibilityHidden(true)
            }
        }
    }
}

#Preview("Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: ALSpace.space4) {
            HStack {
                DateTile(weekday: "Tue", day: "15", month: "Dec", isSelected: true)
                DateTile(weekday: "Wed", day: "16", month: "Dec")
            }
            HStack {
                ALBadge.booked()
                ALBadge("Overnight", style: .info)
                ALBadge("Late", style: .drift)
            }
            VStack(spacing: 0) {
                TimelineRow(.init(time: "09:30", secondaryTime: nil, symbol: "car.fill", title: "Taxi to the hotel", detail: "30 min"), state: .done, isFirst: true)
                TimelineRow(.init(time: "18:30", secondaryTime: "20:30", symbol: "mappin.and.ellipse", title: "Sunset cruise", reference: "B# 100245", isBooked: true), state: .booked, isLast: true)
            }
            HStack {
                Button("Navigate") {}.buttonStyle(ALButtonStyle(.primary))
                Button("Notes") {}.buttonStyle(ALButtonStyle(.secondary))
            }
        }
        .padding()
    }
    .background(ALColor.surface100)
}

/// A line in a timeline where the clock changes ("Now on Sydney time · clocks go forward 19 h"),
/// on the rail between the rows it separates, so a shift in times reads as a shift in zone.
public struct ZoneShiftRow: View {
    private let text: String
    private let fitsTimes: Bool
    private let continuesRail: Bool
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 52
    @Environment(\.dynamicTypeSize) private var typeSize

    /// - Parameters:
    ///   - fitsTimes: the same value the list's rows pass, so the rail lines up.
    ///   - continuesRail: false after the list's last row, where the rail has ended.
    public init(_ text: String, fitsTimes: Bool = true, continuesRail: Bool = true) {
        self.text = text
        self.fitsTimes = fitsTimes
        self.continuesRail = continuesRail
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            label.padding(.bottom, ALSpace.space2)
        } else {
            HStack(alignment: .center, spacing: ALSpace.space2) {
                TimeText(nil, alignment: .trailing, fitsTimes: fitsTimes)
                    .frame(minWidth: timeWidth, alignment: .trailing)
                    .accessibilityHidden(true)
                Rectangle()
                    .fill(ALColor.hairline)
                    .frame(width: 2)
                    .frame(maxHeight: .infinity)
                    .frame(width: 20)
                    .opacity(continuesRail ? 1 : 0)
                label
                    .padding(.top, ALSpace.space1)
                    .padding(.bottom, ALSpace.space3)
            }
        }
    }

    private var label: some View {
        Label(text, systemImage: "clock.arrow.2.circlepath")
            .font(ALFont.footnote)
            .foregroundStyle(ALColor.secondaryText)
            .padding(.horizontal, ALSpace.space3)
            .padding(.vertical, ALSpace.space1)
            .background(ALColor.surface200, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("timeline.zoneShift")
    }
}

/// A time in a column of times: as wide as the widest time this locale writes ("10:58 PM" or
/// "22:58"), the same on every row, so no time is cut short and the column doesn't wobble.
/// Anything wider than a time ("All day") shrinks to fit.
public struct TimeText: View {
    private let text: String?
    private let alignment: Alignment
    private let fitsTimes: Bool

    /// - Parameter fitsTimes: false to size to the text alone, in a column that holds no times.
    public init(_ text: String?, alignment: Alignment = .leading, fitsTimes: Bool = true) {
        self.text = text
        self.alignment = alignment
        self.fitsTimes = fitsTimes
    }

    public var body: some View {
        ZStack(alignment: alignment) {
            ForEach(fitsTimes ? Self.widestTimes : [], id: \.self) { Text($0).hidden().accessibilityHidden(true) }
        }
        .overlay(alignment: alignment) {
            Text(text ?? "").minimumScaleFactor(0.6)
        }
        .font(ALFont.time)
        .monospacedDigit()
        .lineLimit(1)
    }

    /// The widest times the current locale writes: one before noon and one after, with two-digit hours.
    static var widestTimes: [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: .autoupdatingCurrent, calendar: calendar, timeZone: .gmt)
        return [10, 22].compactMap { hour in
            calendar.date(from: DateComponents(year: 2027, month: 3, day: 8, hour: hour, minute: 58)).map { $0.formatted(style) }
        }
    }
}

/// A column of times: as wide as its first view (usually a ``TimeText``); what's under it (an end
/// time, a planned time, a date) gets that width and shrinks or is cut short rather than widening it.
public struct TimeColumn: Layout {
    private let alignment: HorizontalAlignment

    public init(alignment: HorizontalAlignment = .leading) {
        self.alignment = alignment
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let width = first.sizeThatFits(.unspecified).width
        let height = subviews.reduce(0) { $0 + $1.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let first = subviews.first else { return }
        let width = first.sizeThatFits(.unspecified).width
        let trailing = alignment == .trailing
        var y = bounds.minY
        for subview in subviews {
            let size = ProposedViewSize(width: width, height: nil)
            subview.place(at: CGPoint(x: trailing ? bounds.maxX : bounds.minX, y: y),
                          anchor: trailing ? .topTrailing : .topLeading, proposal: size)
            y += subview.sizeThatFits(size).height
        }
    }
}
