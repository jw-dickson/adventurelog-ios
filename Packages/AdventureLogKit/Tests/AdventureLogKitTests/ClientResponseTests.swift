// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux
#endif
import Testing
@testable import AdventureLogKit

/// Each response is selected by the request itself: no shared handler to race between tests.
private final class ResponseProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.path ?? ""
        let isWrite = ["/api/itineraries/", "/api/itineraries/reorder/"].contains(path)
        guard request.value(forHTTPHeaderField: "X-API-Key") == "al_test",
              request.httpMethod == (isWrite ? "POST" : "GET"), !request.httpShouldHandleCookies else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if url.host() == "offline.example" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        if url.host() == "non-http.example" {
            let response = URLResponse(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let status = Int(url.lastPathComponent) ?? 200
        let body: Data
        do {
            switch path {
            case "/auth/user-metadata/": body = try Fixture.data("responses", "auth__user-metadata.json")
            case "/api/collections/all/": body = try Fixture.data("responses", "collections__all.json")
            case "/api/collections/shared/": body = try Fixture.data("responses", "collections__shared__as_guest.json")
            case "/api/collections/trip/": body = try Fixture.data("responses", "collections__detail.json")
            case "/api/itineraries/":
                let row = try Fixture.decodeWrapped(ItineraryRow.self, "itineraries__create_response__d1_note.json")
                body = try ALCoding.encoder().encode(row)
            case "/api/itineraries/reorder/":
                let rows = try Fixture.decodeWrapped([ItineraryRow].self, "itineraries__reorder_response__to_global.json")
                body = try ALCoding.encoder().encode(rows)
            case "/media/photo/": body = Data([0, 255, 1, 128])
            case "/malformed/": body = Data(#"{"uuid":"u","username":42}"#.utf8)
            case "/empty/": body = Data()
            default: body = Data(#"{"detail":"Request rejected"}"#.utf8)
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: status == 204 ? Data() : body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Client responses without a live server")
struct ClientResponseTests {
    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResponseProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test func readEndpointsDecodeTheirResponseShapes() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = AdventureLogClient(baseURL: URL(string: "https://stub.example")!, apiKey: "al_test", session: session)
        let user = try await client.currentUser()
        let owned = try await client.ownedCollections()
        let shared = try await client.sharedCollections()
        let trip = try await client.collection(id: "trip")
        let expectedOwned = try Fixture.decode([CollectionSummary].self, name: "collections__all.json")
        let expectedShared = try Fixture.decode([CollectionSummary].self, name: "collections__shared__as_guest.json")
        let expectedTrip = try Fixture.trip()
        #expect(user.username == "admin")
        #expect(owned == expectedOwned)
        #expect(shared == expectedShared)
        #expect(trip == expectedTrip)
    }

    @Test(arguments: [200, 201, 204, 299])
    func acceptsTheEntireSuccessRange(_ status: Int) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = AdventureLogClient(baseURL: URL(string: "https://stub.example")!, apiKey: "al_test", session: session)
        let data = try await client.data(for: client.makeRequest("GET", "status/\(status)"))
        #expect(data == (status == 204 ? Data() : Data(#"{"detail":"Request rejected"}"#.utf8)))
    }

    @Test(arguments: [
        (400, APIError.invalid(ServerMessage(summary: "Request rejected"))),
        (401, .unauthorized(ServerMessage(summary: "Request rejected"))),
        (402, .subscriptionRequired(ServerMessage(summary: "Request rejected"))),
        (403, .forbidden(ServerMessage(summary: "Request rejected"))),
        (404, .notFound(ServerMessage(summary: "Request rejected"))),
        (429, .server(status: 429, ServerMessage(summary: "Request rejected"))),
        (500, .server(status: 500, ServerMessage(summary: "Request rejected"))),
        (503, .server(status: 503, ServerMessage(summary: "Request rejected"))),
    ])
    func rejectsHTTPFailuresBeforeDecoding(_ status: Int, _ expected: APIError) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = AdventureLogClient(baseURL: URL(string: "https://stub.example")!, apiKey: "al_test", session: session)
        do {
            _ = try await client.send(client.makeRequest("GET", "status/\(status)"), as: User.self)
            Issue.record("Expected HTTP failure \(status)")
        } catch let error as APIError {
            #expect(error == expected)
            #expect(error.isTransient == (status >= 500))
        }
    }

    @Test(arguments: ["malformed", "empty"])
    func successfulButInvalidBodiesProduceDecodingErrors(_ path: String) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = AdventureLogClient(baseURL: URL(string: "https://stub.example")!, apiKey: "al_test", session: session)
        do {
            _ = try await client.send(client.makeRequest("GET", path), as: User.self)
            Issue.record("Expected a decoding error")
        } catch let error as APIError {
            guard case .decoding(let description) = error else {
                Issue.record("Expected .decoding, got \(error)")
                return
            }
            #expect(!error.isTransient)
            #expect(!description.isEmpty)
            if path == "malformed" { #expect(description.contains("username")) }
        }
    }

    @Test(arguments: [("offline.example", URLError.notConnectedToInternet.rawValue), ("non-http.example", -1)])
    func unusableResponsesBecomeTransientTransportErrors(_ host: String, _ code: Int) async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = AdventureLogClient(baseURL: URL(string: "https://\(host)")!, apiKey: "al_test", session: session)
        do {
            _ = try await client.currentUser()
            Issue.record("Expected a transport error")
        } catch let error as APIError {
            guard case .transport(let actualCode, let description) = error else {
                Issue.record("Expected .transport, got \(error)")
                return
            }
            #expect(actualCode == code)
            #expect(!description.isEmpty)
            #expect(error.isTransient)
        }
    }

    @Test func mediaReturnsUnmodifiedBinaryData() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = AdventureLogClient(baseURL: URL(string: "https://stub.example")!, apiKey: "al_test", session: session)
        let data = try await client.media(at: URL(string: "https://stub.example/media/photo/")!)
        #expect(data == Data([0, 255, 1, 128]))
    }

    @Test func writeEndpointsDecodeCreatedAndReorderedRows() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = AdventureLogClient(baseURL: URL(string: "https://stub.example")!, apiKey: "al_test", session: session)
        let expectedRow = try Fixture.decodeWrapped(ItineraryRow.self, "itineraries__create_response__d1_note.json")
        let create = ItineraryCreateRequest(collection: expectedRow.collection, kind: .note, objectId: expectedRow.objectId, date: expectedRow.date, order: expectedRow.order)
        let created = try await client.createItineraryRow(create)
        #expect(created == expectedRow)

        let expectedRows = try Fixture.decodeWrapped([ItineraryRow].self, "itineraries__reorder_response__to_global.json")
        let reorder = ItineraryReorderRequest(items: expectedRows.map { .init(id: $0.id, date: $0.date, order: $0.order) })
        let reordered = try await client.reorderItinerary(reorder)
        #expect(reordered == expectedRows)
    }

    @Test func defaultSessionDisablesCookieAcceptance() {
        let session = AdventureLogClient.makeSession()
        defer { session.invalidateAndCancel() }
        #expect(!session.configuration.httpShouldSetCookies)
        #expect(session.configuration.httpCookieAcceptPolicy == .never)
        #expect(!session.configuration.waitsForConnectivity)
    }
}
