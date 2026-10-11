// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation

/// The last good copy of each trip and of the trip list, as the server sent it, so the app opens
/// and browses offline. Stage 1 replaces this with the SwiftData cache and outbox; the on-disk
/// format is plain AdventureLog JSON so it stays readable and easy to migrate.
public actor TripSnapshotStore {
    public struct TripList: Codable, Sendable, Hashable {
        public var owned: [CollectionSummary]
        public var shared: [CollectionSummary]
        public var savedAt: Date

        public init(owned: [CollectionSummary], shared: [CollectionSummary], savedAt: Date) {
            self.owned = owned
            self.shared = shared
            self.savedAt = savedAt
        }
    }

    public struct Snapshot<Value: Codable & Sendable>: Codable, Sendable {
        public var value: Value
        public var savedAt: Date
    }

    private let directory: URL

    /// Selects a snapshot directory; snapshot files are created on write with backup exclusion attempted.
    /// - Parameter directory: Defaults to `Application Support/AdventureLog/Trips`, or
    ///   `AdventureLog/Trips` under the temporary directory if Application Support cannot be located.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appending(path: "AdventureLog").appending(path: "Trips")
        }
    }

    /// Replaces the saved trip list, preserving its supplied save time at whole-second precision.
    /// - Throws: Directory creation, JSON encoding, or file write errors. Backup exclusion errors are ignored.
    public func saveTripList(_ list: TripList) throws {
        try write(list, to: "trip-list.json")
    }

    /// Returns the saved trip list, or `nil` if the file is missing, unreadable, or cannot be decoded.
    public func tripList() -> TripList? {
        try? read(TripList.self, from: "trip-list.json")
    }

    /// Replaces the snapshot for the trip ID, recording `date` as its save time at whole-second precision.
    /// - Throws: Directory creation, JSON encoding, or file write errors. Backup exclusion errors are ignored.
    public func saveTrip(_ trip: CollectionDetail, at date: Date = .now) throws {
        try write(Snapshot(value: trip, savedAt: date), to: "trip-\(Self.safe(trip.id)).json")
    }

    /// Returns the snapshot for the trip ID, or `nil` if it is missing, unreadable, or cannot be decoded.
    public func trip(id: String) -> Snapshot<CollectionDetail>? {
        try? read(Snapshot<CollectionDetail>.self, from: "trip-\(Self.safe(id)).json")
    }

    /// Deletes the snapshot directory and all its contents, e.g. on sign-out; succeeds if absent.
    /// - Throws: File-system errors from removing the directory.
    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path()) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    /// Writes AdventureLog JSON atomically under the snapshot directory, creating the directory if needed.
    /// Propagates directory, encoding, and write errors; failure to exclude the file from backup is ignored.
    private func write<T: Encodable>(_ value: T, to name: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory.appending(path: name)
        let data = try ALCoding.encoder().encode(value)
        #if os(iOS)
        // Readable by background tasks after first unlock, like the credentials.
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    /// Reads AdventureLog JSON from a snapshot file; propagates file access and decoding errors.
    private func read<T: Decodable>(_ type: T.Type, from name: String) throws -> T {
        let data = try Data(contentsOf: directory.appending(path: name))
        return try ALCoding.decoder().decode(T.self, from: data)
    }

    /// Keeps only Unicode alphanumerics and hyphens for a filename component; distinct IDs may map to the same result.
    private static func safe(_ id: String) -> String {
        String(id.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
    }
}
