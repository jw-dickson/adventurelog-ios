// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation
import Testing
@testable import ALStore

@Suite("Device state")
struct DeviceStateStoreTests {
    func makeStore() -> (DeviceStateStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appending(path: "al-device-\(UUID().uuidString)")
        return (DeviceStateStore(directory: directory), directory)
    }

    @Test func unsentEditsAndSkipsSurviveARelaunch() async throws {
        let (store, directory) = makeStore()
        var state = await store.load()
        #expect(state == DeviceStateStore.State())
        state.outbox.enqueue(.editNote(.init(noteID: "n", noteName: "Tips", baseContent: "", content: "Ferry at 9")), tripID: "t", at: .now)
        state.skipped["t"] = ["row-1"]
        try await store.save(state)

        let relaunched = DeviceStateStore(directory: directory)
        let loaded = await relaunched.load()
        #expect(loaded == state)
        #expect(loaded.outbox.waitingCount == 1)
    }

    @Test func unreadableStateStartsEmptyAndRemoveAllDeletes() async throws {
        let (store, directory) = makeStore()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appending(path: "device-state.json"))
        #expect(await store.load() == DeviceStateStore.State())
        try await store.save(DeviceStateStore.State(skipped: ["t": ["r"]]))
        try await store.removeAll()
        #expect(await store.load() == DeviceStateStore.State())
        try await store.removeAll() // nothing there: still fine
    }
}
