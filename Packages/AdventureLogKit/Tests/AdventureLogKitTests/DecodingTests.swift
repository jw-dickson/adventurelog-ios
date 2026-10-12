// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Decoding real AdventureLog v0.13.0 responses")
struct DecodingTests {
    @Test func fixturesArePresent() throws {
        let readme = Fixture.directory.appending(path: "README.md")
        #expect(FileManager.default.fileExists(atPath: readme.path()), "Run tests from a full checkout: \(readme.path())")
    }

    @Test func collectionDetail() throws {
        let trip = try Fixture.trip()
        #expect(trip.name == "Tasmania Road Trip 2027")
        #expect(trip.startDate == CalendarDate("2027-03-05"))
        #expect(trip.endDate == CalendarDate("2027-03-23"))
        #expect(trip.locations.count == 5)
        #expect(trip.transportations.count == 6)
        #expect(trip.lodging.count == 2)
        #expect(trip.notes.count == 2)
        #expect(trip.checklists.count == 2)
        #expect(trip.itinerary.count == 16)
        #expect(trip.itineraryDays.count == 3)
        #expect(trip.collaborators.count == 2)
        #expect(trip.owner?.username == "admin")
        #expect(trip.status == .upcoming)
    }

    @Test func collectionDetailAsSharedUser() throws {
        let trip = try Fixture.decode(CollectionDetail.self, name: "collections__detail__as_guest.json")
        #expect(trip.currentUserIsOwner == false)
        #expect(trip.itinerary.count == 16)
    }

    @Test func coverPhotoIsTheChosenOneElseTheFirstPlacesPhoto() throws {
        // The seed trip has no cover chosen; the museum is its only place with a photo.
        let trip = try Fixture.decode(CollectionDetail.self, name: "collections__detail.json")
        #expect(trip.primaryImage == nil)
        let museum = try #require(trip.locations.first { $0.name == "Tasmanian Museum and Art Gallery" })
        #expect(trip.coverImageURL == museum.primaryImage?.url)

        // A chosen cover (the server's `primary_image`) wins.
        var object = try #require(try JSONSerialization.jsonObject(with: Fixture.data("responses", "collections__detail.json")) as? [String: Any])
        object["primary_image"] = ["id": "cover", "image": "https://adventurelog.example/media/images/cover.webp", "is_primary": true]
        let chosen = try ALCoding.decoder().decode(CollectionDetail.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(chosen.coverImageURL == URL(string: "https://adventurelog.example/media/images/cover.webp"))
    }

    @Test func nestedCollectionOmitsArrays() throws {
        let trip = try Fixture.decode(CollectionDetail.self, name: "collections__detail_nested.json")
        #expect(trip.transportations.isEmpty)
        #expect(!trip.locations.isEmpty)
        #expect(trip.locations.allSatisfy { $0.visits.isEmpty })
    }

    @Test(arguments: [
        "collections__all.json",
        "collections__archived.json",
    ])
    func collectionLists(_ name: String) throws {
        _ = try Fixture.decode([CollectionSummary].self, name: name)
    }

    @Test func sharedCollections() throws {
        let shared = try Fixture.decode([CollectionSummary].self, name: "collections__shared__as_guest.json")
        #expect(shared.count == 1)
        #expect(shared.first?.isTrip == true)
    }

    @Test func paginatedCollections() throws {
        let page = try Fixture.decode(Page<CollectionSummary>.self, name: "collections__list.json")
        #expect(page.count == page.results.count)
        #expect(page.next == nil)
    }

    @Test func paginatedLocations() throws {
        let page = try Fixture.decode(Page<Location>.self, name: "locations__list_page_size_2.json")
        #expect(page.results.count == 2)
        #expect(page.next != nil)
    }

    @Test func location() throws {
        let location = try Fixture.decode(Location.self, name: "locations__detail.json")
        #expect(location.category != nil)
        #expect(location.priceCurrency == "USD")
        #expect(!location.visits.isEmpty)
    }

    @Test func standaloneLists() throws {
        _ = try Fixture.decode([Location].self, name: "locations__all.json")
        _ = try Fixture.decode([Transportation].self, name: "transportations__list.json")
        _ = try Fixture.decode([Lodging].self, name: "lodging__list.json")
        _ = try Fixture.decode([Note].self, name: "notes__all.json")
        _ = try Fixture.decode([Checklist].self, name: "checklists__list.json")
        _ = try Fixture.decode([Visit].self, name: "visits__list.json")
        _ = try Fixture.decode([LocationCategory].self, name: "categories__list.json")
        _ = try Fixture.decode([ItineraryRow].self, name: "itineraries__list.json")
        _ = try Fixture.decode([ItineraryDayMeta].self, name: "itinerary-days__list.json")
    }

    @Test func currentUser() throws {
        let user = try Fixture.decode(User.self, name: "auth__user-metadata.json")
        #expect(user.username == "admin")
        #expect(user.displayName == "Alex Example")
    }

    @Test(arguments: [
        "itineraries__reorder_response__d1_swap.json",
        "itineraries__reorder_response__to_global.json",
        "itineraries__reorder_response__from_global_back_to_d1.json",
        "itineraries__reorder_response__move_note_d1_to_d2.json",
    ])
    func reorderResponses(_ name: String) throws {
        let rows = try Fixture.decodeWrapped([ItineraryRow].self, name)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { $0.isGlobal == ($0.date == nil) })
    }

    @Test func itineraryRowKindsUseNamesNotIntegers() throws {
        let trip = try Fixture.trip()
        let kinds = Set(trip.itinerary.map(\.kind))
        #expect(kinds == [.transportation, .lodging, .location, .note, .checklist])
    }

    @Test func checklistItems() throws {
        let trip = try Fixture.trip()
        let pickup = try #require(trip.checklists.first { $0.name == "Car pickup" })
        #expect(pickup.date == CalendarDate("2027-03-08"))
        #expect(pickup.items.count > 0)
        #expect(pickup.checkedCount >= 1)
    }

    @Test func unknownEnumValuesFallBack() throws {
        let json = #"{"id":"x","type":"hovercraft","name":"Test"}"#
        let leg = try ALCoding.decoder().decode(Transportation.self, from: Data(json.utf8))
        #expect(leg.type == .other)
    }

    @Test func lodgingWithBackwardsStayIsFlagged() throws {
        let trip = try Fixture.trip()
        #expect(trip.lodging.allSatisfy { $0.hasValidStay })
        var bad = try #require(trip.lodging.first)
        bad.checkOut = bad.checkIn?.addingTimeInterval(-3600)
        #expect(bad.hasValidStay == false)
    }
}
