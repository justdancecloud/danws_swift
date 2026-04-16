import Foundation

/// Shared TX state for one principal.
/// All sessions of the same principal share this state.
public final class PrincipalTX: @unchecked Sendable {
    public let name: String
    private var nextKeyId: UInt32 = 1
    private var onValueSet: ((Frame) -> Void)?
    private var onKeysChanged: (() -> Void)?
    private var onIncrementalKey: ((Frame, Frame, Frame) -> Void)?
    private var cachedKeyFrames: [Frame]?
    private var flatState: FlatStateManager!

    init(name: String, maxValueSize: Int? = nil) {
        self.name = name
        self.flatState = FlatStateManager(cb: FlatStateCallbacks(
            allocateKeyId: { [weak self] in
                guard let self = self else { return 0 }
                let id = self.nextKeyId
                self.nextKeyId += 1
                return id
            },
            enqueue: { [weak self] frame in
                self?.onValueSet?(frame)
            },
            onResync: { [weak self] in
                self?.triggerResync()
            },
            wirePrefix: "",
            onIncrementalKey: { [weak self] kf, sf, vf in
                if let handler = self?.onIncrementalKey {
                    handler(kf, sf, vf)
                } else {
                    self?.triggerResync()
                }
            },
            onKeyStructureChange: { [weak self] in
                self?.cachedKeyFrames = nil
            },
            maxValueSize: maxValueSize
        ))
    }

    // MARK: - Internal Bindings

    func _onValue(_ fn: @escaping (Frame) -> Void) {
        onValueSet = fn
    }

    func _onResync(_ fn: @escaping () -> Void) {
        onKeysChanged = fn
    }

    func _onIncremental(_ fn: @escaping (Frame, Frame, Frame) -> Void) {
        onIncrementalKey = fn
    }

    // MARK: - Public API

    /// Set a key-value pair. Supports primitives and arrays/dictionaries (auto-flattened).
    public func set(_ key: String, _ value: Any?) {
        flatState.set(key, value)
    }

    /// Get the current value for a key.
    public func get(_ key: String) -> Any? {
        flatState.get(key)
    }

    /// All registered key paths.
    public var keys: [String] {
        flatState.keys
    }

    /// Clear a specific key or all keys.
    public func clear(_ key: String? = nil) {
        if let key = key {
            flatState.clear(key)
        } else {
            flatState.clear()
            nextKeyId = 1
        }
    }

    // MARK: - Internal Frame Building

    func _buildKeyFrames() -> [Frame] {
        if let cached = cachedKeyFrames { return cached }
        var frames = flatState.buildKeyFrames()
        frames.append(Frame.signal(.serverSync))
        cachedKeyFrames = frames
        return frames
    }

    func _buildValueFrames() -> [Frame] {
        flatState.buildValueFrames()
    }

    private func triggerResync() {
        cachedKeyFrames = nil
        onKeysChanged?()
    }
}

/// Manages all principals.
public final class PrincipalManager: @unchecked Sendable {
    private var principals = [String: PrincipalTX]()
    private var sessionCounts = [String: Int]()
    private var onNewPrincipal: ((PrincipalTX) -> Void)?
    private var maxValueSize: Int?

    func _setOnNewPrincipal(_ fn: @escaping (PrincipalTX) -> Void) {
        onNewPrincipal = fn
    }

    func _setMaxValueSize(_ size: Int) {
        maxValueSize = size
    }

    public var size: Int { principals.count }

    public func principal(_ name: String) -> PrincipalTX {
        if let ptx = principals[name] { return ptx }
        let ptx = PrincipalTX(name: name, maxValueSize: maxValueSize)
        principals[name] = ptx
        onNewPrincipal?(ptx)
        return ptx
    }

    public var principalNames: [String] {
        sessionCounts.compactMap { $0.value > 0 ? $0.key : nil }
    }

    public func has(_ name: String) -> Bool {
        principals[name] != nil
    }

    public func get(_ name: String) -> PrincipalTX? {
        principals[name]
    }

    public func delete(_ name: String) {
        principals.removeValue(forKey: name)
        sessionCounts.removeValue(forKey: name)
    }

    public func clearAll() {
        principals.removeAll()
        sessionCounts.removeAll()
    }

    func _addSession(_ principal: String) {
        sessionCounts[principal] = (sessionCounts[principal] ?? 0) + 1
    }

    /// Returns true when session count reaches 0.
    @discardableResult
    func _removeSession(_ principal: String) -> Bool {
        let count = (sessionCounts[principal] ?? 1) - 1
        if count <= 0 {
            sessionCounts.removeValue(forKey: principal)
            return true
        }
        sessionCounts[principal] = count
        return false
    }

    func _hasActiveSessions(_ principal: String) -> Bool {
        (sessionCounts[principal] ?? 0) > 0
    }
}
