import Foundation

/// Handle for accessing data scoped to a specific topic subscription.
public final class TopicClientHandle: @unchecked Sendable {

    /// The topic name.
    public let name: String

    private var _index: Int
    private let registry: KeyRegistry
    private let storeGet: (UInt32) -> DanValue
    private let log: ((String, Error?) -> Void)?

    private var onReceiveCallbacks = [(String, Any?) -> Void]()
    private var onUpdateCallbacks = [(TopicClientHandle) -> Void]()
    private var dirty = false
    private var cachedKeys: [String]?

    public init(
        name: String,
        index: Int,
        registry: KeyRegistry,
        storeGet: @escaping (UInt32) -> DanValue,
        log: ((String, Error?) -> Void)? = nil
    ) {
        self.name = name
        self._index = index
        self.registry = registry
        self.storeGet = storeGet
        self.log = log
    }

    /// Get the value for a key within this topic's namespace.
    public func get(_ key: String) -> Any? {
        let wirePath = "t.\(_index).\(key)"
        guard let entry = registry.getByPath(wirePath) else { return nil }
        return storeGet(entry.keyId).anyValue
    }

    /// Get the DanValue for a key within this topic's namespace.
    public func getValue(_ key: String) -> DanValue {
        let wirePath = "t.\(_index).\(key)"
        guard let entry = registry.getByPath(wirePath) else { return .null }
        return storeGet(entry.keyId)
    }

    /// All keys available for this topic (without the wire prefix).
    public var keys: [String] {
        if let cached = cachedKeys { return cached }
        let prefix = "t.\(_index)."
        var result = [String]()
        for path in registry.paths {
            if path.hasPrefix(prefix) {
                result.append(String(path.dropFirst(prefix.count)))
            }
        }
        cachedKeys = result
        return result
    }

    /// Register a callback for per-frame value updates.
    /// Returns a function to remove the registration.
    public func onReceive(_ cb: @escaping (String, Any?) -> Void) -> () -> Void {
        onReceiveCallbacks.append(cb)
        let index = onReceiveCallbacks.count - 1
        return { [weak self] in
            guard let self = self, index < self.onReceiveCallbacks.count else { return }
            self.onReceiveCallbacks.remove(at: index)
        }
    }

    /// Register a callback for batch-level updates (fires on ServerFlushEnd).
    /// Returns a function to remove the registration.
    public func onUpdate(_ cb: @escaping (TopicClientHandle) -> Void) -> () -> Void {
        onUpdateCallbacks.append(cb)
        let index = onUpdateCallbacks.count - 1
        return { [weak self] in
            guard let self = self, index < self.onUpdateCallbacks.count else { return }
            self.onUpdateCallbacks.remove(at: index)
        }
    }

    // MARK: - Internal

    /// Fire onReceive per-frame, mark dirty for batch onUpdate.
    func _notify(userKey: String, value: Any?) {
        for cb in onReceiveCallbacks {
            do {
                cb(userKey, value)
            } catch {
                log?("topic onReceive error", error)
            }
        }
        dirty = true
    }

    /// Fire onUpdate if dirty (called on SERVER_FLUSH_END).
    func _flushUpdate() {
        guard dirty, !onUpdateCallbacks.isEmpty else { return }
        dirty = false
        for cb in onUpdateCallbacks {
            do {
                cb(self)
            } catch {
                log?("topic onUpdate error", error)
            }
        }
    }

    var _idx: Int { _index }

    /// Update wire index.
    func _setIndex(_ index: Int) {
        _index = index
        cachedKeys = nil
    }
}
