// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking  // URLSession on Linux
#endif

/// The self-hosted companion service (`Companion/` in this repository), which sends Live Activity
/// pushes. It authenticates the phone with the same AdventureLog API key the app uses.
public struct CompanionClient: Sendable {
    public enum Environment: String, Sendable {
        /// Builds from Xcode get their pushes through Apple's sandbox.
        case sandbox
        /// TestFlight and App Store builds.
        case production
    }

    public let baseURL: URL
    private let apiKey: String
    private let session: URLSession

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
    }

    /// Registers this phone, with its push-to-start token when it has one.
    /// - Returns: whether the companion holds a push-to-start token for this phone, so it can start
    ///   activities while the app is closed; `nil` from a companion too old to say.
    @discardableResult
    public func register(environment: Environment, startToken: Data?) async throws -> Bool? {
        var body = ["environment": environment.rawValue]
        if let startToken { body["startToken"] = Self.hex(startToken) }
        let data = try await send("POST", "v1/devices", body)
        struct Registered: Decodable { var canStart: Bool? }
        return (try? JSONDecoder().decode(Registered.self, from: data))?.canStart
    }

    /// Hands over a running activity's push token, so the companion can update and end it.
    public func setActivityToken(_ token: Data, tripID: String, rowID: String) async throws {
        try await send("PUT", "v1/activities", ["tripID": tripID, "rowID": rowID, "pushToken": Self.hex(token)])
    }

    /// Stops pushes to this phone, e.g. on sign-out.
    public func unregister() async throws {
        try await send("DELETE", "v1/devices", nil)
    }

    /// APNs tokens go over the wire as lowercase hex.
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    func request(_ method: String, _ path: String, _ body: [String: String]?) -> URLRequest {
        var root = baseURL.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        var request = URLRequest(url: URL(string: root + "/" + path) ?? baseURL)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    @discardableResult
    private func send(_ method: String, _ path: String, _ body: [String: String]?) async throws -> Data {
        let (data, response) = try await session.data(for: request(method, path, body))
        guard let http = response as? HTTPURLResponse else { throw APIError.transport(code: -1, description: "No HTTP response.") }
        guard (200..<300).contains(http.statusCode) else { throw APIError.from(status: http.statusCode, data: data) }
        return data
    }
}
