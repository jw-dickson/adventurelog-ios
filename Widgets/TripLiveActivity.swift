// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import ActivityKit
import AdventureLogKit
import ALDesign
import SwiftUI
import WidgetKit

@main
struct AdventureLogWidgets: WidgetBundle {
    var body: some Widget {
        TripLiveActivity()
    }
}

/// The Lock Screen card and Dynamic Island for a flight or booked tour (Design/review-1, 09).
/// Always the dark live palette, whatever the system appearance; the countdown is system timer
/// text, so it ticks without updates, and the bar fills in ochre.
struct TripLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            LockScreenCard(info: context.attributes.info, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(ALColor.liveBg)
                .activitySystemActionForegroundColor(ALColor.liveInk)
        } dynamicIsland: { context in
            let info = context.attributes.info
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(info.eyebrow, systemImage: LiveText.symbol(info))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(ALColor.accent)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Countdown(state: state)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(ALColor.liveInk)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(info.title)
                        .font(.headline)
                        .foregroundStyle(ALColor.liveInk)
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(LiveText.status(info: info, state: state))
                            .font(.subheadline)
                            .foregroundStyle(ALColor.liveMuted)
                            .lineLimit(1)
                        LegBar(info: info, state: state)
                    }
                }
            } compactLeading: {
                Image(systemName: LiveText.symbol(info))
                    .foregroundStyle(ALColor.accent)
            } compactTrailing: {
                Countdown(state: state)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(ALColor.liveInk)
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: LiveText.symbol(info))
                    .foregroundStyle(ALColor.accent)
            }
            .keylineTint(ALColor.accent)
        }
    }
}

private struct LockScreenCard: View {
    let info: LiveActivityInfo
    let state: LiveActivityState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(info.eyebrow.uppercased())
                    .font(.caption.weight(.semibold))
                    .tracking(1)
                    .foregroundStyle(ALColor.accent)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if state.phase == .cancelled {
                    Text("Cancelled")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(ALColor.accent)
                } else {
                    Countdown(state: state)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(ALColor.liveInk)
                }
            }
            Text(info.title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(ALColor.liveInk)
                .lineLimit(1)
            if let detail = info.detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(ALColor.liveMuted)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline) {
                Text(LiveText.status(info: info, state: state))
                    .font(.subheadline)
                    .foregroundStyle(ALColor.liveMuted)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let reference = info.reference {
                    Text(reference)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(ALColor.liveInk)
                }
            }
            LegBar(info: info, state: state)
                .padding(.top, 4)
                .opacity(isStale ? 0.5 : 1)
        }
        .padding(16)
        .accessibilityElement(children: .combine)
    }
}

/// Counts down to boarding (or a tour's start), then to departure. System timer text: no updates needed.
private struct Countdown: View {
    let state: LiveActivityState

    var body: some View {
        Text(timerInterval: Date.now...max(state.countdownTarget, .now), countsDown: true, showsHours: true)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
    }
}

/// Three parts that fill in ochre over the wait, each a system progress timer.
private struct LegBar: View {
    let info: LiveActivityInfo
    let state: LiveActivityState

    var body: some View {
        let start = info.windowStart
        let span = max(state.target.timeIntervalSince(start), 3)
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { part in
                let from = start.addingTimeInterval(span * Double(part) / 3)
                let to = start.addingTimeInterval(span * Double(part + 1) / 3)
                ProgressView(timerInterval: from...to, countsDown: false) {
                    EmptyView()
                } currentValueLabel: {
                    EmptyView()
                }
                .progressViewStyle(.linear)
                .tint(ALColor.accent)
                .background(ALColor.liveTrack, in: Capsule())
            }
        }
        .accessibilityHidden(true)
    }
}

enum LiveText {
    static func symbol(_ info: LiveActivityInfo) -> String {
        info.kind == .flight ? "airplane" : "ticket"
    }

    /// "Boards 06:15 · Gate 23", "Boarding · departs 07:00", "Starts 11:00", or the cancellation note.
    static func status(info: LiveActivityInfo, state: LiveActivityState) -> String {
        let time = { (date: Date) in TripTime.shortTime(date, in: info.zone) }
        let main: String
        switch (info.kind, state.phase) {
        case (_, .cancelled): return state.note ?? "Cancelled"
        case (.flight, .upcoming): main = "Boards \(time(state.target))"
        case (.flight, .boarding): main = "Boarding · departs \(time(state.departure))"
        case (.tour, _): main = "Starts \(time(state.target))"
        }
        return [main, state.note].compactMap { $0 }.joined(separator: " · ")
    }
}

#Preview("Lock Screen", as: .content, using: TripActivityAttributes(info: LiveActivityInfo(
    tripID: "t", rowID: "r", kind: .flight, eyebrow: "Connection · SYD", title: "EX 1501 to Hobart",
    detail: "Domestic connection. Re-check bags at SYD after customs.", reference: nil,
    zoneIdentifier: "Australia/Sydney", windowStart: .now.addingTimeInterval(-108 * 60)))) {
    TripLiveActivity()
} contentStates: {
    LiveActivityState(phase: .upcoming, target: .now.addingTimeInterval(72 * 60), departure: .now.addingTimeInterval(117 * 60), note: "Gate 23")
    LiveActivityState(phase: .boarding, target: .now.addingTimeInterval(-5 * 60), departure: .now.addingTimeInterval(40 * 60), note: "Gate 23")
    LiveActivityState(phase: .cancelled, target: .now, departure: .now, note: "Cancelled: rebooked on EX 1503 at 09:30")
}
