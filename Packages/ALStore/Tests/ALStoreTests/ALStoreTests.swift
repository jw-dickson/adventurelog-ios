// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation
import Testing
@testable import ALStore

@Suite("Local storage")
struct ALStoreTests {
    static let fixtures: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appending(path: "Fixtures").appending(path: "adventurelog-v0.13.0").appending(path: "responses")
    }()

    @Test func inMemoryCredentialsRoundTrip() throws {
        let store = InMemoryCredentialStore()
        let empty = try store.load()
        #expect(empty == nil)
        let credentials = ServerCredentials(serverURL: URL(string: "https://adventurelog.example")!, apiKey: "al_x", username: "admin")
        try store.save(credentials)
        let saved = try store.load()
        #expect(saved == credentials)
        try store.clear()
        let cleared = try store.load()
        #expect(cleared == nil)
    }

    @Test func tripSnapshotsRoundTripAsAdventureLogJSON() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "al-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripSnapshotStore(directory: directory)

        let data = try Data(contentsOf: Self.fixtures.appending(path: "collections__detail.json"))
        let trip = try ALCoding.decoder().decode(CollectionDetail.self, from: data)
        try await store.saveTrip(trip)

        let snapshot = await store.trip(id: trip.id)
        let loaded = try #require(snapshot)
        // Timestamps are written at whole-second precision, so compare content rather than ==.
        #expect(loaded.value.id == trip.id)
        #expect(loaded.value.name == trip.name)
        #expect(loaded.value.itinerary.map(\.id) == trip.itinerary.map(\.id))
        #expect(loaded.value.locations.map(\.visits.count) == trip.locations.map(\.visits.count))
        #expect(TripPlan(loaded.value, fallbackTimeZone: .gmt).days.count == 19)

        try await store.saveTripList(.init(owned: [], shared: [], savedAt: .now))
        let list = await store.tripList()
        #expect(list != nil)

        try await store.removeAll()
        let gone = await store.trip(id: trip.id)
        #expect(gone == nil)
    }
}
