// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation
import Testing
@testable import ALStore

@Suite("Offline storage recovery and replacement")
struct StorageEdgeCaseTests {
    private let directory = FileManager.default.temporaryDirectory.appending(path: "al-storage-tests-\(UUID().uuidString)")

    private func fixtureTrip() throws -> CollectionDetail {
        let data = try Data(contentsOf: ALStoreTests.fixtures.appending(path: "collections__detail.json"))
        return try ALCoding.decoder().decode(CollectionDetail.self, from: data)
    }

    @Test func missingSnapshotsAndRepeatedRemovalAreHarmless() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripSnapshotStore(directory: directory)
        let trip = await store.trip(id: "absent")
        let list = await store.tripList()
        #expect(trip == nil)
        #expect(list == nil)
        try await store.removeAll()
        try await store.removeAll()
        #expect(!FileManager.default.fileExists(atPath: directory.path()))
    }

    @Test func snapshotsSurviveNewStoreInstancesAndReplaceOnlyTheirOwnID() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripSnapshotStore(directory: directory)
        var first = try fixtureTrip()
        first.id = "first"
        var second = first
        second.id = "second"
        second.name = "Other trip"
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.saveTrip(first, at: savedAt)
        try await store.saveTrip(second, at: savedAt)
        first.name = "Updated trip"
        first.itinerary = []
        try await store.saveTrip(first, at: savedAt.addingTimeInterval(60))

        let reopened = TripSnapshotStore(directory: directory)
        let firstSnapshot = await reopened.trip(id: "first")
        let secondSnapshot = await reopened.trip(id: "second")
        let updated = try #require(firstSnapshot)
        let unchanged = try #require(secondSnapshot)
        #expect(updated.value.name == "Updated trip")
        #expect(updated.value.itinerary.isEmpty)
        #expect(updated.savedAt == savedAt.addingTimeInterval(60))
        #expect(unchanged.value.name == "Other trip")
        #expect(unchanged.value.itinerary.map(\.id) == second.itinerary.map(\.id))
        #expect(unchanged.savedAt == savedAt)
    }

    @Test func tripListPreservesOwnedSharedAndTimestampThenReplacesThem() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripSnapshotStore(directory: directory)
        let ownedData = try Data(contentsOf: ALStoreTests.fixtures.appending(path: "collections__all.json"))
        let sharedData = try Data(contentsOf: ALStoreTests.fixtures.appending(path: "collections__shared__as_guest.json"))
        let owned = try ALCoding.decoder().decode([CollectionSummary].self, from: ownedData)
        let shared = try ALCoding.decoder().decode([CollectionSummary].self, from: sharedData)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.saveTripList(.init(owned: owned, shared: shared, savedAt: savedAt))
        let reopened = TripSnapshotStore(directory: directory)
        let snapshot = await reopened.tripList()
        let list = try #require(snapshot)
        #expect(list.owned.map(\.id) == owned.map(\.id))
        #expect(list.shared.map(\.id) == shared.map(\.id))
        #expect(list.owned.map(\.name) == owned.map(\.name))
        #expect(list.shared.map(\.name) == shared.map(\.name))
        #expect(list.savedAt == savedAt)

        let replacement = TripSnapshotStore.TripList(owned: [], shared: [], savedAt: savedAt.addingTimeInterval(60))
        try await store.saveTripList(replacement)
        let replaced = await reopened.tripList()
        #expect(replaced == replacement)
    }

    @Test(arguments: ["not json", "{}", #"{"value":{},"saved_at":"not-a-date"}"#])
    func corruptSnapshotsAreCacheMissesAndCanBeReplaced(_ body: String) async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(body.utf8).write(to: directory.appending(path: "trip-broken.json"))
        try Data(body.utf8).write(to: directory.appending(path: "trip-list.json"))
        let store = TripSnapshotStore(directory: directory)
        let corruptTrip = await store.trip(id: "broken")
        let corruptList = await store.tripList()
        #expect(corruptTrip == nil)
        #expect(corruptList == nil)

        var trip = try fixtureTrip()
        trip.id = "broken"
        try await store.saveTrip(trip)
        try await store.saveTripList(.init(owned: [], shared: [], savedAt: Date(timeIntervalSince1970: 0)))
        let repairedTrip = await store.trip(id: "broken")
        let repairedList = await store.tripList()
        #expect(repairedTrip?.value.id == "broken")
        #expect(repairedList?.savedAt == Date(timeIntervalSince1970: 0))
    }

    @Test func removalClearsListsAndTripsAndAllowsSavingAgain() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TripSnapshotStore(directory: directory)
        let trip = try fixtureTrip()
        try await store.saveTrip(trip)
        try await store.saveTripList(.init(owned: [], shared: [], savedAt: .now))
        try await store.removeAll()
        let removedTrip = await store.trip(id: trip.id)
        let removedList = await store.tripList()
        #expect(removedTrip == nil)
        #expect(removedList == nil)
        try await store.saveTrip(trip)
        let restored = await store.trip(id: trip.id)
        #expect(restored?.value.id == trip.id)
    }

    @Test func writeFailuresAreReportedToTheCaller() async throws {
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file at the directory path fails deterministically, even with elevated permissions.
        try Data("occupied".utf8).write(to: directory)
        let store = TripSnapshotStore(directory: directory)
        let trip = try fixtureTrip()
        do {
            try await store.saveTrip(trip)
            Issue.record("Expected saveTrip to report a filesystem error")
        } catch {
            #expect((error as NSError).domain == NSCocoaErrorDomain)
        }
        do {
            try await store.saveTripList(.init(owned: [], shared: [], savedAt: .now))
            Issue.record("Expected saveTripList to report a filesystem error")
        } catch {
            #expect((error as NSError).domain == NSCocoaErrorDomain)
        }
    }

    @Test func credentialReplacementAndClearDoNotAffectAnotherStore() throws {
        let first = ServerCredentials(serverURL: URL(string: "https://first.example")!, apiKey: "al_first", username: "first", displayName: "First User")
        let second = ServerCredentials(serverURL: URL(string: "https://second.example")!, apiKey: "al_second")
        let store = InMemoryCredentialStore(first)
        let independent = InMemoryCredentialStore(first)
        let initial = try store.load()
        #expect(initial == first)
        try store.save(second)
        let replaced = try store.load()
        #expect(replaced == second)
        try store.clear()
        try store.clear()
        let cleared = try store.load()
        let untouched = try independent.load()
        #expect(cleared == nil)
        #expect(untouched == first)
    }

    @Test func credentialsRoundTripWithAndWithoutOptionalProfile() throws {
        let minimal = ServerCredentials(serverURL: URL(string: "https://example.com/adventurelog")!, apiKey: "al_test")
        var profile = minimal
        profile.username = "traveller"
        profile.displayName = "旅人"
        for credentials in [minimal, profile] {
            let data = try JSONEncoder().encode(credentials)
            let restored = try JSONDecoder().decode(ServerCredentials.self, from: data)
            #expect(restored == credentials)
        }
    }
}
