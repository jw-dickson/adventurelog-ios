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
