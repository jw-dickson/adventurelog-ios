// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux
#endif
import Testing
@testable import AdventureLogKit

/// Answers like `Companion/companion/app.py`: the key must be `al_synthetic_key`.
private final class CompanionProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seen: [(method: String, path: String, body: [String: String])] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
        Self.seen.append((request.httpMethod ?? "", request.url?.path() ?? "", body))
        let ok = request.value(forHTTPHeaderField: "X-API-Key") == "al_synthetic_key"
        let status = ok ? (request.httpMethod == "POST" ? 200 : 204) : 401
        // Like the companion: it can start activities once it holds a push-to-start token.
        let registered = body["startToken"] != nil ? #"{"id":"d1","canStart":true}"# : #"{"id":"d1","canStart":false}"#
        let reply = ok ? (status == 200 ? registered : "") : #"{"detail":"AdventureLog refused the API key."}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Companion service", .serialized)
struct CompanionClientTests {
    func client(key: String = "al_synthetic_key") -> CompanionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CompanionProtocol.self]
        return CompanionClient(baseURL: URL(string: "https://companion.example/")!, apiKey: key,
                               session: URLSession(configuration: configuration))
    }

    @Test func registersSendsTokensAndUnregisters() async throws {
        CompanionProtocol.seen = []
        let canStart = try await client().register(environment: .sandbox, startToken: Data([0x0a, 0xff]))
        #expect(canStart == true)
        try await client().setActivityToken(Data([0x01, 0x02]), tripID: "trip", rowID: "row")
        try await client().unregister()
        let seen = CompanionProtocol.seen
        #expect(seen.map(\.method) == ["POST", "PUT", "DELETE"])
        #expect(seen.map(\.path) == ["/v1/devices", "/v1/activities", "/v1/devices"])
        #expect(seen[0].body == ["environment": "sandbox", "startToken": "0aff"])
        #expect(seen[1].body == ["tripID": "trip", "rowID": "row", "pushToken": "0102"])
    }

    @Test func withoutAStartTokenTheCompanionCantStartActivities() async throws {
        #expect(try await client().register(environment: .production, startToken: nil) == false)
    }

    @Test func aRefusedKeyIsUnauthorized() async {
        await #expect(throws: APIError.self) {
            try await client(key: "wrong").register(environment: .production, startToken: nil)
        }
    }
}

/// Answers health and replan asks like the companion with Claude set up (Stage 5b).
private final class ReplanProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var lastBody: [String: Any] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        Self.lastBody = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let reply: String
        switch request.url?.path() {
        case "/healthz": reply = #"{"ok": true, "pushes": false, "replan": true}"#
        default:
            reply = """
            {"behindMinutes": 48, "summary": "Keeps the tour.", "source": "claude",
             "changes": [{"type": "keep", "rowID": "row-tour"}, {"type": "skip", "rowID": "row-walk", "reason": "Rain"}]}
            """
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Companion replan asks", .serialized)
struct CompanionReplanTests {
    func client() -> CompanionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ReplanProtocol.self]
        return CompanionClient(baseURL: URL(string: "https://companion.example")!, apiKey: "al_synthetic_key",
                               session: URLSession(configuration: configuration))
    }

    @Test func healthSaysWhetherClaudeIsSetUp() async throws {
        #expect(try await client().health() == CompanionClient.Health(ok: true, pushes: false, replan: true))
    }

    @Test func anAskSendsTheDayWithISOTimesAndReturnsClaudesProposal() async throws {
        let hobart = TimeZone(identifier: "Australia/Hobart")!
        let day = CalendarDate("2027-03-08")!
        let start = ISO8601.parse("2027-03-08T05:00:00Z")!
        let stop = Replan.Stop(rowID: "row-walk", itemID: "walk", title: "Cape Tourville walk", kind: .location, start: start,
                               end: start.addingTimeInterval(3600), zone: hobart, isBooked: false, coordinate: nil)
        let situation = Replan.Situation(date: day, now: start.addingTimeInterval(48 * 60), stops: [stop], delayMinutes: 48, zone: hobart)
        let proposal = try await client().replan(situation: situation, ask: "It's raining", proposal: nil,
                                                 tripDays: [day, day.adding(days: 1)])
        #expect(proposal.source == .claude)
        #expect(proposal.changes == [.keep(rowID: "row-tour"), .skip(rowID: "row-walk", reason: "Rain")])

        let body = ReplanProtocol.lastBody
        #expect(body["ask"] as? String == "It's raining")
        #expect(body["tripDays"] as? [String] == ["2027-03-08", "2027-03-09"])
        let sent = try #require(body["situation"] as? [String: Any])
        #expect(sent["now"] as? String == "2027-03-08T05:48:00Z", "times go as ISO-8601, as the companion reads them")
        #expect(sent["zoneID"] as? String == "Australia/Hobart")
        let stops = try #require(sent["stops"] as? [[String: Any]])
        #expect(stops.first?["start"] as? String == "2027-03-08T05:00:00Z")
    }
}

/// Answers the photo calls like the companion with photos set up (Stage 6).
private final class PhotosProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var seen: [(method: String, path: String, body: [String: Any])] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    static let summary = """
    {"enabled": true, "cameraOffsetMinutes": 3, "lastRun": "2027-03-24T02:00:00+00:00", "lastError": null,
     "days": [{"date": "2027-03-08", "photos": 6, "undone": 0, "failed": 1,
               "stops": [{"title": "Sunset cruise", "photos": 1}, {"title": "", "photos": 2},
                         {"title": "Wineglass Bay Lookout", "photos": 3}]}]}
    """

    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let path = request.url?.path() ?? ""
        Self.seen.append((request.httpMethod ?? "", path, body))
        var status = 200
        var reply = Self.summary
        if path.hasPrefix("/v1/trips/missing") {
            status = 404
            reply = #"{"detail": "That trip can't be found with this key."}"#
        } else if path.hasSuffix("/undo") {
            reply = #"{"restored": 5, "kept": 1, "# + String(Self.summary.dropFirst())
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Companion photos", .serialized)
struct CompanionPhotosTests {
    func client() -> CompanionClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PhotosProtocol.self]
        return CompanionClient(baseURL: URL(string: "https://companion.example")!, apiKey: "al_synthetic_key",
                               session: URLSession(configuration: configuration))
    }

    @Test func readsTheTripsSummary() async throws {
        PhotosProtocol.seen = []
        let photos = try await client().photos(tripID: "4b2dbaf2-bdda-4b57-950f-386189c5d813")
        #expect(PhotosProtocol.seen.first?.path == "/v1/trips/4b2dbaf2-bdda-4b57-950f-386189c5d813/photos")
        #expect(photos.enabled && photos.cameraOffsetMinutes == 3)
        let day = try #require(photos.day(CalendarDate("2027-03-08")!))
        #expect(day.stopsText == "Wineglass Bay Lookout 3 · Sunset cruise 1 · between stops 2")
        #expect(day.countText == "6 photos · 1 not written")
        #expect(day.canUndo)
        #expect(photos.totalPhotos == 6)
    }

    @Test func turningOnSendsTheOffsetWithinRange() async throws {
        PhotosProtocol.seen = []
        _ = try await client().setPhotos(tripID: "trip-1", enabled: true, cameraOffsetMinutes: 5000)
        let sent = try #require(PhotosProtocol.seen.first)
        #expect(sent.method == "PUT")
        #expect(sent.body["enabled"] as? Bool == true)
        #expect(sent.body["cameraOffsetMinutes"] as? Int == 1440)
    }

    @Test func undoSendsTheDayAndReadsTheCounts() async throws {
        PhotosProtocol.seen = []
        let undo = try await client().undoPhotos(tripID: "trip-1", date: CalendarDate("2027-03-08")!)
        #expect(PhotosProtocol.seen.first?.path == "/v1/trips/trip-1/photos/undo")
        #expect(PhotosProtocol.seen.first?.body["date"] as? String == "2027-03-08")
        #expect(undo.restored == 5 && undo.kept == 1)
        #expect(undo.photos.days.count == 1)
    }

    @Test func aTripIDCantReachAnotherPath() async throws {
        PhotosProtocol.seen = []
        _ = try? await client().photos(tripID: "../../healthz?x=1")
        #expect(PhotosProtocol.seen.first?.path == "/v1/trips/healthzx1/photos")
    }

    @Test func aTripTheKeyCantSeeIsNotFound() async {
        await #expect(throws: APIError.self) { try await client().photos(tripID: "missing") }
    }

    @Test func offsetsReadTheWayPeopleSayThem() {
        #expect(TripPhotos.offsetText(0) == "On time")
        #expect(TripPhotos.offsetText(3) == "3 min slow")
        #expect(TripPhotos.offsetText(-65) == "1 h 5 min fast")
        #expect(TripPhotos.offsetText(120) == "2 h slow")
    }

    @Test func aDayWithNothingLeftCantBeUndone() {
        let day = TripPhotos.Day(date: CalendarDate("2027-03-08")!, photos: 0, undone: 4)
        #expect(!day.canUndo)
        #expect(day.countText == "0 photos · 4 undone")
        #expect(day.stopsText.isEmpty)
    }
}

@Suite("The companion's default address")
struct CompanionDefaultAddressTests {
    @Test func sitsBesideTheServer() {
        #expect(CompanionClient.defaultAddress(forServer: URL(string: "https://trips.example.com")!)?.absoluteString
                == "https://trips.example.com/companion")
        #expect(CompanionClient.defaultAddress(forServer: URL(string: "https://example.com/adventurelog/")!)?.absoluteString
                == "https://example.com/adventurelog/companion")
        #expect(CompanionClient.defaultAddress(forServer: URL(string: "https://trips.example.com:8443?x=1")!)?.absoluteString
                == "https://trips.example.com:8443/companion")
    }

    @Test func neverOverPlainHTTP() {
        #expect(CompanionClient.defaultAddress(forServer: URL(string: "http://192.0.2.10:8015")!) == nil)
    }

    @Test func readsWithoutItsScheme() {
        #expect(CompanionClient.displayAddress(URL(string: "https://trips.example.com/companion/")!) == "trips.example.com/companion")
    }
}
