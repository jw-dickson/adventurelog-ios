// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI
import UIKit

// Stage 2's editing screens: the note editor, reordering a day, moving a row to another day, and
// the sync status and issue list that go with them.

// MARK: Account

/// The account button shared by Today and Trips: who is signed in, the token gallery, sign out.
/// Signing out with unsent edits asks first, because it deletes them.
struct AccountMenu: View {
    @Environment(AppModel.self) private var model
    @State private var showingTokens = false
    @State private var showingReminders = false
    @State private var confirmingSignOut = false

    var body: some View {
        Menu {
            if let credentials = model.credentials {
                Text(credentials.displayName ?? credentials.username ?? "Signed in")
                Text(credentials.serverURL.host() ?? credentials.serverURL.absoluteString)
            }
            Button("Reminders", systemImage: "bell") { showingReminders = true }
            Button("Design tokens", systemImage: "paintpalette") { showingTokens = true }
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                if model.outbox.entries.isEmpty {
                    Task { await model.signOut() }
                } else {
                    confirmingSignOut = true
                }
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Account")
        .sheet(isPresented: $showingTokens) {
            NavigationStack { TokenGallery() }
        }
        .sheet(isPresented: $showingReminders) {
            ReminderSettingsView()
        }
        .confirmationDialog(unsentTitle, isPresented: $confirmingSignOut, titleVisibility: .visible) {
            Button("Sign out and delete them", role: .destructive) {
                Task { await model.signOut() }
            }
        } message: {
            Text("Signing out removes everything saved on this phone, including changes that haven't reached your server.")
        }
    }

    private var unsentTitle: String {
        let count = model.outbox.entries.count
        return count == 1 ? "1 change hasn't synced" : "\(count) changes haven't synced"
    }
}

// MARK: Sync status

/// One line under a trip: changes waiting to sync, or changes that need a look.
struct SyncStatusLine: View {
    let tripID: String
    @Environment(AppModel.self) private var model
    @State private var showingIssues = false

    var body: some View {
        let attention = model.outbox.attentionCount(for: tripID)
        let waiting = model.outbox.waitingCount(for: tripID)
        VStack(spacing: ALSpace.space2) {
            if let problem = model.syncProblem {
                Label(problem, systemImage: "key.slash")
                    .foregroundStyle(ALColor.errorText)
            }
            if attention > 0 {
                Button {
                    showingIssues = true
                } label: {
                    Label(attention == 1 ? "1 change needs a look" : "\(attention) changes need a look",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(ALColor.warningText)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sync.issues")
            }
            if waiting > 0 {
                Label(model.isSyncing ? "Saving changes…" : (waiting == 1 ? "1 change waiting to sync" : "\(waiting) changes waiting to sync"),
                      systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(ALColor.inkMuted)
                    .accessibilityIdentifier("sync.waiting")
            }
        }
        .font(ALFont.footnote)
        .frame(maxWidth: .infinity)
        .sheet(isPresented: $showingIssues) {
            SyncIssuesView(tripID: tripID)
        }
    }
}

/// Conflicts, refusals and dropped edits for one trip, each with its choices.
struct SyncIssuesView: View {
    let tripID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let issues = model.issues(for: tripID)
        NavigationStack {
            List {
                if issues.entries.isEmpty && issues.notices.isEmpty {
                    ContentUnavailableView("Everything is saved", systemImage: "checkmark.circle")
                        .listRowBackground(Color.clear)
                }
                ForEach(issues.entries) { entry in
                    Section { IssueRow(entry: entry) }
                }
                ForEach(issues.notices) { notice in
                    Section { NoticeRow(notice: notice) }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ALColor.surface100)
            .navigationTitle("Changes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .accessibilityIdentifier("sync.issues.list")
    }
}

private struct IssueRow: View {
    let entry: PendingEdit
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            Text(entry.edit.summary).font(ALFont.headline).foregroundStyle(ALColor.ink)
            switch entry.state {
            case .conflict(let conflict):
                Text("This note was also changed somewhere else. Pick the version to keep.")
                    .font(ALFont.subheadline).foregroundStyle(ALColor.inkMuted)
                if case .editNote(let edit) = entry.edit {
                    Version(label: "On your server", text: conflict.serverContent)
                    Version(label: "On this phone", text: edit.content)
                }
                HStack {
                    Button("Keep mine") { model.keepMine(entry.id) }
                        .buttonStyle(ALButtonStyle(.primary, small: true))
                        .accessibilityIdentifier("sync.keepMine")
                    Button("Keep theirs") { model.discard(entry.id) }
                        .buttonStyle(ALButtonStyle(.secondary, small: true))
                        .accessibilityIdentifier("sync.keepTheirs")
                }
            case .fieldConflict(let conflict):
                if case .editItem(let edit) = entry.edit {
                    let names = conflict.clashes.map { $0.field.label(for: edit.kind) }
                    Text("Someone else changed the \(ListFormatter.localizedString(byJoining: names)) too. Your other changes were saved.")
                        .font(ALFont.subheadline).foregroundStyle(ALColor.inkMuted)
                    ForEach(conflict.clashes, id: \.field) { clash in
                        let mine = edit.changes.first { $0.field == clash.field }?.value
                        VStack(alignment: .leading, spacing: 2) {
                            Text(clash.field.label(for: edit.kind).capitalized).font(ALFont.footnote.weight(.semibold))
                            Text("Yours: \(describe(mine, field: clash.field, edit: edit))")
                            Text("On your server: \(describe(clash.server, field: clash.field, edit: edit))")
                        }
                        .font(ALFont.subheadline)
                        .foregroundStyle(ALColor.ink)
                    }
                }
                HStack {
                    Button("Keep mine") { model.keepMine(entry.id) }
                        .buttonStyle(ALButtonStyle(.primary, small: true))
                        .accessibilityIdentifier("sync.keepMine")
                    Button("Keep server's") { model.discard(entry.id) }
                        .buttonStyle(ALButtonStyle(.secondary, small: true))
                        .accessibilityIdentifier("sync.keepTheirs")
                }
            case .failed(let message):
                Text("Your server didn't accept this: \(message)")
                    .font(ALFont.subheadline).foregroundStyle(ALColor.inkMuted)
                HStack {
                    Button("Try again") { model.retry(entry.id) }
                        .buttonStyle(ALButtonStyle(.primary, small: true))
                    Button("Discard", role: .destructive) { model.discard(entry.id) }
                        .buttonStyle(ALButtonStyle(.secondary, small: true))
                }
            case .waiting:
                EmptyView()
            }
        }
        .padding(.vertical, ALSpace.space1)
        .listRowBackground(ALColor.surface200)
    }

    /// A field's value as the person would read it: times in the item's own zone.
    private func describe(_ value: FieldValue?, field: ItemField, edit: TripEdit.EditItem) -> String {
        switch value {
        case .time(let date?):
            var zone = TimeZone.current
            if let plan = model.trip(entry.tripID)?.plan, let item = ItemDetailView.find(edit.itemID, in: plan) {
                let summary = ItemSummary(item, day: nil, tripZone: plan.timeZone)
                zone = field == .end ? summary.endZone : summary.startZone
            }
            let day = date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).day().month(.abbreviated))
            return day + " · " + TripTime.shortTime(date, in: zone)
        case .text(let text?) where FieldValue.clean(text) != nil:
            return text
        default:
            return "nothing"
        }
    }
}

private struct Version: View {
    let label: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Overline(label)
            Text(text.isEmpty ? "(empty)" : text)
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.ink)
                .lineLimit(6)
                .textSelection(.enabled)
        }
        .padding(ALSpace.space2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ALColor.surface100, in: RoundedRectangle(cornerRadius: ALRadius.btn, style: .continuous))
    }
}

private struct NoticeRow: View {
    let notice: SyncNotice
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            Label(notice.message, systemImage: "info.circle")
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.ink)
            HStack {
                if let text = notice.keptText {
                    Button("Copy my text") { UIPasteboard.general.string = text }
                        .buttonStyle(ALButtonStyle(.secondary, small: true))
                }
                Button("OK") { model.dismissNotice(notice.id) }
                    .buttonStyle(ALButtonStyle(.plain, small: true))
            }
        }
        .padding(.vertical, ALSpace.space1)
        .listRowBackground(ALColor.surface200)
    }
}

// MARK: Note editor

/// Edits a note's text. Saving keeps the change on the phone and sends it when it can.
struct NoteEditor: View {
    let note: Note
    let tripID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var focused: Bool

    init(note: Note, tripID: String) {
        self.note = note
        self.tripID = tripID
        _text = State(initialValue: note.content ?? "")
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .font(ALFont.body)
                .foregroundStyle(ALColor.ink)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, ALSpace.space3)
                .background(ALColor.surface100)
                .focused($focused)
                .accessibilityIdentifier("note.editor")
                .navigationTitle(note.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            model.saveNote(note, content: text, tripID: tripID)
                            dismiss()
                        }
                        .disabled(text == (note.content ?? ""))
                        .accessibilityIdentifier("note.save")
                    }
                }
                .onAppear { focused = true }
        }
        .interactiveDismissDisabled(text != (note.content ?? ""))
    }
}

// MARK: Reorder and move

/// The rows on one day (or trip-wide), in a list you drag to reorder. Each row can also go to
/// another day.
struct ReorderSheet: View {
    let tripID: String
    /// `nil` for the trip-wide rows.
    let date: CalendarDate?
    let title: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var moving: TripPlan.Entry?

    var body: some View {
        let plan = model.trip(tripID)?.plan
        let entries = plan.map { Self.entries(on: date, in: $0) } ?? []
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    HStack(spacing: ALSpace.space3) {
                        let summary = plan.map { entry.summary(in: $0) }
                        Image(systemName: summary?.symbol ?? "circle")
                            .foregroundStyle(ALColor.ink)
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.item.title).font(ALFont.headline).foregroundStyle(ALColor.ink)
                            if let time = summary?.startText() {
                                Text(time).font(ALFont.footnote).foregroundStyle(ALColor.inkMuted)
                            }
                        }
                        Spacer(minLength: 0)
                        Button {
                            moving = entry
                        } label: {
                            Image(systemName: "calendar.badge.plus")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Move to another day")
                        .accessibilityIdentifier("reorder.move.\(entry.item.title)")
                    }
                    .listRowBackground(ALColor.surface200)
                }
                .onMove { source, destination in
                    guard let from = source.first, entries.indices.contains(from) else { return }
                    // `destination` counts the row itself; the outbox wants its place among the others.
                    let index = destination > from ? destination - 1 : destination
                    model.move(entries[from], to: date, at: index, tripID: tripID)
                }
                if entries.isEmpty {
                    Text("Nothing here to reorder.")
                        .foregroundStyle(ALColor.inkMuted)
                        .listRowBackground(Color.clear)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(ALColor.surface100)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $moving) { entry in
                MoveToDaySheet(tripID: tripID, entry: entry)
            }
        }
        .accessibilityIdentifier("reorder.sheet")
    }

    static func entries(on date: CalendarDate?, in plan: TripPlan) -> [TripPlan.Entry] {
        if let date { return plan.day(for: date)?.entries ?? [] }
        return plan.tripWide
    }
}

/// Picks a day (or the whole trip) for one row; it goes at the end of that day.
struct MoveToDaySheet: View {
    let tripID: String
    let entry: TripPlan.Entry
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let plan = model.trip(tripID)?.plan
        let current = ItineraryLayout.key(entry.row)
        NavigationStack {
            List {
                Section {
                    choice(title: "Whole trip", subtitle: "Not tied to a day", date: nil, isCurrent: current == nil)
                }
                Section("Days") {
                    ForEach(plan?.days ?? []) { day in
                        choice(title: day.name ?? "Day \(day.number)", subtitle: DayText.long(day.date), date: day.date, isCurrent: current == day.date)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(ALColor.surface100)
            .navigationTitle("Move “\(entry.item.title)”")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
        .accessibilityIdentifier("move.sheet")
    }

    private func choice(title: String, subtitle: String, date: CalendarDate?, isCurrent: Bool) -> some View {
        Button {
            if !isCurrent { model.move(entry, to: date, at: .max, tripID: tripID) }
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(ALFont.body).foregroundStyle(ALColor.ink)
                    Text(subtitle).font(ALFont.footnote).foregroundStyle(ALColor.inkMuted)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "checkmark").foregroundStyle(ALColor.primaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(ALColor.surface200)
        .accessibilityAddTraits(isCurrent ? [.isSelected] : [])
        .accessibilityIdentifier("move.to.\(date?.description ?? "trip")")
    }
}
