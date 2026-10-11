// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALStore
import Foundation
import Observation

/// App-wide state: who is signed in, the trip list, and the trips opened so far.
///
/// Everything shows the saved copy first and then refreshes from the server when it can, so the
/// app works the same with no signal.
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case signedOut
        case signedIn(ServerCredentials)
    }

    struct LoadedTrip {
        var plan: TripPlan
        var savedAt: Date
    }

    private(set) var phase: Phase
    private(set) var ownedTrips: [CollectionSummary] = []
    private(set) var sharedTrips: [CollectionSummary] = []
    private(set) var tripListSavedAt: Date?
    private(set) var isRefreshing = false
    /// Trips loaded so far this session, by id.
    private(set) var trips: [String: LoadedTrip] = [:]
    /// Why the last refresh failed, when it did. The saved copy is still shown.
    var lastError: String?
    /// Set when sign-out could not delete the saved credentials; the session stays signed in.
    var signOutError: String?
    var showingSignOutError: Bool {
        get { signOutError != nil }
        set { if !newValue { signOutError = nil } }
    }
    /// The trip the Trip and Map tabs show.
    var selectedTripID: String?

    private let credentialStore: any CredentialStore
    let snapshots: TripSnapshotStore
    let images: ImageStore
    private(set) var client: AdventureLogClient?
    /// The client whose trip-list refresh is in flight; a new session's client can start its own.
    private var refreshingClient: AdventureLogClient?
    /// Snapshot writes run one after another through this chain, so sign-out can wait for every
    /// write queued before it and then delete. Actors alone don't promise that order.
    private var snapshotWrites: Task<Void, Never>?
    private let pinnedNow: Date?

    init(credentialStore: any CredentialStore, snapshots: TripSnapshotStore, images: ImageStore, now: Date? = nil) {
        self.credentialStore = credentialStore
        self.snapshots = snapshots
        self.images = images
        self.pinnedNow = now
        if let saved = try? credentialStore.load() {
            phase = .signedIn(saved)
            client = AdventureLogClient(baseURL: saved.serverURL, apiKey: saved.apiKey)
        } else {
            phase = .signedOut
        }
    }

    /// Real storage, or throwaway storage when UI tests ask for a clean start.
    static func forLaunch(_ options: LaunchOptions = .current) -> AppModel {
        guard options.resetState else {
            return AppModel(credentialStore: KeychainCredentialStore(), snapshots: TripSnapshotStore(), images: ImageStore(), now: options.now)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "uitest-\(UUID().uuidString)")
        let credentials = InMemoryCredentialStore()
        let snapshots = TripSnapshotStore(directory: directory.appending(path: "Trips"))
        if options.offlineSeed {
            Self.seed(options, credentials: credentials, directory: directory.appending(path: "Trips"))
        }
        return AppModel(credentialStore: credentials, snapshots: snapshots, images: ImageStore(directory: directory.appending(path: "Images")), now: options.now)
    }

    /// Writes the seed trips the way a previous session would have, and signs in to a server that
    /// is never reachable (the discard port on loopback).
    private static func seed(_ options: LaunchOptions, credentials: InMemoryCredentialStore, directory: URL) {
        let decoder = ALCoding.decoder()
        let encoder = ALCoding.encoder()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let savedAt = Date(timeIntervalSinceNow: -3_600)
        if let data = options.seedList, let owned = try? decoder.decode([CollectionSummary].self, from: data),
           let list = try? encoder.encode(TripSnapshotStore.TripList(owned: owned, shared: [], savedAt: savedAt)) {
            try? list.write(to: directory.appending(path: "trip-list.json"))
        }
        if let data = options.seedTrip, let trip = try? decoder.decode(CollectionDetail.self, from: data),
           let snapshot = try? encoder.encode(TripSnapshotStore.Snapshot(value: trip, savedAt: savedAt)) {
            let safe = String(trip.id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
            try? snapshot.write(to: directory.appending(path: "trip-\(safe).json"))
        }
        let offline = ServerCredentials(serverURL: URL(string: "http://127.0.0.1:9")!, apiKey: "al_offline", username: "offline", displayName: "Offline test")
        try? credentials.save(offline)
    }

    var credentials: ServerCredentials? {
        if case .signedIn(let credentials) = phase { return credentials }
        return nil
    }

    // MARK: Clock

    /// The current time, or the pinned time in tests and Simulator runs.
    var now: Date { pinnedNow ?? .now }

    /// Today's date where the phone is. On the road the phone is in the trip's zone.
    var today: CalendarDate { CalendarDate(now, in: .autoupdatingCurrent) }

    // MARK: Sign in and out

    /// Validates the address and key against the server, then stores them.
    func signIn(server: String, apiKey: String) async throws {
        guard let url = AdventureLogClient.normalizedServerURL(server) else { throw APIError.badServerURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = AdventureLogClient(baseURL: url, apiKey: key)
        let user = try await client.currentUser()
        // Clear anything a previous session left behind, so one account never sees another's trips.
        await drainSnapshotWrites()
        try await snapshots.removeAll()
        try await images.removeAll()
        let credentials = ServerCredentials(serverURL: url, apiKey: key, username: user.username, displayName: user.displayName)
        try credentialStore.save(credentials)
        self.client = client
        phase = .signedIn(credentials)
        await refreshTrips()
    }

    /// Deletes the saved credentials, ends the session, then deletes the offline copies. If the
    /// credentials can't be deleted it stays signed in and sets `signOutError`, since the next launch
    /// would otherwise restore them. The session ends before the first `await`, so a refresh still in
    /// flight is no longer current and can't write anything back.
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
        trips = [:]
        selectedTripID = nil
        tripListSavedAt = nil
        lastError = nil
        phase = .signedOut
        await drainSnapshotWrites()
        try? await snapshots.removeAll()
        try? await images.removeAll()
    }

    // MARK: Trip list

    func sections(matching query: String = "") -> TripListSections {
        TripListSections(owned: ownedTrips, shared: sharedTrips, today: today, matching: query)
    }

    /// Shows the saved list immediately, then refreshes from the server when reachable.
    func loadTrips() async {
        if ownedTrips.isEmpty, sharedTrips.isEmpty, let saved = await snapshots.tripList() {
            ownedTrips = saved.owned
            sharedTrips = saved.shared
            tripListSavedAt = saved.savedAt
        }
        if selectedTripID == nil { selectedTripID = sections().current?.id }
        await refreshTrips()
    }

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
            ownedTrips = o
            sharedTrips = s
            tripListSavedAt = .now
            lastError = nil
            let store = snapshots
            queueSnapshotWrite { _ = try? await store.saveTripList(.init(owned: o, shared: s, savedAt: .now)) }
            if selectedTripID == nil { selectedTripID = sections().current?.id }
        } catch {
            if isCurrent(client) { lastError = Self.describe(error) }
            return
        }
        await saveForOffline()
    }

    /// Whether `client` still belongs to the signed-in session, so its results may be shown or saved.
    func isCurrent(_ client: AdventureLogClient) -> Bool {
        credentials != nil && self.client === client
    }

    /// Keeps every trip that is happening now or coming up, with its photos, on the phone.
    func saveForOffline() async {
        let sections = sections()
        for summary in sections.happeningNow + sections.upcoming + sections.shared.filter({ $0.isTrip }) {
            await loadTrip(id: summary.id)
        }
    }

    // MARK: Trips

    func trip(_ id: String) -> LoadedTrip? { trips[id] }

    /// The saved copy first, then the server's. Saves what comes back and fetches its photos.
    func loadTrip(id: String) async {
        if trips[id] == nil, let saved = await snapshots.trip(id: id) {
            trips[id] = LoadedTrip(plan: TripPlan(saved.value), savedAt: saved.savedAt)
        }
        guard let client else { return }
        do {
            let detail = try await client.collection(id: id)
            guard isCurrent(client) else { return }
            trips[id] = LoadedTrip(plan: TripPlan(detail), savedAt: .now)
            let store = snapshots
            queueSnapshotWrite { _ = try? await store.saveTrip(detail) }
            lastError = nil
            let urls = ImageStore.imageURLs(in: detail)
            let images = self.images
            Task.detached(priority: .utility) {
                await images.prefetch(urls) { try await client.media(at: $0) }
            }
        } catch {
            if isCurrent(client) { lastError = Self.describe(error) }
        }
    }

    /// Queues a snapshot write behind the ones already queued. Call it with no `await` between the
    /// `isCurrent` check and the call, so a write is only ever queued for the current session.
    private func queueSnapshotWrite(_ write: @escaping @Sendable () async -> Void) {
        let previous = snapshotWrites
        snapshotWrites = Task {
            await previous?.value
            await write()
        }
    }

    /// Waits for every queued snapshot write to finish.
    private func drainSnapshotWrites() async {
        let pending = snapshotWrites
        snapshotWrites = nil
        await pending?.value
    }

    /// Image bytes from the offline pack, downloading them if this is the first time.
    func imageData(for url: URL) async -> Data? {
        if let saved = await images.cachedData(for: url) { return saved }
        guard let client else { return nil }
        return try? await images.data(for: url) { try await client.media(at: $0) }
    }

    /// Says "offline" plainly instead of a URL error.
    static func describe(_ error: any Error) -> String {
        if let api = error as? APIError, case .transport = api { return "Can't reach your server. Showing the copy saved on this phone." }
        return error.localizedDescription
    }
}
