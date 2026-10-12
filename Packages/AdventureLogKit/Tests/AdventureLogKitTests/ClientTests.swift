// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

@Suite("Requests, errors and the wire format")
struct ClientTests {
    let client = AdventureLogClient(baseURL: URL(string: "https://adventurelog.example")!, apiKey: "al_test")

    @Test func pathsAlwaysEndInASlash() {
        for path in ["api/collections", "/api/collections/", "auth/user-metadata"] {
            let request = client.makeRequest("GET", path)
            #expect(request.url?.absoluteString.hasSuffix("/") == true, "\(path)")
        }
        #expect(client.makeRequest("GET", "api/collections").url?.absoluteString == "https://adventurelog.example/api/collections/")
    }

    @Test func authenticatesWithTheKeyAndNoCookies() {
        let request = client.makeRequest("POST", "api/itineraries/reorder/", body: Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "X-API-Key") == "al_test")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.httpShouldHandleCookies == false)
    }

    @Test func mediaSendsTheKeyOnlyToTheServersOrigin() {
        let key = { (url: String) in client.mediaRequest(URL(string: url)!).value(forHTTPHeaderField: "X-API-Key") }
        #expect(key("https://adventurelog.example/media/images/a.jpg") == "al_test")
        #expect(key("https://AdventureLog.example:443/media/images/a.jpg") == "al_test")
        #expect(key("http://adventurelog.example/media/images/a.jpg") == nil)
        #expect(key("https://adventurelog.example:8443/media/images/a.jpg") == nil)
        #expect(key("https://cdn.example/media/images/a.jpg") == nil)
        #expect(client.mediaRequest(URL(string: "https://cdn.example/a.jpg")!).httpShouldHandleCookies == false)
    }

    @Test func queryItemsKeepTheSlash() {
        let request = client.makeRequest("GET", "api/locations/", query: [URLQueryItem(name: "page_size", value: "2")])
        #expect(request.url?.absoluteString == "https://adventurelog.example/api/locations/?page_size=2")
    }

    @Test(arguments: [
        ("adventurelog.example", "https://adventurelog.example"),
        ("https://adventurelog.example/", "https://adventurelog.example"),
        ("  http://192.168.1.10:8015  ", "http://192.168.1.10:8015"),
        ("https://example.com/adventurelog/", "https://example.com/adventurelog"),
    ])
    func normalisesServerAddresses(_ input: String, _ expected: String) {
        #expect(AdventureLogClient.normalizedServerURL(input)?.absoluteString == expected)
    }

    @Test(arguments: ["", "   ", "ftp://example.com", "https://"])
    func rejectsUnusableAddresses(_ input: String) {
        #expect(AdventureLogClient.normalizedServerURL(input) == nil)
    }

    @Test func subpathServersKeepTheirPrefix() {
        let sub = AdventureLogClient(baseURL: URL(string: "https://example.com/adventurelog")!, apiKey: "k")
        #expect(sub.makeRequest("GET", "api/collections/").url?.absoluteString == "https://example.com/adventurelog/api/collections/")
    }

    @Test func reorderToTripWideMatchesWhatTheServerAccepted() throws {
        let captured = try Fixture.data("requests", "itineraries__reorder__to_global.json")
        let object = try #require(JSONSerialization.jsonObject(with: captured) as? [String: Any])
        let body = try #require(object["body"] as? [String: Any])
        let items = try #require(body["items"] as? [[String: Any]])

        let request = ItineraryReorderRequest(items: items.map {
            .init(id: $0["id"] as! String, date: nil, order: $0["order"] as! Int)
        })
        let encoded = try ALCoding.encoder().encode(request)
        let ours = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let ourItems = try #require(ours["items"] as? [[String: Any]])

        #expect(ourItems.count == items.count)
        for (mine, theirs) in zip(ourItems, items) {
            #expect(Set(mine.keys) == Set(theirs.keys))
            #expect(mine["date"] is NSNull)
            #expect(mine["is_global"] as? Bool == true)
            #expect(mine["id"] as? String == theirs["id"] as? String)
            #expect(mine["order"] as? Int == theirs["order"] as? Int)
        }
    }

    @Test func reorderOntoADaySendsTheDate() throws {
        let request = ItineraryReorderRequest(items: [.init(id: "a", date: CalendarDate("2027-03-08"), order: 3)])
        let json = String(decoding: try ALCoding.encoder().encode(request), as: UTF8.self)
        #expect(json == #"{"items":[{"date":"2027-03-08","id":"a","is_global":false,"order":3}]}"#)
    }

    @Test func createRowUsesTheModelName() throws {
        let request = ItineraryCreateRequest(collection: "c", kind: .location, objectId: "o", date: CalendarDate("2027-03-07"), order: 0)
        let json = String(decoding: try ALCoding.encoder().encode(request), as: UTF8.self)
        #expect(json == #"{"collection":"c","content_type":"location","date":"2027-03-07","is_global":false,"object_id":"o","order":0}"#)
    }

    @Test(arguments: [
        ("401__bad_api_key.json", 401, "Invalid or expired API key."),
        ("403__shared_user_patch_note_without_collection.json", 403, "You cannot remove the collection as you are not the owner."),
        ("400__reorder_empty.json", 400, "items: This field is required and must not be empty."),
        ("400__collections_list_no_auth.json", 400, "User is not authenticated"),
    ])
    func errorBodiesBecomeReadableMessages(_ name: String, _ status: Int, _ summary: String) throws {
        let error = APIError.from(status: status, data: try Fixture.data("errors", name))
        #expect(error.errorDescription == summary)
    }

    @Test func validationErrorsKeepEveryField() throws {
        let error = APIError.from(status: 400, data: try Fixture.data("errors", "400__visit_bad_datetime.json"))
        guard case .invalid(let message) = error else {
            Issue.record("expected .invalid, got \(error)")
            return
        }
        #expect(Set(message.fields.keys) == ["start_date", "timezone"])
        #expect(message.fields["timezone"] == [#""Mars/Olympus" is not a valid choice."#])
    }

    @Test func htmlErrorPagesFallBackToTheStatus() {
        let error = APIError.from(status: 500, data: Data("<html>oops</html>".utf8))
        #expect(error.isTransient)
        #expect(error.errorDescription == "Server error 500: Internal Server Error")
    }

    @Test func aCancelledRequestIsToldApartFromRealFailures() {
        #expect(APIError.transport(code: URLError.cancelled.rawValue, description: "cancelled").isCancellation)
        #expect(!APIError.transport(code: URLError.notConnectedToInternet.rawValue, description: "offline").isCancellation)
        #expect(!APIError.transport(code: URLError.timedOut.rawValue, description: "timed out").isCancellation)
        #expect(!APIError.badServerURL.isCancellation)
    }
}
