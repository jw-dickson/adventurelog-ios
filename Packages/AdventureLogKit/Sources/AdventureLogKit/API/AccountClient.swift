// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A sign-in method the server offers besides a password: GitHub, or an OpenID Connect provider
/// such as Authentik (`GET /auth/social-providers/`).
public struct SocialProvider: Codable, Sendable, Hashable, Identifiable {
    /// `openid_connect`, `github`, …
    public var provider: String
    /// Where the provider's sign-in starts, on the server (`…/accounts/oidc/<id>/login/`).
    public var url: URL
    public var name: String
    /// The server only allows provider sign-in (`FORCE_SOCIALACCOUNT_LOGIN`).
    public var usageRequired: Bool?

    public var id: String { url.absoluteString }

    /// The sign-in URL on the address the person typed. The server builds `url` from its
    /// `PUBLIC_URL`, which can be unset or an internal name; the path is what matters.
    public func startURL(on server: URL) -> URL {
        let path = url.path()
        guard let range = path.range(of: "/accounts/") else { return url }
        var root = server.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        return URL(string: root + String(path[range.lowerBound...])) ?? url
    }
}

/// What the server's account settings say about signing in (`GET /auth/app/v1/config`).
public struct AccountConfig: Sendable, Hashable {
    /// `username`, `email` or `username_email`.
    public var authenticationMethod: String
    public var mfaTypes: [String]
}

/// The result of a password sign-in.
public enum LoginStep: Sendable, Hashable {
    /// Signed in: the session token to use for the next calls.
    case signedIn(sessionToken: String)
    /// Two-factor authentication is on: send a code with this pending session token.
    case needsCode(sessionToken: String)
}

/// An API key the server just made. `key` is shown once and never again.
public struct CreatedAPIKey: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var key: String
}

/// Why signing in didn't work, in the server's words where it gave some.
public enum AccountError: Error, Sendable, Equatable, LocalizedError {
    case rejected(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .rejected(let message): return message
        case .unexpected(let message): return "Unexpected response from the server. \(message)"
        }
    }
}

/// Signs in to AdventureLog the way its own web app does, through django-allauth's headless API,
/// then makes an API key for this phone so the rest of the app keeps working offline indefinitely.
///
/// AdventureLog accepts allauth's app session token as `X-Session-Token` on every endpoint and
/// skips CSRF for it (`adventures/middleware.py`), so no cookies are involved. allauth's paths have
/// no trailing slash; AdventureLog's own (`auth/api-keys/`) do.
public struct AccountClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = AdventureLogClient.makeSession()) {
        self.baseURL = baseURL
        self.session = session
    }

    // MARK: Before signing in

    /// The server's sign-in providers, for "Continue with …" buttons. Empty when none are set up.
    public func socialProviders() async throws -> [SocialProvider] {
        let data = try await send(request("GET", "auth/social-providers/"))
        do {
            return try ALCoding.decoder().decode([SocialProvider].self, from: data)
        } catch {
            throw AccountError.unexpected("The provider list couldn't be read.")
        }
    }

    public func config() async throws -> AccountConfig {
        let data = try await send(request("GET", "auth/app/v1/config"))
        guard let object = Self.json(data), let body = object["data"] as? [String: Any] else {
            throw AccountError.unexpected("The sign-in settings couldn't be read.")
        }
        let account = body["account"] as? [String: Any]
        let mfa = body["mfa"] as? [String: Any]
        return AccountConfig(authenticationMethod: account?["authentication_method"] as? String ?? "username",
                             mfaTypes: mfa?["supported_types"] as? [String] ?? [])
    }

    // MARK: Signing in

    /// Signs in with a username (or email) and password.
    /// - Parameter method: the server's `authenticationMethod`; decides whether `login` goes as
    ///   `username` or `email`.
    public func logIn(_ login: String, password: String, method: String = "username") async throws -> LoginStep {
        let login = login.trimmingCharacters(in: .whitespacesAndNewlines)
        let useEmail = method == "email" || (method == "username_email" && login.contains("@"))
        let body = [useEmail ? "email" : "username": login, "password": password]
        let (data, status) = try await exchange(request("POST", "auth/app/v1/auth/login", json: body))
        return try Self.step(from: data, status: status)
    }

    /// Sends a two-factor code (an authenticator code or a recovery code) for a pending sign-in.
    public func submitCode(_ code: String, sessionToken: String) async throws -> String {
        let body = ["code": code.filter { !$0.isWhitespace }]
        let (data, status) = try await exchange(request("POST", "auth/app/v1/auth/2fa/authenticate", json: body, token: sessionToken))
        switch try Self.step(from: data, status: status) {
        case .signedIn(let token): return token
        case .needsCode: throw AccountError.rejected("That code didn't work. Try the newest one from your authenticator app.")
        }
    }

    /// Whether `sessionToken` belongs to a signed-in session. Used to recognise the end of a
    /// provider sign-in in the web sheet, where the session cookie exists before the person has
    /// signed in.
    public func isSignedIn(sessionToken: String) async -> Bool {
        guard let (_, status) = try? await exchange(request("GET", "auth/app/v1/auth/session", token: sessionToken)) else { return false }
        return status == 200
    }

    /// Makes an API key for this phone.
    public func createAPIKey(named name: String, sessionToken: String) async throws -> CreatedAPIKey {
        let data = try await send(request("POST", "auth/api-keys/", json: ["name": name], token: sessionToken))
        do {
            return try ALCoding.decoder().decode(CreatedAPIKey.self, from: data)
        } catch {
            throw AccountError.unexpected("The new API key couldn't be read.")
        }
    }

    /// Ends the sign-in session once the API key exists. Best effort: the session expires anyway.
    public func endSession(_ sessionToken: String) async {
        _ = try? await exchange(request("DELETE", "auth/app/v1/auth/session", token: sessionToken))
    }

    // MARK: Plumbing

    func request(_ method: String, _ path: String, json: [String: String]? = nil, token: String? = nil) -> URLRequest {
        var root = baseURL.absoluteString
        while root.hasSuffix("/") { root.removeLast() }
        var request = URLRequest(url: URL(string: root + "/" + path) ?? baseURL)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue(token, forHTTPHeaderField: "X-Session-Token") }
        if let json {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func exchange(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw APIError.transport(code: -1, description: "No HTTP response.") }
            return (data, http.statusCode)
        } catch let error as URLError {
            throw APIError.transport(code: error.errorCode, description: error.localizedDescription)
        }
    }

    /// The body of a 2xx response; anything else becomes an error with the server's message.
    private func send(_ request: URLRequest) async throws -> Data {
        let (data, status) = try await exchange(request)
        guard (200..<300).contains(status) else { throw Self.error(from: data, status: status) }
        return data
    }

    static func json(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Reads allauth's `{status, data, meta}` envelope.
    static func step(from data: Data, status: Int) throws -> LoginStep {
        let object = json(data)
        let meta = object?["meta"] as? [String: Any]
        let token = meta?["session_token"] as? String
        if status == 200, meta?["is_authenticated"] as? Bool == true, let token {
            return .signedIn(sessionToken: token)
        }
        if status == 401, let token,
           let flows = (object?["data"] as? [String: Any])?["flows"] as? [[String: Any]],
           flows.contains(where: { $0["id"] as? String == "mfa_authenticate" && $0["is_pending"] as? Bool == true }) {
            return .needsCode(sessionToken: token)
        }
        throw error(from: data, status: status)
    }

    /// allauth's `{"errors": [{"message": …}]}`, DRF's `{"detail": …}`, or the status.
    static func error(from data: Data, status: Int) -> Error {
        if let errors = json(data)?["errors"] as? [[String: Any]],
           let message = errors.compactMap({ $0["message"] as? String }).first {
            return AccountError.rejected(message)
        }
        switch status {
        case 401: return AccountError.rejected("The server didn't accept that sign-in.")
        case 404: return AccountError.rejected("This server doesn't offer sign-in for apps. It needs AdventureLog 0.13 or later.")
        case 429: return AccountError.rejected("Too many attempts. Wait a minute and try again.")
        default: return APIError.from(status: status, data: data)
        }
    }
}

extension AdventureLogClient {
    /// Revokes an API key, such as this phone's own on sign-out.
    /// - Throws: Request errors from `data(for:)`.
    public func deleteAPIKey(id: String) async throws {
        _ = try await data(for: makeRequest("DELETE", "auth/api-keys/\(id)/"))
    }
}
