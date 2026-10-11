// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI
import UIKit

/// One item (Design/review-1, 04): photo, title and time, Navigate, the facts with a
/// tap-to-copy booking reference, notes and checklist items. Read-only until Stage 2.
struct ItemDetailView: View {
    let route: ItemRoute
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if let plan = model.trip(route.tripID)?.plan, let item = Self.find(route.itemID, in: plan) {
                ItemDetailContent(summary: ItemSummary(item, day: route.day, tripZone: plan.timeZone), item: item)
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
}

struct Fact: Identifiable, Hashable {
    let key: String
    let value: String
    var id: String { key }
}

private struct ItemDetailContent: View {
    let summary: ItemSummary
    let item: TripPlan.Item
    @Environment(\.openURL) private var openURL
    @State private var copied = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Hero(summary: summary)
                VStack(alignment: .leading, spacing: ALSpace.space3) {
                    header
                    actions
                    facts
                    if let notes = summary.notes {
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
                    if !summary.checklist.isEmpty {
                        Overline("Checklist").padding(.top, ALSpace.space2)
                        ALGroup {
                            ForEach(summary.checklist) { entry in
                                Label {
                                    Text(entry.name)
                                        .foregroundStyle(entry.isChecked ? ALColor.inkMuted : ALColor.ink)
                                        .strikethrough(entry.isChecked)
                                } icon: {
                                    Image(systemName: entry.isChecked ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(entry.isChecked ? ALColor.success : ALColor.inkMuted)
                                }
                                .font(ALFont.body)
                                .padding(ALSpace.space3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityValue(entry.isChecked ? "Done" : "Not done")
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
            if copied {
                Label("Copied", systemImage: "doc.on.doc")
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
        }
    }

    @ViewBuilder private var actions: some View {
        let directions = Self.directionsURL(for: summary)
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
                        withAnimation { copied = true }
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            withAnimation { copied = false }
                        }
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
    static func directionsURL(for summary: ItemSummary) -> URL? {
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

extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
