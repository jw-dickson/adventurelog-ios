// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Wire format edge cases")
struct WireEdgeCaseTests {
    @Test(arguments: [
        ("http://example.com/app", "http://EXAMPLE.com:80/media/image.jpg", true),
        ("https://example.com:8443/app", "https://example.com:8443/media/image.jpg", true),
        ("https://example.com:8443/app", "https://example.com/media/image.jpg", false),
        ("https://example.com/app", "https://example.com.evil.test/media/image.jpg", false),
        ("https://example.com/app", "https://example.com@evil.test/media/image.jpg", false),
        ("https://example.com/app", "/media/image.jpg", false),
    ])
    func mediaAuthenticationChecksTheFullOrigin(_ server: String, _ media: String, _ authenticated: Bool) throws {
        let baseURL = try #require(URL(string: server))
        let mediaURL = try #require(URL(string: media))
        let client = AdventureLogClient(baseURL: baseURL, apiKey: "al_test")
        let request = client.mediaRequest(mediaURL)
        #expect(request.url == mediaURL)
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == (authenticated ? "al_test" : nil))
        #expect(!request.httpShouldHandleCookies)
    }

    @Test(arguments: [
        #"{"id":"c","name":"Trip"}"#,
        #"{"id":"c","name":"Trip","locations":null,"transportations":null,"lodging":null,"notes":null,"checklists":null,"itinerary":null,"itinerary_days":null,"shared_with":null,"collaborators":null}"#,
    ])
    func omittedAndNullArraysAreEmpty(_ json: String) throws {
        let trip = try ALCoding.decoder().decode(CollectionDetail.self, from: Data(json.utf8))
        #expect(trip.locations.isEmpty)
        #expect(trip.transportations.isEmpty)
        #expect(trip.lodging.isEmpty)
        #expect(trip.notes.isEmpty)
        #expect(trip.checklists.isEmpty)
        #expect(trip.itinerary.isEmpty)
        #expect(trip.itineraryDays.isEmpty)
        #expect(trip.sharedWith.isEmpty)
        #expect(trip.collaborators.isEmpty)
        let encoded = try ALCoding.encoder().encode(trip)
        let restored = try ALCoding.decoder().decode(CollectionDetail.self, from: encoded)
        #expect(restored == trip)
    }

    @Test(arguments: [
        #"{"id":"c","name":"Trip","locations":{}}"#,
        #"{"id":"c","name":"Trip","locations":[{"id":"missing-name"}]}"#,
        #"{"id":"c","name":"Trip","shared_with":[42]}"#,
    ])
    func malformedArraysAreNotSilentlyDiscarded(_ json: String) {
        #expect(throws: DecodingError.self) {
            try ALCoding.decoder().decode(CollectionDetail.self, from: Data(json.utf8))
        }
    }

    @Test func unknownEnumsFallBackButKnownValuesRoundTrip() throws {
        try checkEnum(TransportationType.self, fallback: .other)
        try checkEnum(LodgingType.self, fallback: .other)
        try checkEnum(CollectionStatus.self, fallback: .folder)
        try checkEnum(ItemKind.self, fallback: .unknown)
    }

    private func checkEnum<T: LenientStringEnum>(_ type: T.Type, fallback: T) throws {
        let decoded = try ALCoding.decoder().decode(T.self, from: Data(#""future-server-value""#.utf8))
        #expect(decoded == fallback)
        for value in T.allCases {
            let encoded = try ALCoding.encoder().encode(value)
            let wire = try JSONDecoder().decode(String.self, from: encoded)
            let restored = try ALCoding.decoder().decode(T.self, from: encoded)
            #expect(wire == value.rawValue)
            #expect(restored == value)
        }
        for json in ["null", "42", "{}"] {
            #expect(throws: DecodingError.self) {
                try ALCoding.decoder().decode(T.self, from: Data(json.utf8))
            }
        }
    }

    @Test func explicitItemTypeTakesPrecedenceOverLegacyObjectName() throws {
        let json = #"{"id":"r","collection":"c","object_id":"o","object_name":"note","item":{"id":"o","type":"location"},"is_global":true,"order":0}"#
        var row = try ALCoding.decoder().decode(ItineraryRow.self, from: Data(json.utf8))
        #expect(row.kind == .location)
        row.item = nil
        #expect(row.kind == .note)
        row.objectName = "future-kind"
        #expect(row.kind == .unknown)
        row.objectName = nil
        #expect(row.kind == .unknown)
    }

    @Test func primaryImagePrefersTheFlagAndFallsBackToTheFirstImage() throws {
        let json = #"{"id":"l","name":"Place","images":[{"id":"first","image":"https://example.com/a.jpg","is_primary":false},{"id":"primary","image":"https://example.com/b.jpg","is_primary":true}]}"#
        var location = try ALCoding.decoder().decode(Location.self, from: Data(json.utf8))
        #expect(location.primaryImage?.id == "primary")
        location.images[1].isPrimary = false
        #expect(location.primaryImage?.id == "first")
        location.images = []
        #expect(location.primaryImage == nil)
    }

    @Test func checklistCountsOnlyCheckedItemsIncludingAnEmptyList() throws {
        let json = #"{"id":"c","name":"Packing","items":[{"id":"a","name":"A","is_checked":true},{"id":"b","name":"B","is_checked":false},{"id":"c","name":"C","is_checked":true}]}"#
        var checklist = try ALCoding.decoder().decode(Checklist.self, from: Data(json.utf8))
        #expect(checklist.checkedCount == 2)
        checklist.items[0].isChecked = false
        #expect(checklist.checkedCount == 1)
        checklist.items = []
        #expect(checklist.checkedCount == 0)
    }

    @Test func staysAllowEqualOrUnknownEndpoints() throws {
        var stay = try Fixture.decode(Lodging.self, name: "lodging__detail.json")
        let checkIn = try #require(stay.checkIn)
        stay.checkOut = checkIn
        #expect(stay.hasValidStay)
        stay.checkOut = nil
        #expect(stay.hasValidStay)
        stay.checkIn = nil
        stay.checkOut = checkIn
        #expect(stay.hasValidStay)
    }

    @Test func dateOnlyDatetimesDecodeAtUTCMidnightAndEncodeCanonically() throws {
        let json = #"{"id":"v","start_date":"2028-02-29","end_date":"2028-03-01T01:30:00+01:30"}"#
        let visit = try ALCoding.decoder().decode(Visit.self, from: Data(json.utf8))
        #expect(visit.startDate == ISO8601.parse("2028-02-29T00:00:00Z"))
        #expect(visit.endDate == ISO8601.parse("2028-03-01T00:00:00Z"))
        let encoded = try ALCoding.encoder().encode(visit)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: String])
        #expect(object["start_date"] == "2028-02-29T00:00:00Z")
        #expect(object["end_date"] == "2028-03-01T00:00:00Z")
    }

    @Test(arguments: [#""2026-02-30""#, #""nonsense""#, "42"])
    func invalidDatetimesFailDecoding(_ value: String) {
        let json = "{\"id\":\"v\",\"start_date\":\(value)}"
        #expect(throws: DecodingError.self) {
            try ALCoding.decoder().decode(Visit.self, from: Data(json.utf8))
        }
    }

    @Test func globalCreateRequestUsesNamesAndOmitsTheDate() throws {
        let request = ItineraryCreateRequest(collection: "c", kind: .checklist, objectId: "o", date: nil, order: 7)
        let data = try ALCoding.encoder().encode(request)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["content_type"] as? String == "checklist")
        #expect(object["object_id"] as? String == "o")
        #expect(object["collection"] as? String == "c")
        #expect(object["is_global"] as? Bool == true)
        #expect(object["order"] as? Int == 7)
        #expect(object["date"] == nil)
    }

    @Test func requestPreservesEncodedBodyAndJSONHeaders() throws {
        let client = AdventureLogClient(baseURL: URL(string: "https://example.com")!, apiKey: "al_test")
        let reorder = ItineraryReorderRequest(items: [.init(id: "r", date: nil, order: 2)])
        let body = try client.body(reorder)
        let request = client.makeRequest("POST", "api/itineraries/reorder", body: body)
        #expect(request.httpBody == body)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://example.com/api/itineraries/reorder/")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "al_test")
        #expect(!request.httpShouldHandleCookies)
    }

    @Test func validationSummaryIsStableAndPreservesAllMessages() {
        let json = #"{"z":["first","second"],"a":"required","non_field_errors":["Invalid combination"],"empty":[]}"#
        let message = ServerMessage(data: Data(json.utf8), status: 400)
        #expect(message.summary == "a: required\nInvalid combination\nz: first")
        #expect(message.fields == ["a": ["required"], "z": ["first", "second"], "non_field_errors": ["Invalid combination"], "empty": []])
    }

    @Test(arguments: [
        (#"{"detail":"detail wins","error":"error","message":"message"}"#, "detail wins"),
        (#"{"error":"error wins","message":"message"}"#, "error wins"),
        (#"{"message":"message wins"}"#, "message wins"),
        ("  Service temporarily unavailable\n", "Service temporarily unavailable"),
    ])
    func serverMessagesRespectPrecedenceAndPlainText(_ body: String, _ expected: String) {
        let message = ServerMessage(data: Data(body.utf8), status: 503)
        #expect(message.summary == expected)
        #expect(message.fields.isEmpty)
    }

    @Test(arguments: ["", " \n", "<html>failure</html>", "[]", "{}"])
    func unusableErrorBodiesFallBackToHTTPStatus(_ body: String) {
        let message = ServerMessage(data: Data(body.utf8), status: 503)
        #expect(message.summary == HTTPURLResponse.localizedString(forStatusCode: 503).capitalized)
    }

    @Test func queryValuesRoundTripWithoutChangingPathOrHeaders() throws {
        let client = AdventureLogClient(baseURL: URL(string: "https://example.com/adventurelog///")!, apiKey: "al_test")
        let query = [URLQueryItem(name: "search", value: "lake & mountain/雪"), URLQueryItem(name: "tag", value: "a"), URLQueryItem(name: "tag", value: "b")]
        let request = client.makeRequest("GET", "/api/locations/", query: query)
        let url = try #require(request.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.path == "/adventurelog/api/locations/")
        #expect(components.queryItems == query)
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "al_test")
        #expect(!request.httpShouldHandleCookies)
    }
}
