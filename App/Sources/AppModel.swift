// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALStore
import Foundation
import Observation

/// App-wide state: who is signed in, and the trip list. Screens own their own loading.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case signedOut
        case signedIn(ServerCredentials)
    }

    private(set) var phase: Phase
    private(set) var ownedTrips: [CollectionSummary] = []
    private(set) var sharedTrips: [CollectionSummary] = []
    private(set) var tripListSavedAt: Date?
    private(set) var isRefreshing = false
    var lastError: String?
    /// Set when sign-out could not delete the saved credentials; the session stays signed in.
    var signOutError: String?
    var showingSignOutError: Bool {
        get { signOutError != nil }
        set { if !newValue { signOutError = nil } }
    }

    private let credentialStore: any CredentialStore
    let snapshots: TripSnapshotStore
    private(set) var client: AdventureLogClient?
    /// The client whose trip refresh is in flight; a new session's client can start its own.
    private var refreshingClient: AdventureLogClient?

    /// Restores saved credentials without contacting the server; starts signed out if loading fails.
    init(credentialStore: any CredentialStore, snapshots: TripSnapshotStore) {
        self.credentialStore = credentialStore
        self.snapshots = snapshots
        if let saved = try? credentialStore.load() {
            phase = .signedIn(saved)
            client = AdventureLogClient(baseURL: saved.serverURL, apiKey: saved.apiKey)
        } else {
            phase = .signedOut
        }
    }

    /// Uses persistent storage normally; a reset launch uses in-memory credentials and a new temporary snapshot directory.
    static func forLaunch(_ options: LaunchOptions = .current) -> AppModel {
        if options.resetState {
            let directory = FileManager.default.temporaryDirectory.appending(path: "uitest-\(UUID().uuidString)")
            return AppModel(credentialStore: InMemoryCredentialStore(), snapshots: TripSnapshotStore(directory: directory))
        }
        return AppModel(credentialStore: KeychainCredentialStore(), snapshots: TripSnapshotStore())
    }

    var credentials: ServerCredentials? {
        if case .signedIn(let credentials) = phase { return credentials }
        return nil
    }

    // MARK: Sign in and out

    /// Validates the address and trimmed key, saves credentials, signs in, and refreshes trips.
    /// - Throws: `APIError.badServerURL` for an unusable address, or errors from the user request
    ///   or credential store. Trip refresh errors are recorded in `lastError` after sign-in.
    func signIn(server: String, apiKey: String) async throws {
        guard let url = AdventureLogClient.normalizedServerURL(server) else { throw APIError.badServerURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = AdventureLogClient(baseURL: url, apiKey: key)
        let user = try await client.currentUser()
        let credentials = ServerCredentials(serverURL: url, apiKey: key, username: user.username, displayName: user.displayName)
        try credentialStore.save(credentials)
        self.client = client
        phase = .signedIn(credentials)
        await refreshTrips()
    }

    /// Deletes the saved credentials, ends the session, then attempts to delete snapshots.
    /// If the credentials can't be deleted, stays signed in and sets `signOutError`, since the next
    /// launch would otherwise restore them. The session ends before the first `await`, so a refresh
    /// still in flight is no longer current and can't write snapshots back. Snapshot deletion
    /// errors are ignored, so cached trips may remain.
    func signOut() async {
        do {
            try credentialStore.clear()
        } catch {
            signOutError = error.localizedDescription
            return
        }
        client = nil
        refreshingClient = nil
        isRefreshing = false
        ownedTrips = []
        sharedTrips = []
        tripListSavedAt = nil
        lastError = nil
        phase = .signedOut
        try? await snapshots.removeAll()
    }

    // MARK: Trips

    /// Shows the saved list immediately, then refreshes from the server when reachable.
    func loadTrips() async {
        if ownedTrips.isEmpty, sharedTrips.isEmpty, let saved = await snapshots.tripList() {
            ownedTrips = saved.owned
            sharedTrips = saved.shared
            tripListSavedAt = saved.savedAt
        }
        await refreshTrips()
    }

    /// Refreshes and sorts both trip lists, then attempts to save an offline copy.
    /// Does nothing without a client or while this client is already refreshing. Request failures
    /// preserve the current lists and set `lastError`; snapshot write failures are ignored.
    /// Results that arrive after a sign-out or a new sign-in are dropped.
    func refreshTrips() async {
        guard let client, refreshingClient !== client else { return }
        refreshingClient = client
        isRefreshing = true
        defer {
            if refreshingClient === client {
                refreshingClient = nil
                isRefreshing = false
            }
        }
        do {
            async let owned = client.ownedCollections()
            async let shared = client.sharedCollections()
            let (o, s) = try await (owned, shared)
            guard isCurrent(client) else { return }
            ownedTrips = o.sorted(by: Self.tripOrder)
            sharedTrips = s.sorted(by: Self.tripOrder)
            tripListSavedAt = .now
            lastError = nil
            try? await snapshots.saveTripList(.init(owned: ownedTrips, shared: sharedTrips, savedAt: .now))
        } catch {
            guard isCurrent(client) else { return }
            lastError = error.localizedDescription
        }
    }

    /// Whether `client` still belongs to the signed-in session, so its results may be shown or saved.
    func isCurrent(_ client: AdventureLogClient) -> Bool {
        credentials != nil && self.client === client
    }

    /// Trips with dates first, soonest first; undated collections after, by name.
    nonisolated static func tripOrder(_ a: CollectionSummary, _ b: CollectionSummary) -> Bool {
        switch (a.startDate, b.startDate) {
        case let (x?, y?): return x == y ? a.name < b.name : x < y
        case (.some, nil): return true
        case (nil, .some): return false
        case (nil, nil): return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }
}
