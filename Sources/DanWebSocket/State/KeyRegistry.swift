import Foundation

/// Entry in the key registry mapping keyId to path.
public struct KeyEntry: Sendable {
    public let path: String
    public let type: DataType
    public let keyId: UInt32
}

/// Thread-safe registry mapping key IDs to key paths and vice versa.
public final class KeyRegistry: @unchecked Sendable {
    private var byId = [UInt32: KeyEntry]()
    private var byPath = [String: KeyEntry]()
    private var nextId: UInt32 = 1
    private var cachedPaths: [String]?
    private let maxKeys: Int

    private static let keyPathRegex = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)*$")
    private static let maxKeyPathBytes = 200

    public init(maxKeys: Int = 10_000) {
        self.maxKeys = maxKeys
    }

    /// Validate a key path according to protocol rules.
    public static func validateKeyPath(_ path: String) throws {
        if path.isEmpty {
            throw DanWSError("INVALID_KEY_PATH", "Key path must not be empty")
        }
        let range = NSRange(path.startIndex..., in: path)
        if keyPathRegex.firstMatch(in: path, range: range) == nil {
            throw DanWSError("INVALID_KEY_PATH", "Invalid key path: \"\(path)\"")
        }
        if path.utf8.count > maxKeyPathBytes {
            throw DanWSError("INVALID_KEY_PATH", "Key path exceeds 200 bytes: \"\(path)\"")
        }
    }

    /// Register a single key with a specific keyId (used for receiving remote registrations).
    public func registerOne(keyId: UInt32, path: String, type: DataType) {
        let entry = KeyEntry(path: path, type: type, keyId: keyId)
        byId[keyId] = entry
        byPath[path] = entry
        if keyId >= nextId {
            nextId = keyId + 1
        }
        cachedPaths = nil
    }

    /// Look up a key entry by its ID.
    public func getByKeyId(_ keyId: UInt32) -> KeyEntry? {
        byId[keyId]
    }

    /// Look up a key entry by its path.
    public func getByPath(_ path: String) -> KeyEntry? {
        byPath[path]
    }

    /// Check if a key ID is registered.
    public func hasKeyId(_ keyId: UInt32) -> Bool {
        byId[keyId] != nil
    }

    /// Check if a key path is registered.
    public func hasPath(_ path: String) -> Bool {
        byPath[path] != nil
    }

    /// Remove a key by its ID.
    @discardableResult
    public func removeByKeyId(_ keyId: UInt32) -> Bool {
        guard let entry = byId.removeValue(forKey: keyId) else { return false }
        byPath.removeValue(forKey: entry.path)
        cachedPaths = nil
        return true
    }

    /// Number of registered keys.
    public var size: Int {
        byId.count
    }

    /// All registered key paths.
    public var paths: [String] {
        if let cached = cachedPaths { return cached }
        let result = Array(byPath.keys)
        cachedPaths = result
        return result
    }

    /// All key entries.
    public var entries: [KeyEntry] {
        Array(byId.values)
    }

    /// Clear all registered keys.
    public func clear() {
        byId.removeAll()
        byPath.removeAll()
        nextId = 1
        cachedPaths = nil
    }
}
