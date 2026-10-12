// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import ALStore
import BackgroundTasks
import CoreLocation
import Foundation
import Network
import Observation
import os
import UIKit
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
    /// The server answered for the trip list this session, so an empty list really is empty.
    private var tripListFromServer = false
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

    // Live Activities for flights and booked tours (Stage 4).
    private let liveActivities = LiveActivityController()
    /// The companion service's address (optional, Stage 4b): it starts, updates and ends Live
    /// Activities by push.
    var companionAddress: String {
        didSet {
            defaults.set(companionAddress, forKey: Keys.companionAddress)
            // A moment after the typing stops, not on every keystroke.
            companionTask?.cancel()
            companionTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                await self?.connectCompanion()
            }
        }
    }
    private var companionTask: Task<Void, Never>?
    /// The companion this phone last registered with, so a changed or cleared address (or
    /// sign-out) unregisters it rather than leaving it with the key.
    private var registeredCompanion: CompanionClient?
    /// "Connected", or why not; nil when no companion is set.
    private(set) var companionStatus: String?
    private var startToken: Data?
    /// The start token the companion last accepted. A token that failed to register differs from
    /// it, so the next callback or foregrounding tries again.
    private var registeredStartToken: Data?
    /// Activity push tokens the companion hasn't accepted yet (e.g. one that came before the phone
    /// was registered), by trip and item; sent again after each registration.
    private var pendingActivityTokens: [String: (token: Data, tripID: String, rowID: String)] = [:]
    /// On unless the person turns them off in Reminders; iOS has its own switch too.
    var liveActivitiesEnabled: Bool {
        didSet {
            defaults.set(!liveActivitiesEnabled, forKey: Keys.liveActivitiesOff)
            scheduleReminderUpdate()
        }
    }

    private enum Keys {
        static let liveActivitiesOff = "al.liveActivitiesOff"
        static let companionAddress = "al.companionAddress"
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
    /// Geofences outlive the app; the first pass after launch clears any it isn't using.
    private var geofencesChecked = false
    /// Re-checks at midnight, so recording stops after the trip's last day even if the phone sits still.
    private var midnightTask: Task<Void, Never>?
    /// The location permission the last tracking decision saw; a change (an answer to the prompt) decides again.
    private var trackingAuthorization: CLAuthorizationStatus?

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
        self.liveActivitiesEnabled = !defaults.bool(forKey: Keys.liveActivitiesOff)
        self.companionAddress = defaults.string(forKey: Keys.companionAddress) ?? ""
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
        tracker.onTick = { [weak self] in
            self?.checkTrackingDay()
            self?.considerReplanNotice()
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
        try? FileManager.default.removeItem(at: Self.gpxFolder)
        deviceStateLoaded = true
        let credentials = ServerCredentials(serverURL: url, apiKey: key, username: user.username,
                                            displayName: user.displayName, apiKeyID: apiKeyID)
        try credentialStore.save(credentials)
        self.client = client
        phase = .signedIn(credentials)
        startToken = nil
        registeredStartToken = nil
        Task { await connectCompanion() }
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
        // A key the app made at sign-in is revoked; one the person pasted stays theirs. The
        // companion is told first, while the key still works.
        let revoke = credentials?.apiKeyID.flatMap { id in client.map { (client: $0, id: id) } }
        let companion = registeredCompanion ?? self.companion
        registeredCompanion = nil
        registeredStartToken = nil
        pendingActivityTokens = [:]
        resetSession()
        client = nil
        lastError = nil
        phase = .signedOut
        if revoke != nil || companion != nil {
            // Best effort: offline, the key stays until it's revoked in AdventureLog's settings.
            Task.detached {
                try? await companion?.unregister()
                if let revoke { try? await revoke.client.deleteAPIKey(id: revoke.id) }
            }
        }
        await reminderScheduler.removeAll()
        await liveActivities.endAll()
        await tracker.unwatchAll() // runs after any geofence change already under way
        await drainWrites()
        try? await tracks.removeAll()
        try? FileManager.default.removeItem(at: Self.gpxFolder)
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
        midnightTask?.cancel()
        midnightTask = nil
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
        tripListFromServer = false
        trips = [:]
        savedTrips = [:]
        tripRevisions = [:]
        newestFetchShown = [:]
        outbox = Outbox()
        skipped = [:]
        selectedTripID = nil
        tripListSavedAt = nil
        replanRequest = nil
        replanNoticeKey = nil
        lastReplanNotice = nil
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
            tripListFromServer = true
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

    /// Saves edited fields of a place, journey or stay. `item` is the item as shown, so a second
    /// edit builds on the first.
    func editItem(_ item: TripPlan.Item, values: [ItemField: FieldValue], tripID: String) {
        guard let edit = TripEdit.EditItem(item: item, visitID: item.editableVisit?.id, values: values) else { return }
        perform(.editItem(edit), in: tripID)
    }

    /// Adds a timestamped line under an item's notes. The time is shown in the item's zone.
    func appendNote(_ text: String, to item: TripPlan.Item, zone: TimeZone, tripID: String) {
        guard let kind = TripEdit.EditItem.editableKind(item), FieldValue.clean(text) != nil else { return }
        let line = TripEdit.AppendNote.line(text, at: now, in: zone)
        perform(.appendNote(.init(kind: kind, itemID: item.id, visitID: item.editableVisit?.id, title: item.title, line: line)), in: tripID)
    }

    /// Adds a note at the end of a day, or trip-wide when `date` is nil.
    func addNote(name: String, content: String, date: CalendarDate?, tripID: String) {
        var add = TripEdit.AddNote(name: name, content: content, date: date)
        // Twins already shown, including notes still on their way, tell this note from older ones.
        add.occurrence = trips[tripID]?.plan.collection.notes.filter(add.isTwin).count ?? 0
        perform(.addNote(add), in: tripID)
    }

    /// Takes a row off its day. The item stays in the trip, under Not on a day.
    func removeFromDay(_ entry: TripPlan.Entry, tripID: String) {
        perform(.removeRow(.init(rowID: entry.row.id, title: entry.item.title, date: entry.row.date)), in: tripID)
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

    // MARK: Replan (Stage 5)

    /// Behind by this much while recording, Today suggests a replan (and a notification does, in the background).
    static let replanNudgeMinutes = 30
    /// A trip whose replan sheet should open, from the notification.
    var replanRequest: String?
    /// The stop the last replan notification was about, so each late stop notifies once.
    private var replanNoticeKey: String?
    private var lastReplanNotice: Date?
    private var lastReplanCheck = Date.distantPast

    /// The rest of today for a replan: from the last recorded position when recording, else from
    /// how late the person says they are.
    func replanSituation(tripID: String, reportedDelay: Int? = nil) -> Replan.Situation? {
        guard let plan = trips[tripID]?.plan else { return nil }
        let recording = tripID == trackedTripID
        let log = recording ? dayLog(tripID: tripID, date: today) : nil
        let last = recording ? (tracker.buffered.last ?? trackPoints[tripID]?.last) : nil
        return .current(plan: plan, today: today, now: now, skipped: skipped[tripID] ?? [], log: log,
                        lastPoint: last, reportedDelay: reportedDelay)
    }

    func tripDays(_ tripID: String) -> Set<CalendarDate> {
        Set(trips[tripID]?.plan.days.map(\.date) ?? [])
    }

    /// Minutes behind, while recording, when it's worth suggesting a replan.
    func replanNudge(tripID: String) -> Int? {
        guard tripID == trackedTripID, tracker.isRunning, let situation = replanSituation(tripID: tripID),
              situation.position != nil, situation.delayMinutes >= Self.replanNudgeMinutes,
              ReplanPlanner.propose(situation).changesSomething
        else { return nil }
        return situation.delayMinutes
    }

    /// Saves a proposal's changes as ordinary edits: new times, moves to another day, skips and notes.
    func applyReplan(_ proposal: Replan.Proposal, tripID: String) {
        guard let plan = trips[tripID]?.plan else { return }
        for action in ReplanApply.actions(for: proposal, plan: plan, today: today) {
            switch action {
            case .retime(let item, let start, let end):
                editItem(item, values: [.start: .time(start), .end: .time(end)], tripID: tripID)
            case .move(let entry, let item, let date, let index, let start, let end):
                editItem(item, values: [.start: .time(start), .end: .time(end)], tripID: tripID)
                move(entry, to: date, at: index, tripID: tripID)
            case .skip(let rowID):
                setSkipped(true, rowID: rowID, tripID: tripID)
            case .addNote(let title, let content, let date):
                addNote(name: title, content: content, date: date, tripID: tripID)
            }
        }
    }

    /// While recording in the background: once per late stop, at most every 90 minutes, a
    /// notification that opens the replan. Checked at most once a minute.
    private func considerReplanNotice() {
        guard let id = trackedTripID, now.timeIntervalSince(lastReplanCheck) >= 60 else { return }
        lastReplanCheck = now
        guard [.authorized, .provisional].contains(reminderPermission),
              UIApplication.shared.applicationState != .active,
              let situation = replanSituation(tripID: id), situation.position != nil,
              situation.delayMinutes >= Self.replanNudgeMinutes, let target = situation.stops.first,
              ReplanPlanner.propose(situation).changesSomething
        else { return }
        let key = id + "/" + target.rowID
        guard key != replanNoticeKey else { return }
        if let last = lastReplanNotice, now.timeIntervalSince(last) < 90 * 60 { return }
        replanNoticeKey = key
        lastReplanNotice = now
        let behind = situation.delayMinutes
        Task { await reminderScheduler.notifyReplan(tripID: id, behindMinutes: behind, nextTitle: target.title) }
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
        guard credentials != nil else { return }
        reminderTask?.cancel()
        let started = session
        reminderTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.session == started else { return }
            await self.updateReminders()
            await self.updateLiveActivities()
        }
    }

    /// Shows the flight or booked tour whose Live Activity window is open now, across listed trips.
    func updateLiveActivities() async {
        guard credentials != nil, liveActivitiesEnabled else {
            await liveActivities.endAll()
            return
        }
        let listed = Set((ownedTrips + sharedTrips).map(\.id))
        let current = trips.filter { listed.contains($0.key) }
            .compactMap { LiveActivityPlanner.current(for: $0.value.plan, now: now, skipped: skipped[$0.key] ?? []) }
            .min { $0.end < $1.end }
        var onToken: LiveActivityController.TokenHandler?
        if companion != nil {
            onToken = { [weak self] token, tripID, rowID in
                await self?.receivedActivityToken(token, tripID: tripID, rowID: rowID)
            }
        }
        await liveActivities.show(current, onToken: onToken)
    }

    // MARK: Companion service

    /// The companion, when an HTTPS address is set and someone is signed in. Every request carries
    /// the AdventureLog API key, so plain http is never used.
    var companion: CompanionClient? {
        guard let credentials, let url = AdventureLogClient.normalizedServerURL(companionAddress),
              url.scheme?.lowercased() == "https" else { return nil }
        return CompanionClient(baseURL: url, apiKey: credentials.apiKey)
    }

    /// Builds from Xcode get pushes through Apple's sandbox; TestFlight and the App Store don't.
    nonisolated static var pushEnvironment: CompanionClient.Environment {
        #if DEBUG
        .sandbox
        #else
        .production
        #endif
    }

    /// Registers this phone (again) with the companion, with the push-to-start token once iOS gives one.
    func connectCompanion() async {
        if startToken == nil, let current = liveActivities.startToken { startToken = current }
        let companion = self.companion
        // A different (or no) address: the old companion stops pushing and drops the key.
        if let previous = registeredCompanion, previous.baseURL != companion?.baseURL {
            registeredCompanion = nil
            registeredStartToken = nil
            try? await previous.unregister()
        }
        guard let companion else {
            let address = companionAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            companionStatus = address.isEmpty || credentials == nil ? nil : "Use an https:// address."
            return
        }
        let started = session
        do {
            let sending = startToken
            let sentToken = sending != nil
            let canStart = try await companion.register(environment: Self.pushEnvironment, startToken: sending)
            Self.companionLog.info("Registered with the companion; start token sent: \(sentToken, privacy: .public), companion can start: \(String(describing: canStart), privacy: .public)")
            // The address changed (or sign-out happened) while this was in flight: undo it, so a
            // slower, older registration can't replace the current one.
            guard session == started, self.companion?.baseURL == companion.baseURL else {
                try? await companion.unregister()
                return
            }
            registeredCompanion = companion
            if let sending { registeredStartToken = sending }
            // An older companion doesn't say; a newer one says whether it can start activities.
            companionStatus = canStart == false ? "Connected · activities start when you open the app" : "Connected"
            await sendPendingActivityTokens()
            // A newer token arrived while this was in flight (or this older request finished last):
            // register again so the companion ends up with the newest one.
            if let latest = startToken, latest != sending { await connectCompanion() }
        } catch {
            guard session == started else { return }
            companionStatus = Self.describe(error)
        }
    }

    /// For the signed-in session: passes the push tokens iOS hands out to the companion.
    func watchLiveActivityTokens() async {
        await liveActivities.watchTokens(onStartToken: { [weak self] token in
            await self?.receivedStartToken(token)
        }, onToken: { [weak self] token, tripID, rowID in
            await self?.receivedActivityToken(token, tripID: tripID, rowID: rowID)
        })
    }

    private func receivedStartToken(_ token: Data) async {
        Self.companionLog.info("iOS issued a push-to-start token (\(token.count, privacy: .public) bytes)")
        guard token != registeredStartToken || registeredCompanion == nil else { return }
        startToken = token
        await connectCompanion()
    }

    /// Lets iOS issue Live Activity push tokens: some versions only issue a push-to-start token once
    /// the app has registered for remote notifications (#24). The device token itself isn't used.
    func registerForPushes() {
        guard liveActivitiesEnabled else { return }
        UIApplication.shared.registerForRemoteNotifications()
    }

    /// Private to the device's log (Console.app), so a test run shows which side drops a token.
    nonisolated static let companionLog = Logger(subsystem: "AdventureLog", category: "companion")

    private func receivedActivityToken(_ token: Data, tripID: String, rowID: String) async {
        pendingActivityTokens[tripID + "/" + rowID] = (token, tripID, rowID)
        await sendPendingActivityTokens()
    }

    /// Hands the companion every token it hasn't accepted yet; a failure keeps it for next time.
    private func sendPendingActivityTokens() async {
        guard let companion else { return }
        for (key, pending) in pendingActivityTokens {
            do {
                try await companion.setActivityToken(pending.token, tripID: pending.tripID, rowID: pending.rowID)
                // Only if a newer token for the same activity didn't arrive meanwhile.
                if pendingActivityTokens[key]?.token == pending.token { pendingActivityTokens[key] = nil }
            } catch {
                continue
            }
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
        // An empty list counts only when the server sent it: after deleting the last trip its
        // reminders go, but a launch with nothing loaded yet keeps them.
        let complete = (tripListFromServer || !listed.isEmpty) && needed.allSatisfy { trips[$0] != nil }
        await reminderScheduler.replace(with: Array(all.prefix(ReminderPlanner.limit)), removeStale: complete)
    }

    /// The background refresh: fetch what changed, send waiting edits, roll the reminder window on.
    func backgroundRefresh() async {
        Self.scheduleBackgroundRefresh()
        guard credentials != nil else { return }
        await loadTrips()
        await updateReminders()
        await updateLiveActivities()
    }

    /// Asks iOS for the next background refresh, a few hours out.
    nonisolated static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 3 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    // MARK: Tracking (this phone only)

    /// The agreed-to trip with a day today, preferring the one on screen.
    var trackableTripToday: String? {
        let listed = Set((ownedTrips + sharedTrips).map(\.id))
        let candidates = trips.filter {
            listed.contains($0.key) && trackingAllowed.contains($0.key) && $0.value.plan.day(for: today) != nil
        }.map(\.key)
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
        trackingAuthorization = tracker.authorization
        guard credentials != nil, let id = trackableTripToday,
              let plan = trips[id]?.plan, tracker.authorization != .denied, tracker.authorization != .restricted
        else {
            if trackedTripID != nil || tracker.isRunning || !geofencesChecked {
                geofencesChecked = true
                tracker.flush()
                trackedTripID = nil
                tracker.stop()
                midnightTask?.cancel()
                midnightTask = nil
                watchTask = Task { [tracker] in await tracker.unwatchAll() }
            }
            return
        }
        geofencesChecked = true
        scheduleMidnightCheck()
        if trackedTripID != id {
            tracker.flush()
            trackedTripID = id
        }
        tracker.start()
        let places = TripLog.placesToWatch(on: today, plan: plan, skipped: skipped[id] ?? [], now: now).map {
            LocationTracker.Place(rowID: $0.rowID, latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude, radius: $0.radius)
        }
        watchTask = Task { [tracker] in await tracker.watch(places) }
    }

    /// Stops when the trip being recorded has no day today any more.
    private func checkTrackingDay() {
        guard let id = trackedTripID else { return }
        if trips[id]?.plan.day(for: today) == nil || tracker.authorization != trackingAuthorization { updateTracking() }
    }

    private func scheduleMidnightCheck() {
        guard midnightTask == nil else { return }
        let zone = TimeZone.autoupdatingCurrent
        let midnight = CalendarDate(Date.now, in: zone).adding(days: 1).startOfDay(in: zone)
        midnightTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(midnight.timeIntervalSinceNow, 1) + 5))
            guard !Task.isCancelled, let self else { return }
            self.midnightTask = nil
            self.updateTracking()
        }
    }

    private func recorded(_ points: [TrackPoint]) {
        guard credentials != nil, let id = trackedTripID, !points.isEmpty, let plan = trips[id]?.plan else { return }
        // Only points on the trip's days are kept: a batch handed over just after midnight on the
        // last day keeps its points from before midnight and drops the rest.
        let points = points.filter { plan.day(for: CalendarDate($0.time, in: plan.timeZone)) != nil }
        defer { checkTrackingDay() }
        guard !points.isEmpty else { return }
        if trackPoints[id] != nil { trackPoints[id]?.append(contentsOf: points) }
        let store = tracks
        queueWrite { try? await store.append(points, tripID: id) }
    }

    private func recorded(_ event: PlaceEvent) {
        // Like points: only events on the trip's days are kept.
        guard credentials != nil, let id = trackedTripID, let plan = trips[id]?.plan,
              plan.day(for: CalendarDate(event.time, in: plan.timeZone)) != nil else { return }
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
        let folder = Self.gpxFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: safe)
        #if os(iOS)
        try Data(text.utf8).write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try Data(text.utf8).write(to: url, options: .atomic)
        #endif
        return url
    }

    /// Where shared GPX files are written; emptied with the rest of the account's data.
    static var gpxFolder: URL { FileManager.default.temporaryDirectory.appending(path: "GPX") }

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

    /// Drops this phone's edit. For a conflicting note or field, shows the server's version straight away.
    func discard(_ id: UUID) {
        if let entry = outbox.entries.first(where: { $0.id == id }), case .fieldConflict(let conflict) = entry.state,
           case .editItem(let edit) = entry.edit, var saved = savedTrips[entry.tripID] {
            ItemValues.write(conflict.clashes.map { ($0.field, $0.server) }, kind: edit.kind, itemID: edit.itemID,
                             visitID: edit.visitID, in: &saved.value)
            savedTrips[entry.tripID] = saved
            let tripID = entry.tripID
            Task { await loadTrip(id: tripID) }
        }
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
            outbox.markSending(entry.id)
            let outcome = await sender.send(entry.edit, tripID: entry.tripID)
            guard session == started, isCurrent(client) else { return }
            outbox.record(outcome, for: entry.id, sent: entry.edit, at: .now)
            if outcome == .done { settle(entry.edit, in: entry.tripID) }
            if case .added(let noteID, let rowID) = outcome, case .addNote(let add) = entry.edit {
                settle(add, noteID: noteID, rowID: rowID, in: entry.tripID)
            }
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
        keepSaved(saved, for: tripID)
    }

    /// A note made on the phone is on the server: the saved copy gets it under the server's ids,
    /// which edits queued for it now use.
    private func settle(_ add: TripEdit.AddNote, noteID: String, rowID: String, in tripID: String) {
        guard var saved = savedTrips[tripID] else { return }
        add.apply(to: &saved.value, noteID: noteID, rowID: rowID)
        keepSaved(saved, for: tripID)
    }

    private func keepSaved(_ saved: TripSnapshotStore.Snapshot<CollectionDetail>, for tripID: String) {
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
        if let current = liveActivities.startToken, current != registeredStartToken {
            Task { await receivedStartToken(current) }
        }
        Task {
            await refreshOpenTrip()
            await refreshReminderPermission()
            await updateReminders()
            await updateLiveActivities()
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
