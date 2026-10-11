// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALStore
import Foundation
import Network
import Observation

/// App-wide state: who is signed in, the trip list, the trips opened so far, and edits on their
/// way to the server.
///
/// Everything shows the saved copy first and then refreshes from the server when it can, so the
/// app works the same with no signal. Edits are shown at once on top of the saved copy and sent
/// in order when the server can be reached (the outbox).
@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case signedOut
        case signedIn(ServerCredentials)
    }

    struct LoadedTrip {
        /// The saved copy with this phone's unsent edits applied.
        var plan: TripPlan
        var savedAt: Date
    }

    private(set) var phase: Phase
    private(set) var ownedTrips: [CollectionSummary] = []
    private(set) var sharedTrips: [CollectionSummary] = []
    private(set) var tripListSavedAt: Date?
    private(set) var isRefreshing = false
    /// Trips loaded so far this session, by id, as shown.
    private(set) var trips: [String: LoadedTrip] = [:]
    /// Why the last refresh failed, when it did. The saved copy is still shown.
    var lastError: String?
    /// Set when sign-out could not delete the saved credentials; the session stays signed in.
    var signOutError: String?
    var showingSignOutError: Bool {
        get { signOutError != nil }
        set { if !newValue { signOutError = nil } }
    }
    /// The trip the Today, Trip and Map tabs show.
    var selectedTripID: String?

    /// Edits not yet on the server, conflicts, failures and notices.
    private(set) var outbox = Outbox()
    /// Itinerary rows skipped on Today, by trip. Kept on this phone only.
    private(set) var skipped: [String: Set<String>] = [:]
    /// An edit is being sent right now.
    private(set) var isSyncing = false
    /// Sending stopped for a reason the person has to fix (the API key stopped working).
    private(set) var syncProblem: String?

    private let credentialStore: any CredentialStore
    let snapshots: TripSnapshotStore
    let images: ImageStore
    let deviceState: DeviceStateStore
    private(set) var client: AdventureLogClient?
    /// The server's copy of each trip, exactly as last fetched or saved.
    private var savedTrips: [String: TripSnapshotStore.Snapshot<CollectionDetail>] = [:]
    /// Bumped each time an edit to a trip is settled, so a fetch that started before can't
    /// briefly show the trip without it.
    private var tripRevisions: [String: Int] = [:]
    /// Numbers each trip fetch, and the newest one shown, so a slow response can't replace a newer one.
    private var fetchCounter = 0
    private var newestFetchShown: [String: Int] = [:]
    /// The client whose trip-list refresh is in flight; a new session's client can start its own.
    private var refreshingClient: AdventureLogClient?
    /// Writes to disk run one after another through this chain, so sign-out can wait for every
    /// write queued before it and then delete. Actors alone don't promise that order.
    private var pendingWrites: Task<Void, Never>?
    /// Bumped on every sign-in and sign-out. Work that started in an earlier session is dropped,
    /// so it can't put the previous account's trips back on screen.
    private var session = 0
    private var deviceStateLoaded = false
    private var sendTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var pathMonitor: NWPathMonitor?
    private let pinnedNow: Date?

    init(credentialStore: any CredentialStore, snapshots: TripSnapshotStore, images: ImageStore,
         deviceState: DeviceStateStore, now: Date? = nil) {
        self.credentialStore = credentialStore
        self.snapshots = snapshots
        self.images = images
        self.deviceState = deviceState
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
            return AppModel(credentialStore: KeychainCredentialStore(), snapshots: TripSnapshotStore(), images: ImageStore(),
                            deviceState: DeviceStateStore(), now: options.now)
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "uitest-\(UUID().uuidString)")
        let credentials = InMemoryCredentialStore()
        let snapshots = TripSnapshotStore(directory: directory.appending(path: "Trips"))
        if options.offlineSeed {
            Self.seed(options, credentials: credentials, directory: directory.appending(path: "Trips"))
        }
        return AppModel(credentialStore: credentials, snapshots: snapshots, images: ImageStore(directory: directory.appending(path: "Images")),
                        deviceState: DeviceStateStore(directory: directory.appending(path: "Device")), now: options.now)
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
        resetSession()
        await drainWrites()
        try await snapshots.removeAll()
        try await images.removeAll()
        try await deviceState.removeAll()
        deviceStateLoaded = true
        let credentials = ServerCredentials(serverURL: url, apiKey: key, username: user.username, displayName: user.displayName)
        try credentialStore.save(credentials)
        self.client = client
        phase = .signedIn(credentials)
        await refreshTrips()
    }

    /// Deletes the saved credentials, ends the session, then deletes the offline copies and any
    /// unsent edits. If the credentials can't be deleted it stays signed in and sets
    /// `signOutError`, since the next launch would otherwise restore them. The session ends before
    /// the first `await`, so work still in flight is no longer current and can't write anything back.
    func signOut() async {
        do {
            try credentialStore.clear()
        } catch {
            signOutError = error.localizedDescription
            return
        }
        resetSession()
        client = nil
        lastError = nil
        phase = .signedOut
        await drainWrites()
        try? await snapshots.removeAll()
        try? await images.removeAll()
        try? await deviceState.removeAll()
    }

    /// Forgets everything held in memory for the current account and starts a new session.
    private func resetSession() {
        session += 1
        sendTask?.cancel()
        sendTask = nil
        retryTask?.cancel()
        retryTask = nil
        refreshingClient = nil
        isRefreshing = false
        isSyncing = false
        syncProblem = nil
        ownedTrips = []
        sharedTrips = []
        trips = [:]
        savedTrips = [:]
        tripRevisions = [:]
        newestFetchShown = [:]
        outbox = Outbox()
        skipped = [:]
        selectedTripID = nil
        tripListSavedAt = nil
    }

    // MARK: Trip list

    func sections(matching query: String = "") -> TripListSections {
        TripListSections(owned: ownedTrips, shared: sharedTrips, today: today, matching: query)
    }

    /// Shows the saved list immediately, then refreshes from the server when reachable.
    func loadTrips() async {
        let started = session
        await loadDeviceState()
        if ownedTrips.isEmpty, sharedTrips.isEmpty, let saved = await snapshots.tripList(),
           session == started, credentials != nil {
            ownedTrips = saved.owned
            sharedTrips = saved.shared
            tripListSavedAt = saved.savedAt
        }
        if selectedTripID == nil { selectedTripID = sections().current?.id }
        startMonitoringNetwork()
        sendSoon()
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
            queueWrite { _ = try? await store.saveTripList(.init(owned: o, shared: s, savedAt: .now)) }
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
        let started = session
        await loadDeviceState()
        if savedTrips[id] == nil, let saved = await snapshots.trip(id: id) {
            guard session == started, credentials != nil else { return }
            if savedTrips[id] == nil {
                savedTrips[id] = saved
                show(id)
            }
        }
        guard let client else { return }
        let revision = tripRevisions[id, default: 0]
        fetchCounter += 1
        let fetch = fetchCounter
        do {
            let detail = try await client.collection(id: id)
            guard isCurrent(client) else { return }
            lastError = nil
            // An edit settled while this was in flight; the refresh after sending fetches again.
            guard tripRevisions[id, default: 0] == revision else { return }
            // A fetch that started later has already been shown.
            guard fetch > newestFetchShown[id, default: 0] else { return }
            newestFetchShown[id] = fetch
            let savedAt = Date.now
            savedTrips[id] = TripSnapshotStore.Snapshot(value: detail, savedAt: savedAt)
            show(id)
            let store = snapshots
            queueWrite { _ = try? await store.saveTrip(detail, at: savedAt) }
            let urls = ImageStore.imageURLs(in: detail)
            let images = self.images
            Task.detached(priority: .utility) {
                await images.prefetch(urls) { try await client.media(at: $0) }
            }
        } catch {
            if isCurrent(client) { lastError = Self.describe(error) }
        }
    }

    /// Refreshes the trip on screen, so changes made on other phones show up.
    func refreshOpenTrip() async {
        guard let id = selectedTripID else { return }
        await loadTrip(id: id)
    }

    /// Rebuilds what a trip shows: the saved copy with the outbox's edits on top.
    private func show(_ id: String) {
        guard let saved = savedTrips[id] else {
            trips[id] = nil
            return
        }
        let detail = saved.value.applying(outbox.visibleEdits(for: id))
        trips[id] = LoadedTrip(plan: TripPlan(detail), savedAt: saved.savedAt)
    }

    // MARK: Editing

    /// Ticks or unticks a checklist item.
    func setChecked(_ checked: Bool, itemID: String, in checklist: Checklist, tripID: String) {
        guard let edit = TripEdit.CheckItem(checklist: checklist, itemID: itemID, isChecked: checked) else { return }
        perform(.checkItem(edit), in: tripID)
    }

    /// Replaces a note's text. `note` is the note as shown, so a second edit builds on the first.
    func saveNote(_ note: Note, content: String, tripID: String) {
        perform(.editNote(.init(noteID: note.id, noteName: note.name, baseContent: note.content ?? "", content: content)), in: tripID)
    }

    /// Puts a row at `index` on `date`, or trip-wide when `date` is nil.
    func move(_ entry: TripPlan.Entry, to date: CalendarDate?, at index: Int, tripID: String) {
        perform(.moveRow(.init(rowID: entry.row.id, title: entry.item.title, toDate: date, toIndex: index)), in: tripID)
    }

    private func perform(_ edit: TripEdit, in tripID: String) {
        guard credentials != nil else { return }
        outbox.enqueue(edit, tripID: tripID, at: .now)
        show(tripID)
        saveDeviceState()
        sendSoon()
    }

    // MARK: Skipping (this phone only)

    func isSkipped(_ rowID: String, tripID: String) -> Bool {
        skipped[tripID]?.contains(rowID) == true
    }

    func setSkipped(_ value: Bool, rowID: String, tripID: String) {
        guard credentials != nil else { return }
        var rows = skipped[tripID] ?? []
        if value { rows.insert(rowID) } else { rows.remove(rowID) }
        skipped[tripID] = rows.isEmpty ? nil : rows
        saveDeviceState()
    }

    // MARK: Sync

    /// Edits for one trip that need a decision or were dropped.
    func issues(for tripID: String) -> (entries: [PendingEdit], notices: [SyncNotice]) {
        (outbox.entries.filter { $0.tripID == tripID && !$0.isWaiting }, outbox.notices.filter { $0.tripID == tripID })
    }

    func hasWaitingEdit(forItem itemID: String, tripID: String) -> Bool {
        outbox.hasWaitingEdit(forItem: itemID, tripID: tripID)
    }

    /// Keeps this phone's version of a note that was also changed elsewhere.
    func keepMine(_ id: UUID) { changeOutbox { $0.keepMine(id) } }

    /// Drops this phone's edit. For a conflicting note, shows the server's version straight away.
    func discard(_ id: UUID) {
        if let entry = outbox.entries.first(where: { $0.id == id }), case .conflict(let conflict) = entry.state,
           case .editNote(let edit) = entry.edit, var saved = savedTrips[entry.tripID],
           let note = saved.value.notes.firstIndex(where: { $0.id == edit.noteID }) {
            saved.value.notes[note].content = conflict.serverContent
            savedTrips[entry.tripID] = saved
            let tripID = entry.tripID
            Task { await loadTrip(id: tripID) }
        }
        changeOutbox { $0.discard(id) }
    }

    func retry(_ id: UUID) { changeOutbox { $0.retry(id) } }

    func dismissNotice(_ id: UUID) { changeOutbox { $0.dismissNotice(id) } }

    private func changeOutbox(_ change: (inout Outbox) -> Void) {
        guard credentials != nil else { return }
        let before = Set(outbox.entries.map(\.tripID))
        change(&outbox)
        for id in before.union(outbox.entries.map(\.tripID)) { show(id) }
        saveDeviceState()
        sendSoon()
    }

    /// Sends waiting edits now, without waiting out a back-off: pull to refresh, the connection
    /// coming back, the app coming to the front.
    func syncNow() {
        outbox.retryNow()
        sendSoon()
    }

    /// Starts sending unless a send is already running.
    private func sendSoon() {
        guard sendTask == nil, let client, credentials != nil, outbox.next(at: .now) != nil else {
            scheduleRetry()
            return
        }
        let started = session
        sendTask = Task { [weak self] in
            await self?.send(with: client, session: started)
        }
    }

    /// Sends edits one at a time, in order, until the outbox is empty or a send has to wait.
    private func send(with client: AdventureLogClient, session started: Int) async {
        let sender = EditSender(server: client)
        var touched = Set<String>()
        while session == started, isCurrent(client), let entry = outbox.next(at: .now) {
            isSyncing = true
            let outcome = await sender.send(entry.edit, tripID: entry.tripID)
            guard session == started, isCurrent(client) else { return }
            outbox.record(outcome, for: entry.id, sent: entry.edit, at: .now)
            if outcome == .done { settle(entry.edit, in: entry.tripID) }
            tripRevisions[entry.tripID, default: 0] += 1
            touched.insert(entry.tripID)
            show(entry.tripID)
            saveDeviceState()
            if case .unauthorized(let message) = outcome {
                syncProblem = "AdventureLog didn't accept the API key (\(message)). Your changes are kept on this phone."
                break
            }
            syncProblem = nil
            if case .retry = outcome { break }
        }
        guard session == started else { return }
        isSyncing = false
        sendTask = nil
        scheduleRetry()
        // Fetch what the server now has, so the saved copy includes the edits just sent.
        for id in touched {
            guard session == started else { return }
            await loadTrip(id: id)
        }
    }

    /// Puts an edit the server now has into the saved copy, so the trip doesn't flick back while
    /// (or if) the refresh after sending is still to come. The refresh replaces it with the server's own.
    private func settle(_ edit: TripEdit, in tripID: String) {
        guard var saved = savedTrips[tripID] else { return }
        edit.apply(to: &saved.value)
        savedTrips[tripID] = saved
        let detail = saved.value
        let savedAt = saved.savedAt
        let store = snapshots
        queueWrite { _ = try? await store.saveTrip(detail, at: savedAt) }
    }

    /// Wakes the sender when the first waiting edit's back-off ends. Not while the API key is
    /// refused: that waits for the person, or for the app coming back to the front.
    private func scheduleRetry() {
        retryTask?.cancel()
        retryTask = nil
        guard sendTask == nil, syncProblem == nil, let at = outbox.nextAttempt else { return }
        let started = session
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, at.timeIntervalSinceNow)))
            guard !Task.isCancelled, let self, self.session == started else { return }
            self.retryTask = nil
            self.sendSoon()
        }
    }

    /// Sends waiting edits and refreshes as soon as the network comes back.
    private func startMonitoringNetwork() {
        guard pathMonitor == nil else { return }
        let (paths, continuation) = AsyncStream.makeStream(of: Bool.self, bufferingPolicy: .bufferingNewest(1))
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { path in continuation.yield(path.status == .satisfied) }
        monitor.start(queue: DispatchQueue(label: "AdventureLog.network"))
        pathMonitor = monitor
        Task { [weak self] in
            var wasOnline = true
            for await online in paths {
                if online && !wasOnline { self?.connectionCameBack() }
                wasOnline = online
            }
        }
    }

    private func connectionCameBack() {
        guard credentials != nil else { return }
        if outbox.waitingCount > 0 { syncNow() }
        if lastError != nil {
            Task { await refreshOpenTrip() }
        }
    }

    /// The app came to the front.
    func becameActive() {
        guard credentials != nil else { return }
        syncNow()
        Task { await refreshOpenTrip() }
    }

    // MARK: Device state

    /// Loads unsent edits and skips saved by an earlier launch, once.
    private func loadDeviceState() async {
        guard !deviceStateLoaded else { return }
        let started = session
        let state = await deviceState.load()
        guard !deviceStateLoaded, session == started, credentials != nil else { return }
        deviceStateLoaded = true
        outbox = state.outbox
        skipped = state.skipped
        for id in savedTrips.keys { show(id) }
    }

    private func saveDeviceState() {
        let state = DeviceStateStore.State(outbox: outbox, skipped: skipped)
        let store = deviceState
        queueWrite { try? await store.save(state) }
    }

    // MARK: Disk writes

    /// Queues a write behind the ones already queued. Call it with no `await` between the
    /// `isCurrent` check and the call, so a write is only ever queued for the current session.
    private func queueWrite(_ write: @escaping @Sendable () async -> Void) {
        let previous = pendingWrites
        pendingWrites = Task {
            await previous?.value
            await write()
        }
    }

    /// Waits for every queued write to finish.
    private func drainWrites() async {
        let pending = pendingWrites
        pendingWrites = nil
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
