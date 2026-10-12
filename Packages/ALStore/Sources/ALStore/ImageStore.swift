// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import AdventureLogKit
import CryptoKit
import Foundation

/// Photos for the offline pack. Every image a saved trip uses is downloaded once and kept on disk
/// (Application Support, excluded from backup) so item screens show them with no signal.
public actor ImageStore {
    public typealias Fetch = @Sendable (URL) async throws -> Data

    private let directory: URL
    private var inFlight: [URL: Task<Data, any Error>] = [:]
    /// Bumped by `removeAll()`. A download that started before the bump is not saved, so an
    /// account's photos can't reappear after sign-out cleared them.
    private var generation = 0

    /// - Parameter directory: defaults to `Application Support/AdventureLog/Images`.
    public init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
                ?? FileManager.default.temporaryDirectory
            self.directory = support.appending(path: "AdventureLog").appending(path: "Images")
        }
    }

    /// Every image URL a trip uses: its cover, locations, stays and transport legs.
    public nonisolated static func imageURLs(in trip: CollectionDetail) -> [URL] {
        let images = [trip.primaryImage].compactMap { $0 } + trip.locations.flatMap(\.images)
            + trip.lodging.flatMap(\.images) + trip.transportations.flatMap(\.images)
        var seen = Set<URL>()
        return images.compactMap(\.url).filter { seen.insert($0).inserted }
    }

    public func cachedData(for url: URL) -> Data? {
        try? Data(contentsOf: file(for: url))
    }

    /// The saved copy, or a download that is then saved.
    public func data(for url: URL, fetch: @escaping Fetch) async throws -> Data {
        if let saved = cachedData(for: url) { return saved }
        if let running = inFlight[url] { return try await running.value }
        let started = generation
        let task = Task { try await fetch(url) }
        inFlight[url] = task
        defer {
            if generation == started { inFlight[url] = nil }
        }
        let data = try await task.value
        if generation == started { try save(data, for: url) }
        return data
    }

    /// Downloads whatever is not saved yet. Failures are skipped; returns how many were added.
    @discardableResult
    public func prefetch(_ urls: [URL], fetch: @escaping Fetch) async -> Int {
        var added = 0
        let started = generation
        for url in urls where cachedData(for: url) == nil {
            guard generation == started else { break } // cleared mid-prefetch: stop
            if (try? await data(for: url, fetch: fetch)) != nil { added += 1 }
        }
        return added
    }

    public func removeAll() throws {
        generation += 1
        inFlight.values.forEach { $0.cancel() }
        inFlight = [:]
        if FileManager.default.fileExists(atPath: directory.path()) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func file(for url: URL) -> URL {
        directory.appending(path: Self.fileName(for: url))
    }

    /// The name a URL's saved copy has in the directory, so a test seed can write one directly.
    public nonisolated static func fileName(for url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func save(_ data: Data, for url: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var target = file(for: url)
        #if os(iOS)
        try data.write(to: target, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: target, options: [.atomic])
        #endif
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? target.setResourceValues(values)
    }
}
