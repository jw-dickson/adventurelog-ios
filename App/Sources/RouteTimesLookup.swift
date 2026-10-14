// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation
import MapKit

/// Asks for one leg's drive time by road. Apple Maps on the phone; a stand-in in tests.
protocol RouteLookup: Sendable {
    /// Seconds by car setting off at the leg's departure, or `nil` when there's no road route.
    /// - Throws: `RouteLookupError`.
    func seconds(for leg: RouteTimes.Leg, now: Date) async throws -> TimeInterval?
}

enum RouteLookupError: Error {
    /// Apple Maps asked the app to slow down.
    case throttled
    /// Offline, or anything else: try again later.
    case unavailable
}

/// `MKDirections.calculateETA`: only the travel time, no route drawn and no navigation.
struct MapKitRouteLookup: RouteLookup {
    func seconds(for leg: RouteTimes.Leg, now: Date) async throws -> TimeInterval? {
        let request = MKDirections.Request()
        request.source = Self.item(leg.from)
        request.destination = Self.item(leg.to)
        request.transportType = .automobile
        // Traffic as expected when it's planned to set off; a leg under way asks for now.
        request.departureDate = max(leg.departure, now)
        let directions = MKDirections(request: request)
        // The completion-handler form, so only Sendable values cross back.
        let outcome: Outcome = await withCheckedContinuation { continuation in
            directions.calculateETA { response, error in
                if let response {
                    continuation.resume(returning: .seconds(response.expectedTravelTime))
                } else if let error = error as? MKError {
                    switch error.code {
                    case .directionsNotFound: continuation.resume(returning: .noRoute)
                    case .loadingThrottled: continuation.resume(returning: .throttled)
                    default: continuation.resume(returning: .unavailable)
                    }
                } else {
                    continuation.resume(returning: .unavailable)
                }
            }
        }
        switch outcome {
        case .seconds(let seconds): return seconds
        case .noRoute: return nil
        case .throttled: throw RouteLookupError.throttled
        case .unavailable: throw RouteLookupError.unavailable
        }
    }

    private enum Outcome: Sendable {
        case seconds(TimeInterval)
        case noRoute
        case throttled
        case unavailable
    }

    private static func item(_ point: ItemSummary.Coordinate) -> MKMapItem {
        MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: point.latitude, longitude: point.longitude)))
    }
}

extension AppModel {
    /// At most this many lookups a run; the rest wait for the next one.
    static let routeLookupsPerRun = 25
    /// A pause between lookups, well inside Apple's limit.
    static let routeLookupGap: Duration = .milliseconds(400)
    /// After Apple Maps says to slow down.
    static let routeLookupBackoff: TimeInterval = 10 * 60

    /// Looks up drive times for the next two days' legs across every listed trip, soonest first,
    /// and keeps them for offline use. Skipped for the offline UI-test seed.
    func updateRouteTimes() async {
        guard credentials != nil, deviceStateLoaded, !lookingUpRoutes, !LaunchOptions.current.offlineSeed else { return }
        let started = now
        if let paused = routeLookupsPausedUntil, started < paused { return }
        let listed = Set((ownedTrips + sharedTrips).map(\.id))
        var seen: Set<RouteTimes.Key> = []
        let legs = trips.filter { listed.contains($0.key) }
            .flatMap { id, trip in routeTimes.legsToLookUp(in: trip.plan, now: started, skipped: skipped[id] ?? []) }
            .sorted { $0.departure < $1.departure }
            .filter { seen.insert($0.key).inserted }
            .prefix(Self.routeLookupsPerRun)
        routeTimes.prune(now: started)
        guard !legs.isEmpty else { return }

        lookingUpRoutes = true
        defer { lookingUpRoutes = false }
        let runSession = session
        let lookup = routeLookup
        var changed = false
        lookups: for (index, leg) in legs.enumerated() {
            if index > 0 { try? await Task.sleep(for: Self.routeLookupGap) }
            guard session == runSession, !Task.isCancelled else { return }
            do {
                let seconds = try await lookup.seconds(for: leg, now: now)
                guard session == runSession else { return }
                routeTimes.record(leg, seconds: seconds, at: now)
                changed = true
            } catch RouteLookupError.throttled {
                routeLookupsPausedUntil = now.addingTimeInterval(Self.routeLookupBackoff)
                break lookups
            } catch {
                // Offline or a one-off failure: the estimate stands, and the next run asks again.
                break lookups
            }
        }
        if changed, session == runSession { saveDeviceState() }
    }

    /// The drive time Today shows for a leg: looked up when known, else the estimate.
    func travel(from origin: ItemSummary.Coordinate, to destination: ItemSummary.Coordinate) -> RouteTimes.Travel {
        routeTimes.travel(from: origin, to: destination)
    }
}
