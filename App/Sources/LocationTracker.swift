// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import CoreLocation
import Foundation
import Observation

/// Records the route on trip days the person agreed to, and watches the next planned stops with
/// geofences. Everything it sees goes to `AppModel`, which keeps it on the phone.
///
/// Uses iOS 17's live updates with a background activity session, so "While Using" permission is
/// enough and iOS shows the location indicator while it runs.
@MainActor
@Observable
final class LocationTracker {
    private(set) var isRunning = false
    private(set) var authorization: CLAuthorizationStatus

    /// New points, a batch at a time.
    @ObservationIgnored var onPoints: (([TrackPoint]) -> Void)?
    /// Arriving at or leaving a watched stop.
    @ObservationIgnored var onEvent: ((PlaceEvent) -> Void)?

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var updates: Task<Void, Never>?
    @ObservationIgnored private var currentRun: UUID?
    @ObservationIgnored private var session: CLServiceSession?
    @ObservationIgnored private var background: CLBackgroundActivitySession?
    @ObservationIgnored private var monitor: CLMonitor?
    @ObservationIgnored private var monitorEvents: Task<Void, Never>?
    @ObservationIgnored private var watched: Set<String> = []
    @ObservationIgnored private var buffer: [TrackPoint] = []
    @ObservationIgnored private var lastKept: TrackPoint?
    @ObservationIgnored private var lastFlush = Date.distantPast

    /// Keep a point when the phone moved this far, or this long passed.
    static let minimumMove: Double = 25
    static let minimumInterval: TimeInterval = 60
    /// Points less accurate than this are noise.
    static let maximumAccuracy: Double = 100

    init() {
        authorization = manager.authorizationStatus
    }

    func refreshAuthorization() {
        authorization = manager.authorizationStatus
    }

    /// Starts recording; asks for permission the first time.
    func start() {
        guard updates == nil else { return }
        isRunning = true
        session = CLServiceSession(authorization: .whenInUse)
        background = CLBackgroundActivitySession()
        let run = UUID()
        currentRun = run
        updates = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    guard let self, !Task.isCancelled else { return }
                    self.refreshAuthorization()
                    if let location = update.location { self.record(location) }
                }
            } catch {}
            // The stream ended by itself: let the next `start` begin again.
            guard let self, self.currentRun == run else { return }
            self.stop()
        }
    }

    func stop() {
        currentRun = nil
        updates?.cancel()
        updates = nil
        background?.invalidate()
        background = nil
        session?.invalidate()
        session = nil
        isRunning = false
        flush()
    }

    /// Points kept but not yet handed over.
    var buffered: [TrackPoint] { buffer }

    /// Writes out what's buffered.
    func flush() {
        guard !buffer.isEmpty else { return }
        // Empty the buffer before handing it over, so a handler that stops tracking can't re-send it.
        let points = buffer
        buffer = []
        lastFlush = .now
        onPoints?(points)
    }

    private func record(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= Self.maximumAccuracy else { return }
        let point = TrackPoint(time: location.timestamp, latitude: location.coordinate.latitude,
                               longitude: location.coordinate.longitude, accuracy: location.horizontalAccuracy,
                               speed: location.speed >= 0 ? location.speed : nil)
        if let last = lastKept {
            let moved = location.distance(from: CLLocation(latitude: last.latitude, longitude: last.longitude))
            guard moved >= Self.minimumMove || point.time.timeIntervalSince(last.time) >= Self.minimumInterval else { return }
        }
        lastKept = point
        buffer.append(point)
        if buffer.count >= 20 || Date.now.timeIntervalSince(lastFlush) > 120 { flush() }
    }

    // MARK: Geofences

    /// A planned stop to watch.
    struct Place: Hashable {
        let rowID: String
        let latitude: Double
        let longitude: Double
        let radius: Double
    }

    /// Watches exactly these places (iOS allows 20 per app; the caller sends the next few).
    func watch(_ places: [Place]) async {
        let monitor = await ensureMonitor()
        let wanted = Dictionary(places.map { ($0.rowID, $0) }, uniquingKeysWith: { first, _ in first })
        for id in watched where wanted[id] == nil {
            await monitor.remove(id)
        }
        for (id, place) in wanted where !watched.contains(id) {
            let condition = CLMonitor.CircularGeographicCondition(
                center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude), radius: place.radius)
            await monitor.add(condition, identifier: id, assuming: .unsatisfied)
        }
        watched = Set(wanted.keys)
    }

    /// Stops watching everything, including places a previous launch left registered.
    func unwatchAll() async {
        let monitor = await ensureMonitor()
        for id in watched { await monitor.remove(id) }
        watched = []
    }

    /// The monitor, created once. Its conditions outlive the app, so start from what it holds.
    private func ensureMonitor() async -> CLMonitor {
        if let monitor { return monitor }
        let created = await CLMonitor("AdventureLog stops")
        if let monitor { return monitor } // another call won the race while this one waited
        monitor = created
        watched = Set(await created.identifiers)
        monitorEvents = Task { [weak self] in
            do {
                for try await event in await created.events {
                    guard let self else { return }
                    switch event.state {
                    case .satisfied: self.onEvent?(PlaceEvent(rowID: event.identifier, kind: .arrived, time: event.date))
                    case .unsatisfied: self.onEvent?(PlaceEvent(rowID: event.identifier, kind: .left, time: event.date))
                    default: break
                    }
                }
            } catch {}
        }
        return created
    }
}
