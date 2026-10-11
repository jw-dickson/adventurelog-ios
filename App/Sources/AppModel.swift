// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALStore
import BackgroundTasks
import Foundation
import Network
import Observation
import UserNotifications

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

    // Reminders: settings are per phone, in UserDefaults.
    private let defaults: UserDefaults
    private let reminderScheduler = ReminderScheduler()
    private var reminderTask: Task<Void, Never>?
    /// The person turned reminders on (and allowed notifications).
    private(set) var remindersEnabled: Bool
    private(set) var reminderPermission: UNAuthorizationStatus = .notDetermined
    var reminderSettings: ReminderSettings {
        didSet {
            if let data = try? JSONEncoder().encode(reminderSettings) { defaults.set(data, forKey: Keys.reminderSettings) }
            scheduleReminderUpdate()
        }
    }
    /// "Not now" on Today's reminder offer.
    var reminderOfferDismissed: Bool {
        didSet { defaults.set(reminderOfferDismissed, forKey: Keys.reminderOfferDismissed) }
    }

    private enum Keys {
        static let remindersEnabled = "al.remindersEnabled"
        static let reminderSettings = "al.reminderSettings"
        static let reminderOfferDismissed = "al.reminderOfferDismissed"
    }

    // Tracking: only on the days of a trip the person agreed to; the log never leaves the phone.
    let tracks: TrackStore
    let tracker = LocationTracker()
    /// Trips whose route the person agreed to log, and trips they said no to.
    private(set) var trackingAllowed: Set<String> = []
    private(set) var trackingDeclined: Set<String> = []
    /// The trip being recorded right now.
    private(set) var trackedTripID: String?
    /// Recorded points and geofence events, by trip, once read from disk.
    private(set) var trackPoints: [String: [TrackPoint]] = [:]
    private(set) var placeEvents: [String: [PlaceEvent]] = [:]
    private var watchTask: Task<Void, Never>?

    /// The background refresh that keeps the reminder window rolling and the trip fresh.
    nonisolated static let refreshTaskID = "app.adventurelog.refresh"

    init(credentialStore: any CredentialStore, snapshots: TripSnapshotStore, images: ImageStore,
         deviceState: DeviceStateStore, tracks: TrackStore = TrackStore(), defaults: UserDefaults = .standard,
         now: Date? = nil) {
        self.credentialStore = credentialStore
        self.tracks = tracks
        self.snapshots = snapshots
        self.images = images
        self.deviceState = deviceState
        self.defaults = defaults
        self.pinnedNow = now
        self.remindersEnabled = defaults.bool(forKey: Keys.remindersEnabled)
        self.reminderOfferDismissed = defaults.bool(forKey: Keys.reminderOfferDismissed)
        self.reminderSettings = defaults.data(forKey: Keys.reminderSettings)
            .flatMap { try? JSONDecoder().decode(ReminderSettings.self, from: $0) } ?? ReminderSettings()
        if let saved = try? credentialStore.load() {
            phase = .signedIn(saved)
            client = AdventureLogClient(baseURL: saved.serverURL, apiKey: saved.apiKey)
        } else {
            phase = .signedOut
        }
        tracker.onPoints = { [weak self] points in self?.recorded(points) }
        tracker.onEvent = { [weak self] event in self?.recorded(event) }
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
        // A defaults suite of its own, so one test's reminder choices don't leak into the next.
        let defaults = UserDefaults(suiteName: "uitest-\(UUID().uuidString)") ?? .standard
        let tracks = TrackStore(directory: directory.appending(path: "Tracks"))
        if options.offlineSeed, let data = options.seedTrack, let tripID = options.seedTripID {
            Self.seedTrack(data, tripID: tripID, directory: directory.appending(path: "Tracks"))
        }
        return AppModel(credentialStore: credentials, snapshots: snapshots, images: ImageStore(directory: directory.appending(path: "Images")),
                        deviceState: DeviceStateStore(directory: directory.appending(path: "Device")), tracks: tracks,
                        defaults: defaults, now: options.now)
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

    /// Writes a recorded route the way the tracker would have (JSON lines of `TrackPoint`).
    private static func seedTrack(_ data: Data, tripID: String, directory: URL) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safe = String(tripID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
        try? data.write(to: directory.appending(path: "track-\(safe).jsonl"))
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

    /// Signs in with an API key the person pasted. Validates it against the server, then stores it.
    func signIn(server: String, apiKey: String) async throws {
        guard let url = AdventureLogClient.normalizedServerURL(server) else { throw APIError.badServerURL }
        try await establish(url: url, apiKey: apiKey.trimmingCharacters(in: .whitespacesAndNewlines), apiKeyID: nil)
    }

    /// Finishes a password or provider sign-in: makes an API key for this phone with the session,
    /// then ends the session. The key, not the session, is what the app keeps, because a session
    /// expires after a couple of weeks without contact and a trip can be offline longer than that.
    func signIn(url: URL, sessionToken: String) async throws {
        let account = AccountClient(baseURL: url)
        let key = try await account.createAPIKey(named: Self.deviceKeyName(), sessionToken: sessionToken)
        await account.endSession(sessionToken)
        do {
            try await establish(url: url, apiKey: key.key, apiKeyID: key.id)
        } catch {
            // Don't leave an unused key behind on the server.
            try? await AdventureLogClient(baseURL: url, apiKey: key.key).deleteAPIKey(id: key.id)
            throw error
        }
    }

    /// "AdventureLog iOS · 11 Oct 2026", so the key is easy to recognise under Settings › API keys.
    static func deviceKeyName(now: Date = .now) -> String {
        "AdventureLog iOS · " + now.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// Checks the key against the server, clears anything a previous session left, and signs in.
    private func establish(url: URL, apiKey key: String, apiKeyID: String?) async throws {
        let client = AdventureLogClient(baseURL: url, apiKey: key)
        let user = try await client.currentUser()
        // Clear anything a previous session left behind, so one account never sees another's trips.
        resetSession()
        await drainWrites()
        try await snapshots.removeAll()
        try await images.removeAll()
        try await deviceState.removeAll()
        try await tracks.removeAll()
        deviceStateLoaded = true
        let credentials = ServerCredentials(serverURL: url, apiKey: key, username: user.username,
                                            displayName: user.displayName, apiKeyID: apiKeyID)
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
        // A key the app made at sign-in is revoked; one the person pasted stays theirs.
        let revoke = credentials?.apiKeyID.flatMap { id in client.map { (client: $0, id: id) } }
        resetSession()
        client = nil
        lastError = nil
        phase = .signedOut
        if let revoke {
            // Best effort: offline, the key stays until it's revoked in AdventureLog's settings.
            Task.detached { try? await revoke.client.deleteAPIKey(id: revoke.id) }
        }
        await reminderScheduler.removeAll()
        await tracker.unwatchAll()
        await drainWrites()
        try? await tracks.removeAll()
        try? await snapshots.removeAll()
        try? await images.removeAll()
        try? await deviceState.removeAll()
    }

    /// Forgets everything held in memory for the current account and starts a new session.
    private func resetSession() {
        session += 1
        sendTask?.cancel()
        sendTask = nil
        reminderTask?.cancel()
        reminderTask = nil
        watchTask?.cancel()
        watchTask = nil
        // Stop first: points already buffered belong to the old session and are dropped.
        trackedTripID = nil
        tracker.stop()
        trackingAllowed = []
        trackingDeclined = []
        trackPoints = [:]
        placeEvents = [:]
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
        await restoreSavedTrips()
        startMonitoringNetwork()
        sendSoon()
        await refreshTrips()
    }

    /// Shows the saved copies of the trips kept offline, before (and whether or not) the server answers.
    private func restoreSavedTrips() async {
        let started = session
        let sections = sections()
        for summary in sections.happeningNow + sections.upcoming + sections.shared.filter({ $0.isTrip })
        where savedTrips[summary.id] == nil {
            guard let saved = await snapshots.trip(id: summary.id) else { continue }
            guard session == started, credentials != nil else { return }
            if savedTrips[summary.id] == nil {
                savedTrips[summary.id] = saved
                show(summary.id)
            }
        }
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
            // A trip that left the list stops reminding even if nothing else reloads.
            scheduleReminderUpdate()
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
        scheduleReminderUpdate()
        updateTracking()
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
        scheduleReminderUpdate()
        if tripID == trackedTripID { updateTracking() }
    }

    // MARK: Reminders

    /// Turns reminders on (asking for notification permission) or off.
    func setRemindersEnabled(_ on: Bool) async {
        if on {
            let allowed = await reminderScheduler.requestPermission()
            await refreshReminderPermission()
            guard allowed else {
                remindersEnabled = false
                defaults.set(false, forKey: Keys.remindersEnabled)
                return
            }
        }
        remindersEnabled = on
        defaults.set(on, forKey: Keys.remindersEnabled)
        if on {
            await updateReminders()
        } else {
            await reminderScheduler.removeAll()
        }
    }

    func refreshReminderPermission() async {
        reminderPermission = await reminderScheduler.status()
    }

    /// Recalculates reminders a moment after the last change, so a burst of changes costs one pass.
    private func scheduleReminderUpdate() {
        guard remindersEnabled, credentials != nil else { return }
        reminderTask?.cancel()
        let started = session
        reminderTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.session == started else { return }
            await self.updateReminders()
        }
    }

    /// Schedules the next reminders across every loaded trip, soonest first, within iOS's limit.
    func updateReminders() async {
        guard remindersEnabled, credentials != nil else { return }
        let now = Date.now
        // Only trips still in the list: one deleted or no longer shared stops reminding.
        let listed = Set((ownedTrips + sharedTrips).map(\.id))
        var all: [Reminder] = []
        for (id, trip) in trips where listed.contains(id) {
            all += ReminderPlanner.reminders(for: trip.plan, now: now, skipped: skipped[id] ?? [], settings: reminderSettings)
        }
        all.sort { ($0.fireDate, $0.id) < ($1.fireDate, $1.id) }
        // A current trip whose plan isn't loaded (no list yet, or no saved copy) keeps whatever is
        // pending for it, so a cold offline launch never wipes reminders that could still fire.
        let sections = sections()
        let needed = (sections.happeningNow + sections.upcoming + sections.shared.filter(\.isTrip)).map(\.id)
        let complete = !listed.isEmpty && needed.allSatisfy { trips[$0] != nil }
        await reminderScheduler.replace(with: Array(all.prefix(ReminderPlanner.limit)), removeStale: complete)
    }

    /// The background refresh: fetch what changed, send waiting edits, roll the reminder window on.
    func backgroundRefresh() async {
        Self.scheduleBackgroundRefresh()
        guard credentials != nil else { return }
        await loadTrips()
        await updateReminders()
    }

    /// Asks iOS for the next background refresh, a few hours out.
    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Tracking (this phone only)

    /// The trip with a day today, preferring the one on screen.
    var tripWithDayToday: String? {
        let listed = Set((ownedTrips + sharedTrips).map(\.id))
        let candidates = trips.filter { listed.contains($0.key) && $0.value.plan.day(for: today) != nil }.map(\.key)
        if let selected = selectedTripID, candidates.contains(selected) { return selected }
        if let current = sections().current?.id, candidates.contains(current) { return current }
        return candidates.sorted().first
    }

    /// Whether Today should ask about logging this trip's route.
    func shouldOfferTracking(_ tripID: String) -> Bool {
        credentials != nil && deviceStateLoaded && !trackingAllowed.contains(tripID) && !trackingDeclined.contains(tripID)
            && trips[tripID]?.plan.day(for: today) != nil
    }

    /// The answer to Today's offer, or the switch on the Log tab.
    func setTracking(_ on: Bool, tripID: String) {
        guard credentials != nil else { return }
        if on {
            trackingAllowed.insert(tripID)
            trackingDeclined.remove(tripID)
        } else {
            trackingAllowed.remove(tripID)
            trackingDeclined.insert(tripID)
        }
        saveDeviceState()
        updateTracking()
    }

    /// Records on a trip day the person agreed to, and stops otherwise. Cheap to call often.
    func updateTracking() {
        guard credentials != nil, let id = tripWithDayToday, trackingAllowed.contains(id),
              let plan = trips[id]?.plan, tracker.authorization != .denied, tracker.authorization != .restricted
        else {
            if trackedTripID != nil || tracker.isRunning {
                tracker.flush()
                trackedTripID = nil
                tracker.stop()
                watchTask?.cancel()
                watchTask = Task { [tracker] in await tracker.unwatchAll() }
            }
            return
        }
        if trackedTripID != id {
            tracker.flush()
            trackedTripID = id
        }
        tracker.start()
        let places = TripLog.placesToWatch(on: today, plan: plan, skipped: skipped[id] ?? [], now: now).map {
            LocationTracker.Place(rowID: $0.rowID, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, radius: $0.radius)
        }
        watchTask?.cancel()
        watchTask = Task { [tracker] in await tracker.watch(places) }
    }

    private func recorded(_ points: [TrackPoint]) {
        guard credentials != nil, let id = trackedTripID, !points.isEmpty else { return }
        // Past midnight after the trip's last day (or the trip went away): stop, and keep nothing new.
        guard trips[id]?.plan.day(for: today) != nil else {
            updateTracking()
            return
        }
        if trackPoints[id] != nil { trackPoints[id]?.append(contentsOf: points) }
        let store = tracks
        queueWrite { try? await store.append(points, tripID: id) }
    }

    private func recorded(_ event: PlaceEvent) {
        guard credentials != nil, let id = trackedTripID else { return }
        if placeEvents[id] != nil { placeEvents[id]?.append(event) }
        let store = tracks
        queueWrite { try? await store.append(event, tripID: id) }
    }

    /// Reads a trip's recorded route from disk, once a session.
    ///
    /// The cache starts empty at once, so points recorded from here on collect in it; the read is
    /// queued behind the writes already waiting, so it sees exactly the points recorded before.
    func loadTrack(tripID: String) async {
        guard trackPoints[tripID] == nil else { return }
        let started = session
        trackPoints[tripID] = []
        placeEvents[tripID] = []
        let store = tracks
        let (points, events) = await withCheckedContinuation { (continuation: CheckedContinuation<([TrackPoint], [PlaceEvent]), Never>) in
            queueWrite {
                let points = await store.points(tripID: tripID)
                let events = await store.events(tripID: tripID)
                continuation.resume(returning: (points, events))
            }
        }
        guard session == started, credentials != nil else { return }
        trackPoints[tripID] = points + (trackPoints[tripID] ?? [])
        placeEvents[tripID] = events + (placeEvents[tripID] ?? [])
    }

    /// What happened on one day of a trip, against its plan.
    func dayLog(tripID: String, date: CalendarDate) -> DayLog? {
        guard let plan = trips[tripID]?.plan else { return nil }
        var points = trackPoints[tripID] ?? []
        if tripID == trackedTripID { points += tracker.buffered }
        return TripLog.day(date, plan: plan, points: points, events: placeEvents[tripID] ?? [],
                           skipped: skipped[tripID] ?? [], now: now)
    }

    /// The trip's route as a GPX file, one segment per day, with unplanned stops as waypoints.
    func gpxFile(tripID: String, days: [CalendarDate]) throws -> URL {
        guard let plan = trips[tripID]?.plan else { throw CocoaError(.fileNoSuchFile) }
        let logs = days.compactMap { dayLog(tripID: tripID, date: $0) }
        let waypoints = logs.flatMap(\.rows).compactMap { row -> GPX.Waypoint? in
            guard let point = row.coordinate, row.actualStart != nil else { return nil }
            return GPX.Waypoint(name: row.title, latitude: point.latitude, longitude: point.longitude, time: row.actualStart)
        }
        let text = GPX.document(name: plan.collection.name, segments: logs.map(\.points).filter { !$0.isEmpty }, waypoints: waypoints)
        let name = days.count == 1 ? "\(plan.collection.name) \(days[0].description).gpx" : "\(plan.collection.name).gpx"
        let safe = String(name.unicodeScalars.map { CharacterSet(charactersIn: "/:\\").contains($0) ? "-" : Character($0) })
        let folder = FileManager.default.temporaryDirectory.appending(path: "GPX")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: safe)
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
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
        Task {
            await refreshOpenTrip()
            await refreshReminderPermission()
            await updateReminders()
        }
        tracker.refreshAuthorization()
        updateTracking()
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
        trackingAllowed = state.trackingAllowed
        trackingDeclined = state.trackingDeclined
        for id in savedTrips.keys { show(id) }
    }

    private func saveDeviceState() {
        let state = DeviceStateStore.State(outbox: outbox, skipped: skipped,
                                           trackingAllowed: trackingAllowed, trackingDeclined: trackingDeclined)
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
