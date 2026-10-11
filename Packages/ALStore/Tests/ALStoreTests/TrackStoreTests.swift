// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation
import Testing
@testable import ALStore

@Suite("Track store")
struct TrackStoreTests {
    @Test func appendsAndReadsBackPerTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "al-tracks-\(UUID().uuidString)")
        let store = TrackStore(directory: directory)
        let t0 = Date(timeIntervalSince1970: 1_900_000_000)
        try await store.append([TrackPoint(time: t0, latitude: -42.88, longitude: 147.33)], tripID: "a")
        try await store.append([TrackPoint(time: t0.addingTimeInterval(30), latitude: -42.87, longitude: 147.34),
                                TrackPoint(time: t0.addingTimeInterval(60), latitude: -42.86, longitude: 147.35)], tripID: "a")
        try await store.append(PlaceEvent(rowID: "r", kind: .arrived, time: t0), tripID: "a")
        try await store.append([TrackPoint(time: t0, latitude: 1, longitude: 1)], tripID: "b")

        #expect(await store.points(tripID: "a").count == 3)
        #expect(await store.events(tripID: "a") == [PlaceEvent(rowID: "r", kind: .arrived, time: t0)])
        #expect(await store.points(tripID: "b").count == 1)

        // A write cut short leaves a partial last line; the rest still reads.
        let handle = try FileHandle(forWritingTo: directory.appending(path: "track-a.jsonl"))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"time":1900000090,"lat"#.utf8))
        try handle.close()
        #expect(await store.points(tripID: "a").count == 3)
        // The next write starts on a new line, so it isn't lost to the fragment.
        try await store.append([TrackPoint(time: t0.addingTimeInterval(120), latitude: -42.85, longitude: 147.36)], tripID: "a")
        #expect(await store.points(tripID: "a").count == 4)

        try await store.remove(tripID: "a")
        #expect(await store.points(tripID: "a").isEmpty)
        #expect(await store.points(tripID: "b").count == 1)
        try await store.removeAll()
        #expect(await store.points(tripID: "b").isEmpty)
    }

    @Test func olderDeviceStateWithoutTrackingFieldsStillDecodes() throws {
        let old = #"{"outbox":{"entries":[],"notices":[]},"skipped":{"t":["r"]}}"#
        let state = try JSONDecoder().decode(DeviceStateStore.State.self, from: Data(old.utf8))
        #expect(state.skipped == ["t": ["r"]])
        #expect(state.trackingAllowed.isEmpty && state.trackingDeclined.isEmpty)
    }
}
