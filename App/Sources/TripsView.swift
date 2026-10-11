// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI

/// The Trips screen (Design/review-1, 06): happening now, upcoming, shared with you, past.
/// The root of the Trip tab; on launch it opens the trip that is happening now.
struct TripsView: View {
    @Environment(AppModel.self) private var model
    @State private var path = NavigationPath()
    @State private var query = ""
    @State private var showingTokens = false
    @State private var openedCurrentTrip = false

    var body: some View {
        NavigationStack(path: $path) {
            let sections = model.sections(matching: query)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ALSpace.space3) {
                    if let message = model.lastError {
                        OfflineBanner(message: message)
                    }
                    if !sections.happeningNow.isEmpty {
                        Overline("Happening now")
                        ForEach(sections.happeningNow) { trip in
                            NavigationLink(value: trip.id) { CurrentTripCard(trip: trip, today: model.today) }
                                .buttonStyle(.plain)
                        }
                    }
                    TripGroup(title: "Upcoming", trips: sections.upcoming, today: model.today)
                    TripGroup(title: "Shared with you", trips: sections.shared, today: model.today, shared: true)
                    TripGroup(title: "Past", trips: sections.past, today: model.today)
                    TripGroup(title: "Collections", trips: sections.collections, today: model.today)

                    if sections.isEmpty, !model.isRefreshing {
                        ContentUnavailableView(
                            query.isEmpty ? "No trips yet" : "No matches",
                            systemImage: "map",
                            description: Text(query.isEmpty
                                ? "Collections you create or that are shared with you in AdventureLog appear here."
                                : "No trip names match “\(query)”.")
                        )
                        .padding(.top, ALSpace.space8)
                    }
                    if let savedAt = model.tripListSavedAt {
                        Text("Updated \(savedAt.formatted(.relative(presentation: .named)))")
                            .font(ALFont.footnote)
                            .foregroundStyle(ALColor.inkMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.top, ALSpace.space2)
                    }
                }
                .padding(.horizontal, ALSpace.space4)
                .padding(.bottom, ALSpace.space6)
            }
            .background(ALColor.surface100)
            .accessibilityIdentifier("trips.list")
            .navigationTitle("Trips")
            .searchable(text: $query, prompt: "Search trips")
            .refreshable { await model.refreshTrips() }
            .navigationDestination(for: String.self) { id in
                TripView(tripID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { accountMenu }
            }
            .sheet(isPresented: $showingTokens) {
                NavigationStack { TokenGallery() }
            }
            .onChange(of: model.selectedTripID, initial: true) { _, id in
                // Open the trip that is happening now, once, when the list first knows about it.
                guard !openedCurrentTrip, let id, path.isEmpty, model.sections().current?.id == id else { return }
                openedCurrentTrip = true
                path.append(id)
            }
        }
    }

    private var accountMenu: some View {
        Menu {
            if let credentials = model.credentials {
                Text(credentials.displayName ?? credentials.username ?? "Signed in")
                Text(credentials.serverURL.host() ?? credentials.serverURL.absoluteString)
            }
            Button("Design tokens", systemImage: "paintpalette") { showingTokens = true }
            Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                Task { await model.signOut() }
            }
        } label: {
            Image(systemName: "person.crop.circle")
        }
        .accessibilityLabel("Account")
    }
}

/// A plain line saying the server could not be reached; the saved copy stays on screen.
struct OfflineBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "icloud.slash")
            .font(ALFont.footnote)
            .foregroundStyle(ALColor.inkMuted)
            .padding(.vertical, ALSpace.space1)
            .accessibilityIdentifier("offline.banner")
    }
}

/// The card for a trip that is happening now, in the Next up card's style.
private struct CurrentTripCard: View {
    let trip: CollectionSummary
    let today: CalendarDate

    var body: some View {
        VStack(alignment: .leading, spacing: ALSpace.space1) {
            if let progress = TripText.progress(trip, today: today) {
                Text(progress)
                    .font(ALFont.overline)
                    .textCase(.uppercase)
                    .kerning(0.6)
                    .foregroundStyle(ALColor.primaryText)
            }
            Text(trip.name)
                .font(ALFont.title3)
                .foregroundStyle(ALColor.ink)
                .multilineTextAlignment(.leading)
            Text(TripText.subtitle(trip))
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
        }
        .alCard(padding: ALSpace.space4)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the trip")
    }
}

private struct TripGroup: View {
    let title: String
    let trips: [CollectionSummary]
    let today: CalendarDate
    var shared = false

    var body: some View {
        if !trips.isEmpty {
            Overline(title).padding(.top, ALSpace.space2)
            ALGroup {
                ForEach(trips) { trip in
                    NavigationLink(value: trip.id) {
                        TripRow(trip: trip, shared: shared)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct TripRow: View {
    let trip: CollectionSummary
    let shared: Bool
    @ScaledMetric(relativeTo: .body) private var thumb: CGFloat = 56

    var body: some View {
        HStack(spacing: ALSpace.space3) {
            TripThumbnail(id: trip.id)
                .frame(width: thumb, height: thumb)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name)
                    .font(ALFont.headline)
                    .foregroundStyle(ALColor.ink)
                    .multilineTextAlignment(.leading)
                Text(shared ? TripText.sharedSubtitle(trip) : TripText.subtitle(trip))
                    .font(ALFont.footnote)
                    .foregroundStyle(ALColor.inkMuted)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(ALColor.inkMuted)
                .accessibilityHidden(true)
        }
        .padding(ALSpace.space3)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A soft gradient picked from the trip's id, so each trip keeps its own colour.
struct TripThumbnail: View {
    let id: String

    private static let palettes: [(Color, Color)] = [
        (ALColor.secondary, ALColor.primary),
        (ALColor.accent, ALColor.primaryFocus),
        (ALColor.primary, ALColor.secondaryFocus),
        (ALColor.secondaryFocus, ALColor.accentFocus),
    ]

    var body: some View {
        let index = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Self.palettes.count
        let pair = Self.palettes[index]
        RoundedRectangle(cornerRadius: ALRadius.tile, style: .continuous)
            .fill(LinearGradient(colors: [pair.0, pair.1], startPoint: .topLeading, endPoint: .bottomTrailing))
            .accessibilityHidden(true)
    }
}

/// Short texts about a trip, shared by the list and the trip screen.
enum TripText {
    static func subtitle(_ trip: CollectionSummary) -> String {
        var parts: [String] = []
        if let start = trip.startDate, let end = trip.endDate {
            parts.append(DateRangeText.text(start, end))
        }
        if !trip.collaborators.filter({ $0.isCurrentUser != true }).isEmpty {
            let names = trip.collaborators.filter { $0.isCurrentUser != true }.map(\.displayName)
            parts.append("with " + ListFormatter.localizedString(byJoining: names))
        }
        if let count = trip.locationCount, count > 0 { parts.append(count == 1 ? "1 place" : "\(count) places") }
        return parts.isEmpty ? "Collection" : parts.joined(separator: " · ")
    }

    static func sharedSubtitle(_ trip: CollectionSummary) -> String {
        let owner = trip.collaborators.first { $0.isOwner == true }?.displayName
        var parts: [String] = []
        if let owner { parts.append("from \(owner)") }
        if let start = trip.startDate, let end = trip.endDate { parts.append(DateRangeText.text(start, end)) }
        return parts.isEmpty ? "Shared collection" : parts.joined(separator: " · ")
    }

    /// "Day 4 of 19".
    static func progress(_ trip: CollectionSummary, today: CalendarDate) -> String? {
        guard let start = trip.startDate, let end = trip.endDate else { return nil }
        let first = min(start, end), last = max(start, end)
        guard first <= today, today <= last else { return nil }
        return "Day \(today.days(since: first) + 1) of \(last.days(since: first) + 1)"
    }
}

/// "5–23 Mar 2027" style ranges from calendar dates, without passing through any time zone.
enum DateRangeText {
    /// Formats a localized date-only interval, putting the earlier date first even for a reversed range.
    static func text(_ start: CalendarDate, _ end: CalendarDate, locale: Locale = .autoupdatingCurrent) -> String {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let style = Date.IntervalFormatStyle(date: .abbreviated, time: .omitted, locale: locale, calendar: calendar, timeZone: utc)
        let a = start.startOfDay(in: utc), b = end.startOfDay(in: utc)
        // The server does not enforce start <= end.
        return (min(a, b)..<max(a, b)).formatted(style)
    }
}
