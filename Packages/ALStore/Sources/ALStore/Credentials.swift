// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

import Foundation
import Security

/// Where and as whom the app talks to AdventureLog.
public struct ServerCredentials: Codable, Sendable, Hashable {
    public var serverURL: URL
    public var apiKey: String
    /// Remembered so the app can greet the user and show the account while offline.
    public var username: String?
    public var displayName: String?
    /// The id of the key, when the app made it at sign-in, so signing out can revoke it.
    /// `nil` for a key the person pasted in, which stays theirs to manage.
    public var apiKeyID: String?

    public init(serverURL: URL, apiKey: String, username: String? = nil, displayName: String? = nil, apiKeyID: String? = nil) {
        self.serverURL = serverURL
        self.apiKey = apiKey
        self.username = username
        self.displayName = displayName
        self.apiKeyID = apiKeyID
    }
}

public protocol CredentialStore: Sendable {
    func load() throws -> ServerCredentials?
    func save(_ credentials: ServerCredentials) throws
    func clear() throws
}

public struct KeychainError: Error, LocalizedError, Sendable, Equatable, CustomStringConvertible {
    public let status: OSStatus
    public var description: String {
        let text = (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error"
        return "\(text) (\(status))"
    }
    public var errorDescription: String? { description }
}

/// Stores credentials as one generic-password item, readable after first unlock so background
/// sync and location tasks can reach the server while the phone is locked.
public struct KeychainCredentialStore: CredentialStore {
    public let service: String
    public let account: String

    /// Selects the keychain item identified by `service` and `account`; performs no keychain access.
    public init(service: String = "app.adventurelog.ios.credentials", account: String = "default") {
        self.service = service
        self.account = account
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    /// Returns stored credentials, or `nil` when the keychain item does not exist.
    /// - Throws: `KeychainError` for lookup or data retrieval failures, or JSON decoding errors.
    public func load() throws -> ServerCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return try JSONDecoder().decode(ServerCredentials.self, from: data)
    }

    /// Stores credentials accessible after first unlock on this device, updating the existing item
    /// in place (or adding one), so a failure leaves the previous credentials intact.
    /// - Throws: JSON encoding errors or `KeychainError` from the update or insertion.
    public func save(_ credentials: ServerCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let values: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            let attributes = baseQuery.merging(values) { $1 }
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    /// Deletes the selected item; succeeds if it is already absent.
    /// - Throws: `KeychainError` if deletion fails.
    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// For tests, previews and UI-test launches.
public final class InMemoryCredentialStore: CredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var value: ServerCredentials?

    public init(_ initial: ServerCredentials? = nil) {
        value = initial
    }

    public func load() throws -> ServerCredentials? {
        lock.withLock { value }
    }

    public func save(_ credentials: ServerCredentials) throws {
        lock.withLock { value = credentials }
    }

    public func clear() throws {
        lock.withLock { value = nil }
    }
}
