// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation

/// What only this phone knows: edits not yet on the server, and the rows skipped on Today.
///
/// Kept apart from the trip snapshots, which are always exactly what the server sent, so a
/// refresh can never overwrite an unsent edit. One small JSON file, written after every change.
public actor DeviceStateStore {
    public struct State: Codable, Sendable, Hashable {
        public var outbox: Outbox
        /// Itinerary row ids skipped on Today, by trip id. Never sent to the server.
        public var skipped: [String: Set<String>]
        /// Trips whose route the person agreed to log, and trips they said no to.
        public var trackingAllowed: Set<String>
        public var trackingDeclined: Set<String>

        public init(outbox: Outbox = Outbox(), skipped: [String: Set<String>] = [:],
                    trackingAllowed: Set<String> = [], trackingDeclined: Set<String> = []) {
            self.outbox = outbox
            self.skipped = skipped
            self.trackingAllowed = trackingAllowed
            self.trackingDeclined = trackingDeclined
        }

        private enum CodingKeys: String, CodingKey { case outbox, skipped, trackingAllowed, trackingDeclined }

        /// Fields added later decode as empty, so an update never loses unsent edits.
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            outbox = try container.decodeIfPresent(Outbox.self, forKey: .outbox) ?? Outbox()
            skipped = try container.decodeIfPresent([String: Set<String>].self, forKey: .skipped) ?? [:]
            trackingAllowed = try container.decodeIfPresent(Set<String>.self, forKey: .trackingAllowed) ?? []
            trackingDeclined = try container.decodeIfPresent(Set<String>.self, forKey: .trackingDeclined) ?? []
        }
    }

    private let file: URL

    /// - Parameter directory: defaults to `Application Support/AdventureLog/Device`.
    public init(directory: URL? = nil) {
        let folder: URL
        if let directory {
            folder = directory
        } else {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            folder = support.appending(path: "AdventureLog").appending(path: "Device")
        }
        self.file = folder.appending(path: "device-state.json")
    }

    /// The saved state, or an empty one when there is none or it can't be read.
    public func load() -> State {
        guard let data = try? Data(contentsOf: file) else { return State() }
        return (try? JSONDecoder().decode(State.self, from: data)) ?? State()
    }

    /// Replaces the saved state.
    /// - Throws: Directory creation, encoding or write errors.
    public func save(_ state: State) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        var url = file
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Deletes the state, e.g. on sign-out; succeeds if there is none.
    /// - Throws: File-system errors from removing the file.
    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: file.path()) {
            try FileManager.default.removeItem(at: file)
        }
    }
}
