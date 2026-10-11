// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import Foundation

/// The recorded route and geofence events of each trip, on this phone only.
///
/// Append-only JSON lines, one file per trip and kind, so recording a point never rewrites the
/// day's track. Times are Unix seconds. A line that can't be read (a write cut short) is skipped.
public actor TrackStore {
    private let directory: URL

    /// - Parameter directory: defaults to `Application Support/AdventureLog/Tracks`.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appending(path: "AdventureLog").appending(path: "Tracks")
        }
    }

    public func append(_ points: [TrackPoint], tripID: String) throws {
        try append(points, to: file("track", tripID))
    }

    public func append(_ event: PlaceEvent, tripID: String) throws {
        try append([event], to: file("events", tripID))
    }

    public func points(tripID: String) -> [TrackPoint] {
        read(file("track", tripID))
    }

    public func events(tripID: String) -> [PlaceEvent] {
        read(file("events", tripID))
    }

    /// Forgets one trip's log.
    public func remove(tripID: String) throws {
        for kind in ["track", "events"] {
            let url = file(kind, tripID)
            if FileManager.default.fileExists(atPath: url.path()) { try FileManager.default.removeItem(at: url) }
        }
    }

    /// Forgets every log, e.g. on sign-out.
    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path()) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func file(_ kind: String, _ tripID: String) -> URL {
        let safe = String(tripID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "-" })
        return directory.appending(path: "\(kind)-\(safe).jsonl")
    }

    private func append<T: Encodable>(_ values: [T], to url: URL) throws {
        guard !values.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        var data = Data()
        for value in values {
            data.append(try encoder.encode(value))
            data.append(0x0A)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path()) {
            #if os(iOS)
            // Readable by background location updates after first unlock.
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: [.atomic])
            #endif
            var target = url
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? target.setResourceValues(values)
            return
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        if end > 0 {
            // A write cut short leaves no newline; start on a fresh line so this record survives.
            try handle.seek(toOffset: end - 1)
            if try handle.read(upToCount: 1) != Data([0x0A]) { data.insert(0x0A, at: 0) }
            try handle.seekToEnd()
        }
        try handle.write(contentsOf: data)
    }

    private func read<T: Decodable>(_ url: URL) -> [T] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(T.self, from: Data($0)) }
    }
}
