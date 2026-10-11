// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
@testable import AdventureLogKit

/// `{status, body}` envelope used for captured write responses.
struct Wrapped<Body: Decodable>: Decodable {
    let status: Int
    let body: Body
}

/// Loads JSON captured from a real AdventureLog server (see Fixtures/adventurelog-v0.13.0/README.md).
enum Fixture {
    static let version = "adventurelog-v0.13.0"

    /// Repository root, found from this file's path so tests need no bundled resources.
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() } // FixtureLoader.swift → Tests target → Tests → package → Packages → root
        return url
    }()

    static var directory: URL {
        root.appending(path: "Fixtures").appending(path: version)
    }

    static func data(_ folder: String, _ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: folder).appending(path: name))
    }

    /// Raw GET bodies in `responses/`, error bodies in `errors/`.
    static func decode<T: Decodable>(_ type: T.Type, _ folder: String = "responses", _ name: String) throws -> T {
        try ALCoding.decoder().decode(T.self, from: data(folder, name))
    }

    /// Write responses are wrapped as `{status, body}`.
    static func decodeWrapped<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try ALCoding.decoder().decode(Wrapped<T>.self, from: data("responses", name)).body
    }

    /// The seeded (synthetic) Tasmania trip.
    static func trip() throws -> CollectionDetail {
        try decode(CollectionDetail.self, name: "collections__detail.json")
    }

    static func decode<T: Decodable>(_ type: T.Type, name: String) throws -> T {
        try decode(type, "responses", name)
    }
}
