// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation
import Testing
@testable import ALStore

/// Counts downloads so tests can see what came from disk.
private actor Downloads {
    var count = 0
    func record() { count += 1 }
}

private struct Offline: Error {}

@Suite("Offline images")
struct ImageStoreTests {
    func makeStore() -> ImageStore {
        ImageStore(directory: FileManager.default.temporaryDirectory.appending(path: "al-images-\(UUID().uuidString)"))
    }

    @Test func downloadsOnceThenServesFromDisk() async throws {
        let store = makeStore()
        let downloads = Downloads()
        let url = try #require(URL(string: "https://adventurelog.example/media/a.jpg"))
        let fetch: ImageStore.Fetch = { _ in
            await downloads.record()
            return Data("jpeg".utf8)
        }
        let first = try await store.data(for: url, fetch: fetch)
        let second = try await store.data(for: url, fetch: { _ in throw Offline() })
        #expect(first == second)
        #expect(await downloads.count == 1)
        #expect(await store.cachedData(for: url) == Data("jpeg".utf8))
    }

    @Test func prefetchSkipsFailuresAndCountsWhatItAdded() async throws {
        let store = makeStore()
        let good = try #require(URL(string: "https://adventurelog.example/media/good.jpg"))
        let bad = try #require(URL(string: "https://adventurelog.example/media/bad.jpg"))
        let added = await store.prefetch([good, bad]) { url in
            if url == bad { throw Offline() }
            return Data("ok".utf8)
        }
        #expect(added == 1)
        let again = await store.prefetch([good]) { _ in Data("new".utf8) }
        #expect(again == 0)
        try await store.removeAll()
        #expect(await store.cachedData(for: good) == nil)
    }

    @Test func tripImagesAreCollectedOnce() throws {
        let data = try Data(contentsOf: ALStoreTests.fixtures.appending(path: "collections__detail.json"))
        let trip = try ALCoding.decoder().decode(CollectionDetail.self, from: data)
        let urls = ImageStore.imageURLs(in: trip)
        #expect(urls.count == Set(urls).count)
        #expect(urls.count == trip.locations.flatMap(\.images).count + trip.lodging.flatMap(\.images).count + trip.transportations.flatMap(\.images).count)
    }
}
