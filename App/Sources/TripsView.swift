// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALDesign
import SwiftUI

/// The trip list. Pre-design scaffold: it proves sign-in, loading and offline snapshots end to
/// end; the reviewed Trips screen replaces it in Stage 1.
struct TripsView: View {
    @Environment(AppModel.self) private var model
    @State private var showingTokens = false

    var body: some View {
        NavigationStack {
            List {
                if !model.ownedTrips.isEmpty {
                    Section("Your trips") {
                        ForEach(model.ownedTrips) { trip in
                            NavigationLink(value: trip.id) { TripRow(trip: trip) }
                        }
                    }
                }
                if !model.sharedTrips.isEmpty {
                    Section("Shared with you") {
                        ForEach(model.sharedTrips) { trip in
                            NavigationLink(value: trip.id) { TripRow(trip: trip) }
                        }
                    }
                }
                if model.ownedTrips.isEmpty, model.sharedTrips.isEmpty, !model.isRefreshing {
                    ContentUnavailableView(
                        "No collections yet",
                        systemImage: "map",
                        description: Text(model.lastError ?? "Collections you create or that are shared with you in AdventureLog appear here.")
                    )
                    .listRowBackground(Color.clear)
                }
                if let savedAt = model.tripListSavedAt {
                    Text("Updated \(savedAt.formatted(.relative(presentation: .named)))")
                        .font(ALFont.footnote)
                        .foregroundStyle(ALColor.inkMuted)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(ALColor.surface100)
            .accessibilityIdentifier("trips.list")
            .navigationTitle("Trips")
            .navigationDestination(for: String.self) { id in
                TripOutlineView(tripID: id)
            }
            .refreshable { await model.refreshTrips() }
            .task { await model.loadTrips() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
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
            .sheet(isPresented: $showingTokens) {
                NavigationStack { TokenGallery() }
            }
        }
    }
}

private struct TripRow: View {
    let trip: CollectionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(trip.name)
                .font(ALFont.headline)
                .foregroundStyle(ALColor.ink)
            Text(subtitle)
                .font(ALFont.subheadline)
                .foregroundStyle(ALColor.inkMuted)
        }
        .padding(.vertical, ALSpace.space1)
        .listRowBackground(ALColor.surface200)
    }

    private var subtitle: String {
        var parts: [String] = []
        if let start = trip.startDate, let end = trip.endDate {
            parts.append(DateRangeText.text(start, end))
        }
        if let count = trip.locationCount { parts.append(count == 1 ? "1 location" : "\(count) locations") }
        return parts.isEmpty ? "Collection" : parts.joined(separator: " · ")
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
