import Foundation

/// Session states for server-side sessions.
public enum SessionState: String, Sendable {
    case pending
    case authorized
    case synchronizing
    case ready
    case disconnected
}

/// Represents a single client connection on the server side.
public final class DanWebSocketSession: @unchecked Sendable {

    /// Unique client identifier.
    public let id: String

    /// The principal assigned to this session.
    public private(set) var principal: String?

    /// Whether the session has been authorized.
    public private(set) var authorized: Bool = false

    /// Whether the session is currently connected.
    public private(set) var connected: Bool = true

    /// Current session state.
    public private(set) var state: SessionState = .pending

    private var enqueueFrame: ((Frame) -> Void)?

    // Callbacks
    private var onReadyCallbacks = [() -> Void]()
    private var onDisconnectCallbacks = [() -> Void]()
    private var onErrorCallbacks = [(DanWSError) -> Void]()

    // Provider for TX frames (from principal shared state)
    private var txKeyFrameProvider: (() -> [Frame])?
    private var txValueFrameProvider: (() -> [Frame])?
    private var txKeyFrameIndex: [UInt32: Frame]?
    private var txValueFrameIndex: [UInt32: Frame]?

    // Sync tracking
    private var serverSyncSent = false

    // Session-level flat TX store (topic modes)
    private var nextKeyId: UInt32 = 1
    private var sessionEnqueue: ((Frame) -> Void)?
    private var sessionBound = false
    private var flatState: FlatStateManager?

    // Topic handles
    private var topicHandles = [String: TopicHandle]()
    private var topicIndex = 0
    private var topics = [String: (name: String, params: [String: Any])]()

    // Size limits
    private var maxValueSize: Int?
    private var debug: Bool = false

    public init(_ clientUuid: String) {
        self.id = clientUuid
    }

    // MARK: - Event Registration

    /// Register a callback for when the session is ready (initial sync complete).
    @discardableResult
    public func onReady(_ cb: @escaping () -> Void) -> () -> Void {
        onReadyCallbacks.append(cb)
        return { [weak self] in
            self?.onReadyCallbacks.removeAll { $0 as AnyObject === cb as AnyObject }
        }
    }

    /// Register a callback for when the session disconnects.
    @discardableResult
    public func onDisconnect(_ cb: @escaping () -> Void) -> () -> Void {
        onDisconnectCallbacks.append(cb)
        return { [weak self] in
            self?.onDisconnectCallbacks.removeAll { $0 as AnyObject === cb as AnyObject }
        }
    }

    /// Register a callback for session errors.
    @discardableResult
    public func onError(_ cb: @escaping (DanWSError) -> Void) -> () -> Void {
        onErrorCallbacks.append(cb)
        return { [weak self] in
            self?.onErrorCallbacks.removeAll { $0 as AnyObject === cb as AnyObject }
        }
    }

    /// Disconnect this session.
    public func disconnect() {
        connected = false
        state = .disconnected
        for cb in onDisconnectCallbacks { cb() }
    }

    // MARK: - Session-level Data API (topic modes)

    /// Set a key-value pair in the session's flat state (topic modes only).
    public func set(_ key: String, _ value: Any?) {
        guard sessionBound, let flatState = flatState else { return }
        flatState.set(key, value)
    }

    /// Get a value from the session's flat state.
    public func get(_ key: String) -> Any? {
        flatState?.get(key)
    }

    /// All keys in the session's flat state.
    public var keys: [String] {
        flatState?.keys ?? []
    }

    /// Clear a key or all keys from the session's flat state.
    public func clearKey(_ key: String? = nil) {
        guard sessionBound, let flatState = flatState else { return }
        if let key = key {
            flatState.clear(key)
        } else {
            flatState.clear()
        }
    }

    // MARK: - Topic API (backward compat)

    /// Names of all subscribed topics.
    public var topicNames: [String] {
        Array(topics.keys)
    }

    /// Get topic info by name.
    public func topic(_ name: String) -> (name: String, params: [String: Any])? {
        topics[name]
    }

    /// Get a topic handle by name.
    public func getTopicHandle(_ name: String) -> TopicHandle? {
        topicHandles[name]
    }

    /// All topic handles.
    public var allTopicHandles: [String: TopicHandle] {
        topicHandles
    }

    // MARK: - Internal Methods

    func _setDebug(_ debug: Bool) {
        self.debug = debug
    }

    func _setMaxValueSize(_ size: Int) {
        maxValueSize = size
    }

    func _setEnqueue(_ fn: @escaping (Frame) -> Void) {
        enqueueFrame = fn
    }

    func _setTxProviders(
        keyFrames: @escaping () -> [Frame],
        valueFrames: @escaping () -> [Frame]
    ) {
        txKeyFrameProvider = keyFrames
        txValueFrameProvider = valueFrames
        txKeyFrameIndex = nil
        txValueFrameIndex = nil
    }

    func _bindSessionTX(enqueue: @escaping (Frame) -> Void) {
        sessionEnqueue = enqueue
        sessionBound = true
        flatState = FlatStateManager(cb: FlatStateCallbacks(
            allocateKeyId: { [weak self] in
                guard let self = self else { return 0 }
                let id = self.nextKeyId
                self.nextKeyId += 1
                return id
            },
            enqueue: enqueue,
            onResync: { [weak self] in
                self?.triggerSessionResync()
            },
            wirePrefix: "",
            maxValueSize: maxValueSize
        ))
    }

    func _authorize(_ principal: String) {
        self.principal = principal
        authorized = true
        state = .authorized
    }

    func _startSync() {
        state = .synchronizing
        serverSyncSent = false

        if let provider = txKeyFrameProvider, let enqueue = enqueueFrame {
            let frames = provider()
            if !frames.isEmpty {
                for f in frames { enqueue(f) }
                serverSyncSent = true
            } else {
                enqueue(Frame.signal(.serverSync))
                serverSyncSent = true
            }
        } else {
            state = .ready
            for cb in onReadyCallbacks { cb() }
        }
    }

    func _handleFrame(_ frame: Frame) {
        switch frame.frameType {
        case .clientReady:
            if state == .ready { return }
            if let provider = txValueFrameProvider, let enqueue = enqueueFrame {
                for vf in provider() { enqueue(vf) }
            }
            if serverSyncSent {
                state = .ready
                for cb in onReadyCallbacks { cb() }
            }

        case .clientResyncReq:
            if let provider = txKeyFrameProvider, let enqueue = enqueueFrame {
                txKeyFrameIndex = nil
                txValueFrameIndex = nil
                enqueue(Frame.signal(.serverReset))
                for f in provider() { enqueue(f) }
            }

        case .clientKeyRequest:
            handleKeyRequest(frame.keyId)

        case .error:
            let msg = frame.payload.stringValue ?? "Unknown error"
            let err = DanWSError.remoteError(msg)
            if onErrorCallbacks.isEmpty {
                log("Unhandled error: \(msg)")
            } else {
                for cb in onErrorCallbacks { cb(err) }
            }

        default:
            break
        }
    }

    func _handleDisconnect() {
        connected = false
        state = .disconnected
        for cb in onDisconnectCallbacks { cb() }
    }

    func _handleReconnect() {
        connected = true
        state = .authorized
    }

    // Topic management
    func _addTopic(_ name: String, params: [String: Any]) {
        topics[name] = (name: name, params: params)
    }

    func _removeTopic(_ name: String) {
        topics.removeValue(forKey: name)
    }

    func _updateTopicParams(_ name: String, params: [String: Any]) {
        if var t = topics[name] {
            t.params = params
            topics[name] = t
        }
    }

    var _nextTopicIndex: Int { topicIndex }

    func _createTopicHandle(
        _ name: String,
        params: [String: Any],
        wireIndex: Int? = nil
    ) -> TopicHandle {
        let index = wireIndex ?? topicIndex
        if index >= topicIndex { topicIndex = index + 1 }

        let payload = TopicPayload(
            index: index,
            allocateKeyId: { [weak self] in
                guard let self = self else { return 0 }
                let id = self.nextKeyId
                self.nextKeyId += 1
                return id
            },
            maxValueSize: maxValueSize
        )

        if let enqueue = sessionEnqueue {
            payload._bind(enqueue: enqueue, onResync: { [weak self] in
                self?.triggerSessionResync()
            })
        }

        let handle = TopicHandle(
            name: name,
            params: params,
            payload: payload,
            session: self,
            log: debug ? { [weak self] msg, err in self?.log(msg, err: err) } : nil
        )
        topicHandles[name] = handle
        topics[name] = (name: name, params: params)
        return handle
    }

    func _removeTopicHandle(_ name: String) {
        if let handle = topicHandles[name] {
            handle._dispose()
            topicHandles.removeValue(forKey: name)
            topics.removeValue(forKey: name)
            triggerSessionResync()
        }
    }

    func _disposeAllTopicHandles() {
        for handle in topicHandles.values {
            handle._dispose()
        }
        topicHandles.removeAll()
    }

    // MARK: - Private

    private func triggerSessionResync() {
        guard let enqueue = sessionEnqueue else { return }

        txKeyFrameIndex = nil
        txValueFrameIndex = nil

        // ServerReset
        enqueue(Frame.signal(.serverReset))

        // Build flat state frames
        var flatValueFrames: [Frame]?
        if let flatState = flatState {
            let (keyFrames, valueFrames) = flatState.buildAllFrames()
            for f in keyFrames { enqueue(f) }
            flatValueFrames = valueFrames
        }

        // Key registrations: topic payload entries
        for handle in topicHandles.values {
            for f in handle.payload._buildKeyFrames() {
                enqueue(f)
            }
        }

        // ServerSync
        enqueue(Frame.signal(.serverSync))

        // Values: flat session entries
        if let vf = flatValueFrames {
            for f in vf { enqueue(f) }
        }

        // Values: topic payload entries
        for handle in topicHandles.values {
            for f in handle.payload._buildValueFrames() {
                enqueue(f)
            }
        }
    }

    private func handleKeyRequest(_ keyId: UInt32) {
        guard let enqueue = enqueueFrame else { return }

        let syncFrame = Frame.signal(.serverSync)

        // Search in TX providers (broadcast/principal mode)
        if let keyProvider = txKeyFrameProvider, let valProvider = txValueFrameProvider {
            if txKeyFrameIndex == nil {
                var idx = [UInt32: Frame]()
                for f in keyProvider() where f.frameType == .serverKeyRegistration {
                    idx[f.keyId] = f
                }
                txKeyFrameIndex = idx
            }
            if let keyFrame = txKeyFrameIndex?[keyId] {
                enqueue(keyFrame)
                enqueue(syncFrame)
                if txValueFrameIndex == nil {
                    var idx = [UInt32: Frame]()
                    for f in valProvider() {
                        idx[f.keyId] = f
                    }
                    txValueFrameIndex = idx
                }
                if let vf = txValueFrameIndex?[keyId] {
                    enqueue(vf)
                }
                return
            }
        }

        // Search in session-level flat state
        if let flatState = flatState, let found = flatState.getByKeyId(keyId) {
            let (dt, dv) = Serializer.toDanValue(found.entry.value)
            enqueue(Frame(
                frameType: .serverKeyRegistration,
                keyId: UInt32(found.entry.keyId),
                dataType: found.entry.type,
                payload: .string(found.key)
            ))
            enqueue(syncFrame)
            enqueue(Frame(
                frameType: .serverValue,
                keyId: UInt32(found.entry.keyId),
                dataType: dt,
                payload: dv
            ))
            return
        }

        // Search in topic payloads
        for handle in topicHandles.values {
            for f in handle.payload._buildKeyFrames() {
                if f.keyId == keyId {
                    enqueue(f)
                    enqueue(syncFrame)
                    for vf in handle.payload._buildValueFrames() {
                        if vf.keyId == keyId {
                            enqueue(vf)
                            break
                        }
                    }
                    return
                }
            }
        }
    }

    private func log(_ msg: String, err: Error? = nil) {
        if debug {
            if let err = err {
                print("[dan-ws session] \(msg): \(err)")
            } else {
                print("[dan-ws session] \(msg)")
            }
        }
    }
}
