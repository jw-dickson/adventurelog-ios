// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import ActivityKit
import AdventureLogKit
import Foundation

/// Keeps at most one Live Activity running: the flight or booked tour `LiveActivityPlanner` picks.
///
/// iOS only lets an app start an activity while it's in the foreground, so the activity begins the
/// next time AdventureLog is open (or tracking keeps it running) inside the window. Updates and
/// endings also work in the background. A push from the companion service (Stage 4b) can add a
/// gate or a delay; the phone keeps that note when it updates the times.
///
/// Not main-actor bound: `Activity` isn't Sendable, so it's looked up and changed on the same
/// (generic) executor rather than handed across from the main actor.
struct LiveActivityController: Sendable {
    var isAllowed: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// A running activity's push token, for the companion service: token, trip id, row id.
    typealias TokenHandler = @Sendable (Data, String, String) async -> Void

    /// Makes the running activity match `plan`, or ends every activity when `plan` is nil.
    /// - Parameter onToken: when set (a companion is configured), a new activity asks for a push
    ///   token and each token goes here.
    func show(_ plan: LiveActivityPlanner.Plan?, onToken: TokenHandler? = nil) async {
        let running = Activity<TripActivityAttributes>.activities
        for activity in running where !matches(activity, plan) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        guard let plan else { return }
        if let activity = running.first(where: { matches($0, plan) }) {
            var state = plan.state
            // A pushed gate or delay stays until a push changes it; a cancellation is the push's to lift.
            let current = activity.content.state
            state.note = current.note
            if current.phase == .cancelled { return }
            guard state != current else { return }
            await activity.update(ActivityContent(state: state, staleDate: plan.end))
            return
        }
        guard isAllowed else { return }
        do {
            let activity = try Activity.request(attributes: TripActivityAttributes(info: plan.info),
                                                content: ActivityContent(state: plan.state, staleDate: plan.end),
                                                pushType: onToken == nil ? nil : .token)
            if let onToken {
                let info = plan.info
                Task {
                    for await token in activity.pushTokenUpdates { await onToken(token, info.tripID, info.rowID) }
                }
            }
        } catch {
            // Not in the foreground, or the person turned Live Activities off: try again next time.
        }
    }

    /// Runs for the signed-in session: hands the companion the push-to-start token, and the push
    /// token of every activity a push starts.
    func watchTokens(onStartToken: @escaping @Sendable (Data) async -> Void, onToken: @escaping TokenHandler) async {
        await withDiscardingTaskGroup { group in
            group.addTask {
                for await token in Activity<TripActivityAttributes>.pushToStartTokenUpdates { await onStartToken(token) }
            }
            group.addTask {
                for await activity in Activity<TripActivityAttributes>.activityUpdates {
                    let info = activity.attributes.info
                    Task {
                        for await token in activity.pushTokenUpdates { await onToken(token, info.tripID, info.rowID) }
                    }
                }
            }
        }
    }

    /// Ends everything, e.g. on sign-out.
    func endAll() async {
        for activity in Activity<TripActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private func matches(_ activity: Activity<TripActivityAttributes>, _ plan: LiveActivityPlanner.Plan?) -> Bool {
        guard let plan else { return false }
        let info = activity.attributes.info
        return info.tripID == plan.info.tripID && info.rowID == plan.info.rowID
    }
}
