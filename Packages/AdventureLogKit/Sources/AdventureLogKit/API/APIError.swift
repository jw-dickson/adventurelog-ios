// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation

/// A server message decoded leniently from any of AdventureLog's three error shapes:
/// `{"detail": "…"}`, `{"error": "…"}`, or DRF validation `{"field": ["…"]}`, where a
/// field's value is sometimes a bare string instead of a list.
public struct ServerMessage: Sendable, Hashable {
    /// One human-readable line.
    public var summary: String
    /// Field-level validation messages, empty for `detail`/`error` bodies.
    public var fields: [String: [String]]

    public init(summary: String, fields: [String: [String]] = [:]) {
        self.summary = summary
        self.fields = fields
    }

    /// Extracts a message and any field errors from JSON, or uses a non-HTML UTF-8 body as text.
    /// Undecodable, empty, HTML, or unsupported bodies fall back to the localized HTTP status text.
    public init(data: Data, status: Int) {
        let fallback = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        guard let object = try? JSONSerialization.jsonObject(with: data) else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.init(summary: text.isEmpty || text.hasPrefix("<") ? fallback : text)
            return
        }
        if let text = object as? String {
            self.init(summary: text)
            return
        }
        guard let dictionary = object as? [String: Any] else {
            self.init(summary: fallback)
            return
        }
        for key in ["detail", "error", "message"] {
            if let text = dictionary[key] as? String {
                self.init(summary: text)
                return
            }
        }
        var fields: [String: [String]] = [:]
        for (key, value) in dictionary {
            if let text = value as? String {
                fields[key] = [text]
            } else if let list = value as? [Any] {
                fields[key] = list.map { "\($0)" }
            } else {
                fields[key] = ["\(value)"]
            }
        }
        let summary = fields.keys.sorted().compactMap { key -> String? in
            guard let first = fields[key]?.first else { return nil }
            return key == "non_field_errors" ? first : "\(key): \(first)"
        }.joined(separator: "\n")
        self.init(summary: summary.isEmpty ? fallback : summary, fields: fields)
    }
}

public enum APIError: Error, Sendable, Equatable, LocalizedError {
    /// 401: missing, wrong or revoked API key.
    case unauthorized(ServerMessage)
    /// 402: AdventureLog Cloud subscription required.
    case subscriptionRequired(ServerMessage)
    /// 403.
    case forbidden(ServerMessage)
    /// 404. AdventureLog also answers 404 for other users' unshared objects.
    case notFound(ServerMessage)
    /// 400 validation errors.
    case invalid(ServerMessage)
    /// Any other non-2xx status.
    case server(status: Int, ServerMessage)
    /// No usable response: offline, DNS, TLS, timeout.
    case transport(code: Int, description: String)
    /// The response did not match the expected shape.
    case decoding(String)
    /// The configured server address is not a usable URL.
    case badServerURL

    public var errorDescription: String? {
        switch self {
        case .unauthorized(let m), .subscriptionRequired(let m), .forbidden(let m), .notFound(let m), .invalid(let m):
            return m.summary
        case .server(let status, let m):
            return "Server error \(status): \(m.summary)"
        case .transport(_, let description):
            return description
        case .decoding(let description):
            return "Unexpected response from the server. \(description)"
        case .badServerURL:
            return "That doesn't look like a server address."
        }
    }

    /// True when the request may succeed if retried later (offline, timeouts, 5xx).
    public var isTransient: Bool {
        switch self {
        case .transport: return true
        case .server(let status, _): return status >= 500
        default: return false
        }
    }

    /// Maps 400–404 to their specific error cases; all other statuses become `.server`.
    static func from(status: Int, data: Data) -> APIError {
        let message = ServerMessage(data: data, status: status)
        switch status {
        case 400: return .invalid(message)
        case 401: return .unauthorized(message)
        case 402: return .subscriptionRequired(message)
        case 403: return .forbidden(message)
        case 404: return .notFound(message)
        default: return .server(status: status, message)
        }
    }
}
