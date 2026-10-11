// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// Keeps the phone's pending notifications in step with `ReminderPlanner`: adds the new ones,
/// removes the ones that no longer apply, and leaves everything that isn't ours alone.
///
/// Uses the completion-handler forms of the notification APIs so only identifiers and statuses
/// (Sendable values) cross between actors.
@MainActor
final class ReminderScheduler {
    private let center = UNUserNotificationCenter.current()

    func status() async -> UNAuthorizationStatus {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    /// Asks once; afterwards the answer lives in Settings.
    func requestPermission() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Makes the pending reminders exactly `reminders`.
    func replace(with reminders: [Reminder]) async {
        let pending = await pendingIDs()
        let wanted = Set(reminders.map(\.id))
        let stale = pending.filter { !wanted.contains($0) }
        if !stale.isEmpty { center.removePendingNotificationRequests(withIdentifiers: stale) }
        let existing = Set(pending)
        for reminder in reminders where !existing.contains(reminder.id) {
            center.add(Self.request(for: reminder)) { _ in }
        }
    }

    /// Removes every pending and delivered reminder of ours, e.g. on sign-out.
    func removeAll() async {
        let pending = await pendingIDs()
        center.removePendingNotificationRequests(withIdentifiers: pending)
        let delivered: [String] = await withCheckedContinuation { continuation in
            center.getDeliveredNotifications { notifications in
                continuation.resume(returning: notifications.map(\.request.identifier).filter { $0.hasPrefix(ReminderPlanner.prefix) })
            }
        }
        center.removeDeliveredNotifications(withIdentifiers: delivered)
    }

    private func pendingIDs() async -> [String] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { requests in
                continuation.resume(returning: requests.map(\.identifier).filter { $0.hasPrefix(ReminderPlanner.prefix) })
            }
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
