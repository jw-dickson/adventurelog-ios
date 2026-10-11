// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Testing
@testable import AdventureLogKit

/// Answers like AdventureLog's allauth headless API, as checked against the test server on
/// 2026-10-11 (password, two-factor, session token, API key).
private final class AllauthProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    private func body() -> [String: String] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
    }

    override func startLoading() {
        let url = request.url!
        let token = request.value(forHTTPHeaderField: "X-Session-Token")
        let reply: (Int, String)
        if request.httpShouldHandleCookies || request.value(forHTTPHeaderField: "X-API-Key") != nil {
            reply = (400, #"{"detail":"no cookies or keys expected"}"#)
        } else {
            switch (request.httpMethod ?? "", url.path()) {
            case ("GET", "/auth/social-providers/"):
                reply = (200, #"[{"provider":"openid_connect","url":"None/accounts/oidc/authentik/login/","name":"Authentik","usage_required":false}]"#)
            case ("GET", "/auth/app/v1/config"):
                reply = (200, #"{"status":200,"data":{"account":{"authentication_method":"username"},"socialaccount":{"providers":[]},"mfa":{"supported_types":["recovery_codes","totp"]}}}"#)
            case ("POST", "/auth/app/v1/auth/login"):
                let body = body()
                if body["username"] == "alex", body["password"] == "right" {
                    reply = (200, #"{"status":200,"data":{"user":{"username":"alex"}},"meta":{"is_authenticated":true,"session_token":"t1"}}"#)
                } else if body["username"] == "sam", body["password"] == "right" {
                    reply = (401, #"{"status":401,"data":{"flows":[{"id":"login"},{"id":"mfa_authenticate","is_pending":true}]},"meta":{"is_authenticated":false,"session_token":"p1"}}"#)
                } else if body["email"] == "alex@example.com" {
                    reply = (200, #"{"status":200,"data":{},"meta":{"is_authenticated":true,"session_token":"t3"}}"#)
                } else {
                    reply = (400, #"{"status":400,"errors":[{"message":"The username and/or password you specified are not correct.","code":"username_password_mismatch","param":"password"}]}"#)
                }
            case ("POST", "/auth/app/v1/auth/2fa/authenticate"):
                reply = token == "p1" && body()["code"] == "123456"
                    ? (200, #"{"status":200,"data":{},"meta":{"is_authenticated":true,"session_token":"t2"}}"#)
                    : (400, #"{"status":400,"errors":[{"message":"Incorrect code.","code":"incorrect_code","param":"code"}]}"#)
            case ("GET", "/auth/app/v1/auth/session"):
                reply = token == "t1" ? (200, #"{"status":200,"meta":{"is_authenticated":true}}"#) : (401, #"{"status":401,"meta":{"is_authenticated":false}}"#)
            case ("POST", "/auth/api-keys/"):
                reply = token == "t1"
                    ? (201, #"{"id":"k1","name":"\#(body()["name"] ?? "")","key_prefix":"al_new","created_at":"2026-10-11T17:00:00Z","key":"al_newkey"}"#)
                    : (401, #"{"detail":"Authentication credentials were not provided."}"#)
            case ("DELETE", "/auth/app/v1/auth/session"):
                reply = (401, #"{"status":401,"data":{"flows":[{"id":"login"}]},"meta":{"is_authenticated":false}}"#)
            default:
                reply = (404, #"{"detail":"Not found."}"#)
            }
        }
        let response = HTTPURLResponse(url: url, statusCode: reply.0, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// A server behind a single sign-on proxy (forward auth): requests that carry a session token
/// reach AdventureLog; the rest are redirected to the proxy's login page and get HTML.
private final class SignOnProxyProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        if request.value(forHTTPHeaderField: "X-Session-Token") == "t1" {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"status":200,"meta":{"is_authenticated":true}}"#.utf8))
        } else {
            // What URLSession hands back after following the proxy's 302.
            let login = URL(string: "https://sso.example/flows/default-authentication-flow/?next=\(url.path())")!
            let response = HTTPURLResponse(url: login, statusCode: 200, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/html; charset=utf-8"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("<!doctype html><title>Sign in</title>".utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("Signing in with an account")
struct AccountClientTests {
    let account: AccountClient = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AllauthProtocol.self]
        configuration.httpShouldSetCookies = false
        return AccountClient(baseURL: URL(string: "https://adventurelog.example/")!, session: URLSession(configuration: configuration))
    }()

    @Test func aPasswordSignInGivesASessionThatMakesAKey() async throws {
        let step = try await account.logIn(" alex ", password: "right")
        #expect(step == .signedIn(sessionToken: "t1"))
        #expect(await account.isSignedIn(sessionToken: "t1"))
        let key = try await account.createAPIKey(named: "AdventureLog iOS · 11 Oct 2026", sessionToken: "t1")
        #expect(key == CreatedAPIKey(id: "k1", name: "AdventureLog iOS · 11 Oct 2026", key: "al_newkey"))
        await account.endSession("t1") // a 401 afterwards is allauth's normal answer
    }

    @Test func twoFactorAsksForACodeThenSignsIn() async throws {
        let step = try await account.logIn("sam", password: "right")
        #expect(step == .needsCode(sessionToken: "p1"))
        #expect(await account.isSignedIn(sessionToken: "p1") == false)
        await #expect(throws: AccountError.rejected("Incorrect code.")) {
            try await account.submitCode("000000", sessionToken: "p1")
        }
        #expect(try await account.submitCode("123 456", sessionToken: "p1") == "t2")
    }

    @Test func aWrongPasswordShowsTheServersMessage() async {
        await #expect(throws: AccountError.rejected("The username and/or password you specified are not correct.")) {
            try await account.logIn("alex", password: "wrong")
        }
    }

    @Test func emailOrUsernameFollowsTheServersSetting() async throws {
        #expect(try await account.logIn("alex@example.com", password: "x", method: "username_email") == .signedIn(sessionToken: "t3"))
        #expect(try await account.logIn("alex@example.com", password: "x", method: "email") == .signedIn(sessionToken: "t3"))
        await #expect(throws: AccountError.self) {
            try await account.logIn("alex@example.com", password: "x", method: "username")
        }
    }

    @Test func configAndProviders() async throws {
        let config = try await account.config()
        #expect(config.authenticationMethod == "username")
        #expect(config.mfaTypes == ["recovery_codes", "totp"])
        let providers = try await account.socialProviders()
        #expect(providers.map(\.name) == ["Authentik"])
        // The server builds the URL from PUBLIC_URL, which here is unset ("None").
        #expect(providers[0].startURL(on: URL(string: "https://trips.example/")!).absoluteString
                == "https://trips.example/accounts/oidc/authentik/login/")
    }

    @Test func allauthPathsHaveNoTrailingSlash() {
        #expect(account.request("POST", "auth/app/v1/auth/login").url?.absoluteString == "https://adventurelog.example/auth/app/v1/auth/login")
        let request = account.request("GET", "auth/app/v1/auth/session", token: "t")
        #expect(request.value(forHTTPHeaderField: "X-Session-Token") == "t")
        #expect(request.httpShouldHandleCookies == false)
    }

    /// Issue #9: behind a sign-on proxy, discovery and password sign-in meet its login page.
    @Test func aSignOnProxyIsRecognisedNotMisread() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SignOnProxyProtocol.self]
        let proxied = AccountClient(baseURL: URL(string: "https://adventurelog.example/")!, session: URLSession(configuration: configuration))
        await #expect(throws: AccountError.singleSignOn) { try await proxied.socialProviders() }
        await #expect(throws: AccountError.singleSignOn) { try await proxied.config() }
        await #expect(throws: AccountError.singleSignOn) { try await proxied.logIn("alex", password: "right") }
        // With the session from the web sheet, AdventureLog itself answers.
        #expect(await proxied.isSignedIn(sessionToken: "t1"))
        #expect(await proxied.isSignedIn(sessionToken: "nope") == false)
    }

    @Test func oldServersSayWhy() {
        let error = AccountClient.error(from: Data(#"{"detail":"Not found."}"#.utf8), status: 404)
        #expect(error.localizedDescription.contains("0.13"))
    }
}
