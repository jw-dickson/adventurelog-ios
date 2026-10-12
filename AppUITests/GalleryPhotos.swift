// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import XCTest

/// Drawn photos for the screenshot gallery (`Photos/`, made by scripts/gallery-photos.py). The seed
/// trip has only one tiny photo, so the gallery gives a few of its items, and the trip itself, a
/// picture each. Only the copy handed to the app changes; the fixture stays as captured.
enum GalleryPhotos {
    /// Item name (as in the fixture) → photo, and the trip's cover.
    static let items: [(kind: String, name: String, photo: String)] = [
        ("locations", "Wineglass Bay Lookout", "lookout"),
        ("locations", "Sunset cruise", "cruise"),
        ("lodging", "Bay Holiday Park", "campground"),
    ]
    static let cover = "cover"

    static func url(_ photo: String) -> String { "https://adventurelog.example/media/images/gallery-\(photo).jpg" }

    /// The trip JSON with those photos attached, and the photos for `AL_SEED_IMAGES`.
    static func seed(_ tripJSON: String) throws -> (trip: String, images: String) {
        var trip = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(tripJSON.utf8)) as? [String: Any])
        for item in items {
            var list = try XCTUnwrap(trip[item.kind] as? [[String: Any]], "no \(item.kind) in the seed trip")
            let index = try XCTUnwrap(list.firstIndex { $0["name"] as? String == item.name }, "\(item.name) isn't in the seed trip")
            list[index]["images"] = [image(item.photo)]
            trip[item.kind] = list
        }
        trip["primary_image"] = image(cover)

        let bundle = Bundle(for: OfflineBrowseUITests.self)
        var images: [String: String] = [:]
        for photo in items.map(\.photo) + [cover] {
            let file = try XCTUnwrap(bundle.url(forResource: photo, withExtension: "jpg"), "\(photo).jpg is not in the test bundle")
            images[url(photo)] = try Data(contentsOf: file).base64EncodedString()
        }
        let tripData = try JSONSerialization.data(withJSONObject: trip)
        let imageData = try JSONSerialization.data(withJSONObject: images)
        return (String(decoding: tripData, as: UTF8.self), String(decoding: imageData, as: UTF8.self))
    }

    private static func image(_ photo: String) -> [String: Any] {
        ["id": "gallery-\(photo)", "image": url(photo), "is_primary": true]
    }
}
