// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI
import UIKit

/// One item (Design/review-1, 04): photo, title and time, Navigate, the facts with a
/// tap-to-copy booking reference, notes and checklist items. Checklist items tick on tap and notes
/// can be edited; both are saved on the phone at once and sent when the server can be reached.
struct ItemDetailView: View {
    let route: ItemRoute
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let plan = model.trip(route.tripID)?.plan, let item = Self.find(route.itemID, in: plan) {
                ItemDetailContent(summary: ItemSummary(item, day: route.day, tripZone: plan.timeZone), item: item,
                                  entry: Self.entry(route.itemID, on: route.day, in: plan), tripID: route.tripID)
            } else {
                ContentUnavailableView("Not in this trip any more", systemImage: "questionmark.circle")
            }
        }
        .background(ALColor.surface100)
        .navigationBarTitleDisplayMode(.inline)
    }

    static func find(_ id: String, in plan: TripPlan) -> TripPlan.Item? {
        for day in plan.days {
            if let entry = day.entries.first(where: { $0.item.id == id }) { return entry.item }
        }
        if let entry = plan.tripWide.first(where: { $0.item.id == id }) { return entry.item }
        return plan.unscheduled.first { $0.id == id }
    }

    /// The row placing the item on `day`, else its first row anywhere.
    static func entry(_ id: String, on day: CalendarDate?, in plan: TripPlan) -> TripPlan.Entry? {
        if let day, let entry = plan.day(for: day)?.entries.first(where: { $0.item.id == id }) { return entry }
        for day in plan.days {
            if let entry = day.entries.first(where: { $0.item.id == id }) { return entry }
        }
        return plan.tripWide.first { $0.item.id == id }
    }
}

struct Fact: Identifiable, Hashable {
    let key: String
    let value: String
    var id: String { key }
}

private struct ItemDetailContent: View {
    let summary: ItemSummary
    let item: TripPlan.Item
    let entry: TripPlan.Entry?
    let tripID: String
    @Environment(AppModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var toast: Toast?
    @State private var editingNote: Note?
    @State private var editingItem = false
    @State private var addingNote = false

    private enum Toast {
        case copied, saved

        var text: String { self == .copied ? "Copied" : "Saved on this phone · syncs when online" }
        var symbol: String { self == .copied ? "doc.on.doc" : "arrow.triangle.2.circlepath" }
    }

    private var isEditable: Bool { TripEdit.EditItem.editableKind(item) != nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Hero(summary: summary)
                VStack(alignment: .leading, spacing: ALSpace.space3) {
                    header
                    actions
                    facts
                    if case .note(let note) = item {
                        noteSection(note)
                    } else if isEditable {
                        itemNotesSection
                    } else if let notes = summary.notes {
                        Overline("Notes").padding(.top, ALSpace.space2)
                        Text(Self.markdown(notes))
                            .font(ALFont.body)
                            .foregroundStyle(ALColor.ink)
                            .tint(ALColor.primaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .alCard()
                            .textSelection(.enabled)
                            .accessibilityIdentifier("item.notes")
                    }
                    if case .checklist(let list) = item, !list.items.isEmpty {
                        Overline("Checklist").padding(.top, ALSpace.space2)
                        ALGroup {
                            ForEach(list.items) { entry in
                                Button {
                                    model.setChecked(!entry.isChecked, itemID: entry.id, in: list, tripID: tripID)
                                } label: {
                                    Label {
                                        Text(entry.name)
                                            .foregroundStyle(entry.isChecked ? ALColor.inkMuted : ALColor.ink)
                                            .strikethrough(entry.isChecked)
                                            .multilineTextAlignment(.leading)
                                    } icon: {
                                        Image(systemName: entry.isChecked ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(entry.isChecked ? ALColor.success : ALColor.inkMuted)
                                    }
                                    .font(ALFont.body)
                                    .padding(ALSpace.space3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .sensoryFeedback(.selection, trigger: entry.isChecked)
                                .accessibilityValue(entry.isChecked ? "Done" : "Not done")
                                .accessibilityHint(entry.isChecked ? "Unticks it" : "Ticks it")
                                .accessibilityIdentifier("checklist.item.\(entry.name)")
                            }
                        }
                    }
                }
                .padding(.horizontal, ALSpace.space4)
                .padding(.top, ALSpace.space4)
                .padding(.bottom, ALSpace.space8)
            }
        }
        .ignoresSafeArea(edges: summary.imageURL == nil ? Edge.Set() : .top)
        .overlay(alignment: .bottom) {
            if let toast {
                Label(toast.text, systemImage: toast.symbol)
                    .font(ALFont.subheadline.weight(.semibold))
                    .foregroundStyle(ALColor.onNeutral)
                    .padding(.horizontal, ALSpace.space4)
                    .padding(.vertical, ALSpace.space2)
                    .background(ALColor.neutral, in: Capsule())
                    .padding(.bottom, ALSpace.space6)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .accessibilityIdentifier("item.detail")
        .toolbar {
            if case .note(let note) = item {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editingNote = note }
                        .accessibilityIdentifier("note.edit")
                }
            } else if isEditable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { editingItem = true }
                        .accessibilityIdentifier("item.edit")
                }
            }
        }
        .sheet(item: $editingNote) { note in
            NoteEditor(note: note, tripID: tripID)
        }
        .sheet(isPresented: $editingItem) {
            ItemEditor(item: item, summary: summary, entry: entry, tripID: tripID)
        }
        .sheet(isPresented: $addingNote) {
            QuickNoteSheet(item: item, zone: summary.startZone, tripID: tripID) { show(.saved) }
        }
    }

    private func show(_ kind: Toast) {
        withAnimation { toast = kind }
        Task {
            try? await Task.sleep(for: .seconds(kind == .copied ? 1.5 : 2.5))
            withAnimation { if toast == kind { toast = nil } }
        }
    }

    /// A place's, journey's or stay's notes, with Add a note at the foot (Design/editing, 01).
    @ViewBuilder private var itemNotesSection: some View {
        Overline("Notes").padding(.top, ALSpace.space2)
        ALGroup {
            if let notes = summary.notes {
                Text(Self.markdown(notes))
                    .font(ALFont.body)
                    .foregroundStyle(ALColor.ink)
                    .tint(ALColor.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(ALSpace.space3)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("item.notes")
            }
            Button {
                addingNote = true
            } label: {
                Label("Add a note", systemImage: "plus")
                    .font(ALFont.subheadline.weight(.medium))
                    .foregroundStyle(ALColor.primaryText)
                    .padding(ALSpace.space3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("item.addNote")
        }
    }

    /// A note's text, always shown for notes so an empty one can be filled in.
    @ViewBuilder private func noteSection(_ note: Note) -> some View {
        Overline("Note").padding(.top, ALSpace.space2)
        Button {
            editingNote = note
        } label: {
            Group {
                if let text = note.content?.nilIfBlank {
                    Text(Self.markdown(text))
                        .foregroundStyle(ALColor.ink)
                        .tint(ALColor.primaryText)
                } else {
                    Text("Add to this note…")
                        .foregroundStyle(ALColor.inkMuted)
                }
            }
            .font(ALFont.body)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .alCard()
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edits the note")
        .accessibilityIdentifier("item.notes")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: ALSpace.space2) {
            if summary.isBooked || summary.categoryName != nil {
                HStack(spacing: 6) {
                    if summary.isBooked { ALBadge.booked() }
                    if let name = summary.categoryName {
                        CategoryPill([summary.categoryIcon, name].compactMap { $0 }.joined(separator: " "))
                    }
                }
            }
            Text(summary.title)
                .font(ALFont.title1)
                .foregroundStyle(ALColor.ink)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("item.title")
            if let when = summary.whenText() {
                Text(when)
                    .font(ALFont.subheadline)
                    .foregroundStyle(ALColor.inkMuted)
            }
            if model.hasWaitingEdit(forItem: summary.id, tripID: tripID) {
                Label("Saved on this phone, waiting to sync", systemImage: "arrow.triangle.2.circlepath")
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
                    .accessibilityIdentifier("item.waiting")
            }
        }
    }

    @ViewBuilder private var actions: some View {
        let directions = summary.directionsURL
        if directions != nil || summary.link != nil {
            HStack(spacing: ALSpace.space2) {
                if let directions {
                    Button {
                        openURL(directions)
                    } label: {
                        Label("Navigate", systemImage: "arrow.triangle.turn.up.right.diamond.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ALButtonStyle(.primary))
                    .accessibilityIdentifier("item.navigate")
                }
                if let link = summary.link {
                    Button {
                        openURL(link)
                    } label: {
                        Label(summary.isBooked ? "Open booking" : "Open link", systemImage: "safari").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(ALButtonStyle(.secondary))
                }
            }
        }
    }

    @ViewBuilder private var facts: some View {
        let rows = Self.facts(for: item, summary: summary)
        if summary.reference != nil || !rows.isEmpty {
            ALGroup {
                if let reference = summary.reference {
                    Button {
                        UIPasteboard.general.string = reference
                        show(.copied)
                    } label: {
                        KeyValueRow(Self.referenceLabel(for: item)) {
                            HStack(spacing: 6) {
                                Text(reference).font(ALFont.reference.weight(.semibold))
                                Image(systemName: "doc.on.doc").font(.footnote)
                            }
                            .foregroundStyle(ALColor.primaryText)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Copies the reference")
                    .accessibilityIdentifier("item.reference")
                }
                ForEach(rows) { fact in
                    KeyValueRow(fact.key, fact.value)
                }
            }
        }
    }

    // MARK: Helpers

    static func referenceLabel(for item: TripPlan.Item) -> String {
        switch item {
        case .transportation(let leg): return leg.type == .plane ? "Flight" : "Booking"
        case .lodging: return "Reservation"
        default: return "Booking"
        }
    }

    /// Facts that are not already in the header.
    static func facts(for item: TripPlan.Item, summary: ItemSummary) -> [Fact] {
        var rows: [Fact] = []
        switch item {
        case .transportation(let leg):
            if let from = leg.fromLocation?.nilIfBlank { rows.append(Fact(key: "From", value: from)) }
            if let to = leg.toLocation?.nilIfBlank { rows.append(Fact(key: "To", value: to)) }
            if let start = leg.date { rows.append(Fact(key: "Departs", value: Self.stamp(start, zone: summary.startZone))) }
            if let end = leg.endDate { rows.append(Fact(key: "Arrives", value: Self.stamp(end, zone: summary.endZone))) }
            if let minutes = leg.travelDurationMinutes, minutes > 0 { rows.append(Fact(key: "Duration", value: ItemSummary.durationText(minutes: minutes))) }
        case .lodging(let stay):
            if let address = summary.address { rows.append(Fact(key: "Address", value: address)) }
            if let checkIn = stay.checkIn { rows.append(Fact(key: "Check-in", value: Self.stamp(checkIn, zone: summary.startZone))) }
            if let checkOut = stay.checkOut, stay.hasValidStay { rows.append(Fact(key: "Check-out", value: Self.stamp(checkOut, zone: summary.endZone))) }
        case .location:
            if let address = summary.address { rows.append(Fact(key: "Address", value: address)) }
        default:
            break
        }
        if let price = Self.price(for: item) { rows.append(Fact(key: "Price", value: price)) }
        return rows
    }

    private static func stamp(_ date: Date, zone: TimeZone) -> String {
        let day = Date.FormatStyle(timeZone: zone).weekday(.abbreviated).day().month(.abbreviated)
        var text = date.formatted(day) + " " + TripTime.shortTime(date, in: zone)
        if let abbreviation = zone.abbreviation(for: date) { text += " " + abbreviation }
        return text
    }

    private static func price(for item: TripPlan.Item) -> String? {
        let raw: (String?, String?)
        switch item {
        case .location(let place, _): raw = (place.price, place.priceCurrency)
        case .transportation(let leg): raw = (leg.price, leg.priceCurrency)
        case .lodging(let stay): raw = (stay.price, stay.priceCurrency)
        default: return nil
        }
        guard let text = raw.0, let amount = Decimal(string: text), amount > 0 else { return nil }
        if let code = raw.1?.nilIfBlank { return amount.formatted(.currency(code: code)) }
        return amount.formatted()
    }

    /// Apple Maps directions to the item's coordinate, or its address.
    nonisolated static func directionsURL(for summary: ItemSummary) -> URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        if let point = summary.kind == .transportation ? (summary.coordinate ?? summary.destination) : summary.coordinate {
            components?.queryItems = [
                URLQueryItem(name: "daddr", value: "\(point.latitude),\(point.longitude)"),
                URLQueryItem(name: "q", value: summary.title),
            ]
        } else if let address = summary.address {
            components?.queryItems = [URLQueryItem(name: "daddr", value: address)]
        } else {
            return nil
        }
        return components?.url
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}

/// The photo at the top, from the offline pack, or nothing when the item has none.
private struct Hero: View {
    let summary: ItemSummary
    @Environment(AppModel.self) private var model
    @State private var image: UIImage?
    @ScaledMetric private var height: CGFloat = 220

    var body: some View {
        if let url = summary.imageURL {
            ZStack {
                LinearGradient(colors: [ALColor.secondaryFocus, ALColor.primaryFocus], startPoint: .top, endPoint: .bottom)
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipped()
            .accessibilityHidden(true)
            .task(id: url) {
                if let data = await model.imageData(for: url) { image = UIImage(data: data) }
            }
        }
    }
}

extension ItemSummary {
    /// Apple Maps directions to the item, when it has a place.
    var directionsURL: URL? { ItemDetailContent.directionsURL(for: self) }
}

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
