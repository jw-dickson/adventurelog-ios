// AdventureLog for iOS — Copyright (C) 2026 the AdventureLog iOS contributors. GPL-3.0-or-later.

/// Decodes a collection that the server may omit or send as `null` as an empty collection.
///
/// AdventureLog leaves arrays out of some representations (for example `?nested=true`
/// collection detail drops `visits`), so every array on a model uses this wrapper.
@propertyWrapper
public struct DefaultEmpty<Value>: Sendable, Hashable
where Value: RangeReplaceableCollection & Codable & Sendable & Hashable {
    public var wrappedValue: Value

    public init(wrappedValue: Value = Value()) {
        self.wrappedValue = wrappedValue
    }
}

extension DefaultEmpty: Codable {
    /// Decodes `null` as an empty collection; propagates errors when decoding a non-null value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            wrappedValue = Value()
        } else {
            wrappedValue = try container.decode(Value.self)
        }
    }

    /// Encodes the wrapped collection, including when empty; propagates encoder errors.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }
}

extension KeyedDecodingContainer {
    /// Missing or null values decode to an empty collection instead of throwing `keyNotFound`.
    /// Errors decoding a present, non-null value propagate to the caller.
    public func decode<V>(_ type: DefaultEmpty<V>.Type, forKey key: Key) throws -> DefaultEmpty<V> {
        try decodeIfPresent(type, forKey: key) ?? DefaultEmpty()
    }
}
