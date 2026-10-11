// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// What a pending reminder says, to tell whether it needs replacing.
struct ReminderContent: Equatable, Sendable {
    let title: String
    let body: String
}

extension ReminderContent {
    init(_ reminder: Reminder) {
        self.init(title: reminder.title, body: reminder.body)
    }
}

/// Keeps the phone's pending notifications in step with `ReminderPlanner`: adds the new ones,
/// removes the ones that no longer apply, and leaves everything that isn't ours alone.
///
/// Uses the completion-handler forms of the notification APIs so only identifiers and statuses
/// (Sendable values) cross between actors. The handlers are `@Sendable`: iOS calls them on a
/// background queue, and a handler left main-actor isolated would trap there.
@MainActor
final class ReminderScheduler {
    private let center = UNUserNotificationCenter.current()

    func status() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { @Sendable settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Asks once; afterwards the answer lives in Settings.
    func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            center.requestAuthorization(options: [.alert, .sound, .badge]) { @Sendable granted, _ in
                continuation.resume(returning: granted)
            }
        }
    }

    /// Operations run one at a time, in order, so a sign-out's cleanup can't interleave with a
    /// replacement that started before it.
    private var tail: Task<Void, Never>?
    /// Bumped by `removeAll`; a replacement that started under an older value adds nothing.
    private var generation = 0

    /// Makes the pending reminders exactly `reminders`.
    /// - Parameter removeStale: `false` adds and updates only, for when some trips' plans aren't
    ///   loaded yet and their pending reminders must survive.
    func replace(with reminders: [Reminder], removeStale: Bool = true) async {
        let started = generation
        await serially { [self] in
            guard generation == started else { return }
            let pending = await pendingReminderContent()
            guard generation == started else { return }
            if removeStale {
                let wanted = Set(reminders.map(\.id))
                let stale = pending.keys.filter { !wanted.contains($0) }
                if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
            }
            for reminder in reminders {
                // Same id and same words: leave it. A changed title or reference replaces it.
                if let current = pending[reminder.id], current == ReminderContent(reminder) { continue }
                guard generation == started else { return }
                await add(Self.request(for: reminder))
            }
        }
    }

    /// Removes every pending and delivered reminder of ours, e.g. on sign-out.
    func removeAll() async {
        generation += 1
        await serially { [self] in
            let pending = await pendingReminderContent()
            center.removePendingNotificationRequests(withIdentifiers: Array(pending.keys))
            let delivered: [String] = await withCheckedContinuation { continuation in
                center.getDeliveredNotifications { @Sendable notifications in
                    continuation.resume(returning: notifications.map(\.request.identifier).filter { $0.hasPrefix(ReminderPlanner.prefix) })
                }
            }
            center.removeDeliveredNotifications(withIdentifiers: delivered)
        }
    }

    private func serially(_ operation: @escaping @MainActor () async -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }

    private func pendingReminderContent() async -> [String: ReminderContent] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { @Sendable requests in
                var result: [String: ReminderContent] = [:]
                for request in requests where request.identifier.hasPrefix(ReminderPlanner.prefix) {
                    result[request.identifier] = ReminderContent(title: request.content.title, body: request.content.body)
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Adding with an id that's already pending replaces that request.
    private func add(_ request: UNNotificationRequest) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            center.add(request) { @Sendable _ in continuation.resume() }
        }
    }

    /// A one-off notification at the reminder's instant. The trigger is given in UTC, so it fires
    /// at the same moment whatever zone the phone moves to.
    static func request(for reminder: Reminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.threadIdentifier = reminder.tripID
        content.userInfo = ["tripID": reminder.tripID, "itemID": reminder.itemID]
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: reminder.fireDate)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
    }
}

/// Shows reminders as banners even while the app is open.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}

/// Reminder settings (account menu › Reminders).
struct ReminderSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Toggle("Reminders", isOn: Binding(get: { model.remindersEnabled }, set: { on in
                        Task { await model.setRemindersEnabled(on) }
                    }))
                    .accessibilityIdentifier("reminders.enabled")
                    if model.reminderPermission == .denied {
                        Button("Allow notifications in Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                        }
                    }
                } footer: {
                    Text("Reminders are worked out on this phone from the trip's plan, so they arrive with no signal. They follow the trip's time zones.")
                }
                Section {
                    Toggle("Live Activities", isOn: $model.liveActivitiesEnabled)
                        .accessibilityIdentifier("reminders.liveActivities")
                } footer: {
                    Text("Flights and booked tours count down on the Lock Screen and in the Dynamic Island: a flight from three hours before departure, a tour from an hour before it starts.")
                }
                Section {
                    TextField("Companion address", text: $model.companionAddress, prompt: Text("companion.example.com"))
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("reminders.companion")
                    if let status = model.companionStatus {
                        Label(status, systemImage: status == "Connected" ? "checkmark.circle" : "exclamationmark.triangle")
                            .font(ALFont.footnote)
                            .foregroundStyle(status == "Connected" ? ALColor.successText : ALColor.errorText)
                    }
                } header: {
                    Text("Companion service")
                } footer: {
                    Text("Optional. With your self-hosted AdventureLog companion, Live Activities start and end on time without opening the app. It uses this phone's AdventureLog key.")
                }
                if model.remindersEnabled {
                    Section("Remind me") {
                        Toggle("When to leave", isOn: $model.reminderSettings.leaveBy)
                        Toggle("Before things start", isOn: $model.reminderSettings.headsUp)
                        if model.reminderSettings.headsUp {
                            Picker("Places and stays", selection: $model.reminderSettings.headsUpMinutes) {
                                ForEach([5, 10, 15, 30, 60], id: \.self) { Text(ItemSummary.durationText(minutes: $0)).tag($0) }
                            }
                            Picker("Booked items", selection: $model.reminderSettings.bookedHeadsUpMinutes) {
                                ForEach([15, 30, 60, 120], id: \.self) { Text(ItemSummary.durationText(minutes: $0)).tag($0) }
                            }
                            Picker("Flights", selection: $model.reminderSettings.flightHeadsUpMinutes) {
                                ForEach([60, 120, 180, 240], id: \.self) { Text(ItemSummary.durationText(minutes: $0)).tag($0) }
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ALColor.surface100)
            .navigationTitle("Reminders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await model.refreshReminderPermission() }
        }
        .accessibilityIdentifier("reminders.settings")
    }
}

/// On Today, once: offers reminders when a trip is on and the person hasn't decided yet.
struct ReminderOffer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if !model.remindersEnabled, !model.reminderOfferDismissed {
            VStack(alignment: .leading, spacing: ALSpace.space2) {
                Label("Get a nudge when it's time to leave", systemImage: "bell.badge")
                    .font(ALFont.headline)
                    .foregroundStyle(ALColor.ink)
                Text("Leave-by times and heads-ups before booked items, worked out on this phone so they arrive offline.")
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
                HStack {
                    Button("Turn on") { Task { await model.setRemindersEnabled(true) } }
                        .buttonStyle(ALButtonStyle(.primary, small: true))
                        .accessibilityIdentifier("reminders.offer.on")
                    Button("Not now") { model.reminderOfferDismissed = true }
                        .buttonStyle(ALButtonStyle(.plain, small: true))
                }
            }
            .alCard(padding: ALSpace.space4)
            .accessibilityIdentifier("reminders.offer")
        }
    }
}
