// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux
#endif

/// A thin, typed client for one AdventureLog server, authenticated with an API key.
///
/// Rules the server imposes (see Fixtures/adventurelog-v0.13.0/README.md):
/// - every path ends in `/` (a POST without it returns 500);
/// - the key goes in `X-API-Key`, and no session cookie may ride along or CSRF comes back.
public final class AdventureLogClient: Sendable {
    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    /// - Parameter baseURL: the server root that serves `/api/` and `/auth/`, e.g. `https://adventurelog.example`.
    public init(baseURL: URL, apiKey: String, session: URLSession = AdventureLogClient.makeSession()) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// An ephemeral session with cookies off, so a stray `sessionid` never re-enables CSRF.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        #if !canImport(FoundationNetworking)
        configuration.waitsForConnectivity = false  // read-only (and always false) on Linux
        #endif
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }

    /// Normalizes what a person types ("adventurelog.example", "https://host/") into a server root.
    /// Adds HTTPS if no scheme is supplied, removes trailing slashes, and preserves subpaths.
    /// Returns `nil` for empty input or a URL without an HTTP(S) scheme and host.
    public static func normalizedServerURL(_ text: String) -> URL? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains("://") { trimmed = "https://" + trimmed }
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http", url.host() != nil
        else { return nil }
        return url
    }

    // MARK: Requests

    /// Builds a request. `path` is relative to the server root and gets a trailing slash if missing.
    /// Adds the API key and disables cookies. A supplied body is sent as JSON without validation;
    /// nonempty `query` replaces existing query items. Falls back to `baseURL` if URL construction fails.
    public func makeRequest(_ method: String, _ path: String, query: [URLQueryItem] = [], body: Data? = nil) -> URLRequest {
        var relative = path.hasPrefix("/") ? String(path.dropFirst()) : path
        if !relative.hasSuffix("/") { relative += "/" }
        // Joined by hand: URL.appending(path:) adds a second slash to a path that already ends in one.
        var root = baseURL.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        var components = URLComponents(string: root + "/" + relative) ?? URLComponents()
        if !query.isEmpty { components.queryItems = query }
        let url = components.url ?? baseURL
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Returns the body of a 2xx HTTP response.
    /// - Throws: `APIError.transport` for URL loading errors or a non-HTTP response, and the
    ///   corresponding `APIError` for other statuses. Other session errors propagate unchanged.
    func data(for request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw APIError.transport(code: error.errorCode, description: error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw APIError.transport(code: -1, description: "No HTTP response.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.from(status: http.statusCode, data: data)
        }
        return data
    }

    /// Sends a request and decodes its body using AdventureLog wire conventions.
    /// - Throws: Request errors from `data(for:)`; `DecodingError` becomes `APIError.decoding`,
    ///   while other errors thrown during decoding propagate unchanged.
    func send<T: Decodable>(_ request: URLRequest, as type: T.Type = T.self) async throws -> T {
        let data = try await self.data(for: request)
        do {
            return try ALCoding.decoder().decode(T.self, from: data)
        } catch let error as DecodingError {
            throw APIError.decoding(Self.describe(error))
        }
    }

    /// Encodes a JSON request body using AdventureLog wire conventions; propagates encoding errors.
    func body<B: Encodable>(_ value: B) throws -> Data {
        try ALCoding.encoder().encode(value)
    }

    /// Describes a decoding failure with its dot-separated coding path.
    static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            context.codingPath.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "Missing \(key.stringValue) at \(path(context))."
        case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context))."
        @unknown default: return "\(error)"
        }
    }

    // MARK: Endpoints

    /// The signed-in user. Used to validate a server address and key at sign-in.
    /// - Throws: Request and response-decoding errors from `send(_:as:)`.
    public func currentUser() async throws -> User {
        try await send(makeRequest("GET", "auth/user-metadata/"))
    }

    /// Collections the user owns (not archived), unpaginated.
    /// - Throws: Request and response-decoding errors from `send(_:as:)`.
    public func ownedCollections() async throws -> [CollectionSummary] {
        try await send(makeRequest("GET", "api/collections/all/"))
    }

    /// Collections shared with the user. They never appear in the owned lists.
    /// - Throws: Request and response-decoding errors from `send(_:as:)`.
    public func sharedCollections() async throws -> [CollectionSummary] {
        try await send(makeRequest("GET", "api/collections/shared/"))
    }

    /// Everything in one trip, including its itinerary rows and day names.
    /// - Throws: Request and response-decoding errors from `send(_:as:)`.
    public func collection(id: String) async throws -> CollectionDetail {
        try await send(makeRequest("GET", "api/collections/\(id)/"))
    }

    /// Reorders rows and moves them between days. Returns the updated rows.
    /// - Throws: Request-body encoding errors, or request and response-decoding errors from `send(_:as:)`.
    public func reorderItinerary(_ request: ItineraryReorderRequest) async throws -> [ItineraryRow] {
        try await send(makeRequest("POST", "api/itineraries/reorder/", body: body(request)))
    }

    /// Places an object on a day or trip-wide.
    /// - Throws: Request-body encoding errors, or request and response-decoding errors from `send(_:as:)`.
    public func createItineraryRow(_ request: ItineraryCreateRequest) async throws -> ItineraryRow {
        try await send(makeRequest("POST", "api/itineraries/", body: body(request)))
    }

    /// Downloads protected media (images, attachments).
    /// - Parameter url: The media URL to request; the API key is sent only when it shares `baseURL`'s origin.
    /// - Throws: Request errors from `data(for:)`.
    public func media(at url: URL) async throws -> Data {
        try await data(for: mediaRequest(url))
    }

    func mediaRequest(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        if Self.sameOrigin(url, baseURL) {
            request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        }
        return request
    }

    /// Scheme, host and port all match (case-insensitively), treating a missing port as the scheme's default.
    static func sameOrigin(_ a: URL, _ b: URL) -> Bool {
        func origin(_ url: URL) -> (String, String, Int)? {
            guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased() else { return nil }
            let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
            return (scheme, host, port)
        }
        guard let x = origin(a), let y = origin(b) else { return false }
        return x == y
    }
}
