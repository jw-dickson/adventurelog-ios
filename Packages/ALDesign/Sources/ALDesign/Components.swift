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
    @ScaledMetric(relativeTo: .subheadline) private var timeWidth: CGFloat = 52
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 28
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ content: Content, state: Status, isFirst: Bool = false, isLast: Bool = false) {
        self.content = content
        self.state = state
        self.isFirst = isFirst
        self.isLast = isLast
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            // At the largest sizes the time moves into the card so titles keep their width.
            card(showTime: true)
                .padding(.bottom, ALSpace.space2)
                .accessibilityElement(children: .combine)
        } else {
            HStack(alignment: .top, spacing: ALSpace.space2) {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(content.time ?? "")
                        .font(ALFont.time)
                        .monospacedDigit()
                        .foregroundStyle(ALColor.ink)
                    if let secondary = content.secondaryTime {
                        Text(secondary)
                            .font(.caption)
                            .foregroundStyle(ALColor.inkMuted)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: timeWidth, alignment: .trailing)
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
        }
        .alCard()
        .opacity(state == .done ? 0.72 : 1)
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
