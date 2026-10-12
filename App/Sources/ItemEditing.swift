// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI

// Editing a place, journey or stay (Design/editing): the edit sheet, the quick note, and a new note
// on a day. Everything is saved on the phone first and sent when the server can be reached.

// MARK: Edit sheet

/// Name, times, notes and details of one place, journey or stay, plus Remove from its day.
struct ItemEditor: View {
    let item: TripPlan.Item
    let summary: ItemSummary
    /// The row the person came from; offers Remove from that day when it's on one.
    let entry: TripPlan.Entry?
    let tripID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var values: [ItemField: FieldValue]
    @State private var confirmingRemove = false
    private let original: [ItemField: FieldValue]
    private let kind: ItemKind

    init(item: TripPlan.Item, summary: ItemSummary, entry: TripPlan.Entry?, tripID: String) {
        self.item = item
        self.summary = summary
        self.entry = entry
        self.tripID = tripID
        let kind = TripEdit.EditItem.editableKind(item) ?? .unknown
        self.kind = kind
        let visit = item.editableVisit?.id
        var start: [ItemField: FieldValue] = [:]
        for field in ItemField.fields(for: kind) {
            if let value = ItemValues.read(field, of: item, visitID: visit) { start[field] = value }
        }
        original = start
        _values = State(initialValue: start)
    }

    private var changed: Bool {
        values.contains { field, value in !(original[field].map(value.matches) ?? true) }
    }

    private var titleText: String {
        switch kind {
        case .transportation: return isFlight ? "Edit flight" : "Edit journey"
        case .lodging: return "Edit stay"
        default: return "Edit"
        }
    }

    private var isFlight: Bool {
        if case .transportation(let leg) = item { return leg.type == .plane }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: text(.name))
                        .font(ALFont.body)
                        .accessibilityIdentifier("edit.name")
                }
                .listRowBackground(ALColor.surface200)

                if kind == .transportation && isFlight {
                    Section {
                        LabeledContent("Flight number") {
                            TextField("EX 101", text: text(.flightNumber))
                                .font(.system(.body, design: .monospaced).weight(.semibold))
                                .multilineTextAlignment(.trailing)
                                .textInputAutocapitalization(.characters)
                                .autocorrectionDisabled()
                                .accessibilityIdentifier("edit.flightNumber")
                        }
                    }
                    .listRowBackground(ALColor.surface200)
                }

                if hasTimes {
                    timesSection
                }

                Section {
                    TextEditor(text: text(notesField))
                        .font(ALFont.body)
                        .frame(minHeight: 96)
                        .accessibilityIdentifier("edit.notes")
                } header: {
                    Text(kind == .location ? "Notes for this visit" : "Notes")
                }
                .listRowBackground(ALColor.surface200)

                detailsSection

                if let entry, entry.row.date != nil {
                    Section {
                        Button(role: .destructive) {
                            confirmingRemove = true
                        } label: {
                            Text("Remove from \(dayLabel(entry))")
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(ALColor.errorText)
                        }
                        .accessibilityIdentifier("edit.removeFromDay")
                    } footer: {
                        Text("\(kindNoun.capitalizedFirst) stays in the trip, under Not on a day.")
                    }
                    .listRowBackground(ALColor.surface200)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ALColor.surface100)
            .navigationTitle(titleText)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.editItem(item, values: values, tripID: tripID)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(!changed || FieldValue.clean(values[.name]?.text) == nil)
                    .accessibilityIdentifier("edit.save")
                }
            }
            .confirmationDialog(removeTitle, isPresented: $confirmingRemove, titleVisibility: .visible) {
                Button("Remove from day", role: .destructive) {
                    if let entry { model.removeFromDay(entry, tripID: tripID) }
                    dismiss()
                }
            } message: {
                Text("It stays in the trip under Not on a day, with its booking and notes. Its time on that day is kept too.")
            }
        }
        .interactiveDismissDisabled(changed)
    }

    // MARK: Sections

    private var hasTimes: Bool {
        guard kind != .location || item.editableVisit != nil else { return false }
        return values[.start]?.time != nil || values[.end]?.time != nil
    }

    @ViewBuilder private var timesSection: some View {
        Section {
            timeRow(kind == .transportation ? "Departs" : kind == .lodging ? "Check-in" : "Starts", field: .start,
                    zone: summary.startZone, code: departureCode)
            timeRow(kind == .transportation ? "Arrives" : kind == .lodging ? "Check-out" : "Ends", field: .end,
                    zone: summary.endZone, code: arrivalCode)
        } header: {
            if kind != .transportation {
                Text(zoneHeader(summary.startZone))
            } else {
                Text("Times")
            }
        } footer: {
            Text(kind == .transportation
                 ? "Each time is in its own place's zone. Reminders and the Live Activity follow the new times."
                 : "Moving the start moves the end with it.")
        }
        .listRowBackground(ALColor.surface200)
    }

    @ViewBuilder private func timeRow(_ label: String, field: ItemField, zone: TimeZone, code: String?) -> some View {
        if let date = values[field]?.time {
            DatePicker(selection: timeBinding(field), displayedComponents: summary.isAllDay ? [.date] : [.date, .hourAndMinute]) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(ALFont.body)
                    if kind == .transportation {
                        Text([code, zone.abbreviation(for: date)].compactMap { $0 }.joined(separator: " · "))
                            .font(ALFont.footnote)
                            .foregroundStyle(ALColor.inkMuted)
                    }
                }
            }
            // All-day values are UTC midnight on their date; everything else is shown in its zone.
            .environment(\.timeZone, summary.isAllDay ? TimeZone(identifier: "UTC")! : zone)
            .accessibilityIdentifier(field == .start ? "edit.start" : "edit.end")
        }
    }

    @ViewBuilder private var detailsSection: some View {
        let fields = ItemField.fields(for: kind)
        Section {
            if kind == .lodging {
                LabeledContent("Booking") {
                    TextField("Reference", text: text(.reservationNumber))
                        .font(.system(.body, design: .monospaced).weight(.semibold))
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled()
                }
            }
            if fields.contains(.address) {
                LabeledContent("Address") {
                    TextField("Address", text: text(.address))
                        .multilineTextAlignment(.trailing)
                }
            }
            LabeledContent("Link") {
                TextField("Add a link", text: text(.link))
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if kind == .location {
                VStack(alignment: .leading, spacing: ALSpace.space1) {
                    Text("About the place").font(ALFont.footnote).foregroundStyle(ALColor.inkMuted)
                    TextEditor(text: text(.description))
                        .font(ALFont.body)
                        .frame(minHeight: 60)
                }
            }
        } header: {
            Text("Details")
        }
        .listRowBackground(ALColor.surface200)
    }

    // MARK: Bindings and labels

    /// Where the notes field writes: a place's visit notes when it has a visit, else its notes.
    private var notesField: ItemField {
        kind == .location && item.editableVisit != nil ? .visitNotes : .description
    }

    private func text(_ field: ItemField) -> Binding<String> {
        Binding(get: { values[field]?.text ?? "" }, set: { values[field] = .text($0) })
    }

    private func timeBinding(_ field: ItemField) -> Binding<Date> {
        Binding(get: { values[field]?.time ?? model.now }, set: { new in
            // Moving the start keeps the length, so the end follows.
            if field == .start, let old = values[.start]?.time, let end = values[.end]?.time {
                values[.end] = .time(end.addingTimeInterval(new.timeIntervalSince(old)))
            }
            values[field] = .time(new)
        })
    }

    private var departureCode: String? {
        if case .transportation(let leg) = item { return leg.startCode }
        return nil
    }

    private var arrivalCode: String? {
        if case .transportation(let leg) = item { return leg.endCode }
        return nil
    }

    private var kindNoun: String {
        switch kind {
        case .transportation: return isFlight ? "the flight" : "the journey"
        case .lodging: return "the stay"
        default: return "the place"
        }
    }

    private var removeTitle: String {
        guard let entry else { return "" }
        return "Remove \(item.title) from \(dayLabel(entry))?"
    }

    private func dayLabel(_ entry: TripPlan.Entry) -> String {
        guard let date = entry.row.date else { return "its day" }
        return DayText.long(date)
    }

    private func zoneHeader(_ zone: TimeZone) -> String {
        let abbreviation = zone.abbreviation(for: values[.start]?.time ?? model.now) ?? zone.identifier
        let city = zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") }
        return ["When", [abbreviation, city].compactMap { $0 }.joined(separator: ", ")].joined(separator: " · ")
    }
}

// MARK: Quick note

/// One field: a line added under an item's notes, with the time it was written.
struct QuickNoteSheet: View {
    let item: TripPlan.Item
    let zone: TimeZone
    let tripID: String
    let onAdded: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: ALSpace.space2) {
                TextEditor(text: $text)
                    .font(ALFont.body)
                    .scrollContentBackground(.hidden)
                    .padding(ALSpace.space2)
                    .frame(minHeight: 110)
                    .background(ALColor.surface200, in: RoundedRectangle(cornerRadius: ALRadius.box, style: .continuous))
                    .focused($focused)
                    .accessibilityIdentifier("quickNote.text")
                Text("Added under the notes with the time, \(TripTime.shortTime(model.now, in: zone)). Saved on this phone first.")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
                Spacer(minLength: 0)
            }
            .padding(ALSpace.space4)
            .background(ALColor.surface100)
            .navigationTitle("Add a note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.appendNote(text, to: item, zone: zone, tripID: tripID)
                        onAdded()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(FieldValue.clean(text) == nil)
                    .accessibilityIdentifier("quickNote.add")
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(FieldValue.clean(text) != nil)
    }
}

// MARK: New note on a day

/// A new note at the end of a day, or for the whole trip.
struct NewNoteSheet: View {
    struct Target: Identifiable, Hashable {
        /// `nil` for trip-wide.
        let date: CalendarDate?
        let label: String
        var id: String { date?.description ?? "trip" }
    }

    let target: Target
    let tripID: String
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var content = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $name)
                        .font(ALFont.body)
                        .focused($focused)
                        .accessibilityIdentifier("newNote.title")
                    TextEditor(text: $content)
                        .font(ALFont.body)
                        .frame(minHeight: 120)
                        .accessibilityIdentifier("newNote.text")
                } header: {
                    Text(target.label)
                } footer: {
                    Text(target.date == nil
                         ? "Goes with the whole trip's notes and checklists."
                         : "Goes at the end of the day. Drag it into place afterwards.")
                }
                .listRowBackground(ALColor.surface200)
            }
            .scrollContentBackground(.hidden)
            .background(ALColor.surface100)
            .navigationTitle("New note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        model.addNote(name: name, content: content, date: target.date, tripID: tripID)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(FieldValue.clean(name) == nil && FieldValue.clean(content) == nil)
                    .accessibilityIdentifier("newNote.add")
                }
            }
            .onAppear { focused = true }
        }
        .interactiveDismissDisabled(FieldValue.clean(name) != nil || FieldValue.clean(content) != nil)
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
