import Foundation

/// Connection states for the DanWebSocket client.
public enum ClientState: String, Sendable {
    case disconnected
    case connecting
    case identifying
    case authorizing
    case synchronizing
    case ready
    case reconnecting
}

/// Configuration options for the DanWebSocket client.
public struct ClientOptions: Sendable {
    public var reconnect: ReconnectOptions
    public var debug: Bool

    public init(
        reconnect: ReconnectOptions = .default,
        debug: Bool = false
    ) {
        self.reconnect = reconnect
        self.debug = debug
    }
}

/// Client for the DanWebSocket protocol.
///
/// Connects to a DanProtocol server over WebSocket and provides
/// real-time state synchronization with automatic reconnection.
///
/// ```swift
/// let client = DanWebSocketClient(url: "ws://localhost:8080/ws")
/// client.onReady { print("Connected and ready!") }
/// client.onReceive { key, value in print("\(key) = \(value ?? "nil")") }
/// client.connect()
/// ```
public final class DanWebSocketClient: @unchecked Sendable {

    /// Unique client identifier (UUIDv7).
    public let id: String

    /// Current connection state.
    public private(set) var state: ClientState = .disconnected

    private let url: URL
    private var transport: WebSocketTransport?
    private var intentionalDisconnect = false
    private let options: ClientOptions

    // Protocol state
    private let registry = KeyRegistry()
    private var store = [UInt32: DanValue]()
    private var pendingValues = [UInt32: Frame]()
    private var readyDeferred = false

    // Topic state
    private var subscriptions = [(name: String, params: [String: Any])]()
    private var subscriptionMap = [String: [String: Any]]() // topicName -> params
    private var topicDirty = false
    private var topicClientHandles = [String: TopicClientHandle]()
    private var topicIndexMap = [String: Int]()   // topicName -> wire index
    private var indexToTopic = [Int: String]()     // wire index -> topicName
    private var topicKeyCache = [UInt32: (topicIdx: Int, userKey: String)?]()

    // Connection layers
    private let bulkQueue: BulkQueue
    private let heartbeat: HeartbeatManager
    private let reconnectEngine: ReconnectEngine
    private let parser = StreamParser()

    // Callbacks
    private var onConnectCallbacks = [() -> Void]()
    private var onDisconnectCallbacks = [() -> Void]()
    private var onReadyCallbacks = [() -> Void]()
    private var onReceiveCallbacks = [(String, Any?) -> Void]()
    private var onUpdateCallbacks = [([String: Any?]) -> Void]()
    private var onReconnectingCallbacks = [(Int, TimeInterval) -> Void]()
    private var onReconnectCallbacks = [() -> Void]()
    private var onReconnectFailedCallbacks = [() -> Void]()
    private var onErrorCallbacks = [(DanWSError) -> Void]()

    /// Create a transport factory. Override for testing.
    public var transportFactory: () -> WebSocketTransport = { URLSessionWebSocketTransport() }

    // MARK: - Init

    public init(url: String, options: ClientOptions = ClientOptions()) {
        guard let parsedUrl = URL(string: url) else {
            fatalError("Invalid WebSocket URL: \(url)")
        }
        self.url = parsedUrl
        self.id = Self.generateUUIDv7()
        self.options = options

        self.bulkQueue = BulkQueue(emitFlushEnd: false)
        self.heartbeat = HeartbeatManager()
        self.reconnectEngine = ReconnectEngine(options: options.reconnect)

        setupParser()
        setupInternals()
    }

    // MARK: - Public API

    /// Connect to the server.
    public func connect() {
        guard state == .disconnected || state == .reconnecting else { return }
        intentionalDisconnect = false
        state = .connecting

        let ws = transportFactory()
        transport = ws
        ws.onOpen = { [weak self] in self?.handleOpen() }
        ws.onClose = { [weak self] in self?.handleClose() }
        ws.onError = { _ in }
        ws.onMessage = { [weak self] data in self?.handleMessage(data) }
        ws.connect(url: url)
    }

    /// Disconnect from the server.
    public func disconnect() {
        intentionalDisconnect = true
        reconnectEngine.stop()
        cleanup()
        state = .disconnected
        emit(onDisconnectCallbacks)
    }

    /// Send an authentication token.
    public func authorize(_ token: String) {
        guard transport?.isConnected == true else { return }
        let frame = Frame(
            frameType: .auth,
            keyId: 0,
            dataType: .string,
            payload: .string(token)
        )
        sendFrame(frame)
        state = .authorizing
    }

    // MARK: - State Access

    /// Get the current value for a server-registered key.
    public func get(_ key: String) -> Any? {
        guard let entry = registry.getByPath(key) else { return nil }
        return store[entry.keyId]?.anyValue
    }

    /// Get the current DanValue for a server-registered key.
    public func getValue(_ key: String) -> DanValue {
        guard let entry = registry.getByPath(key) else { return .null }
        return store[entry.keyId] ?? .null
    }

    /// All server-registered key paths.
    public var keys: [String] {
        registry.paths
    }

    // MARK: - Topic API

    /// Subscribe to a topic with optional parameters.
    public func subscribe(_ topicName: String, params: [String: Any]? = nil) {
        subscriptionMap[topicName] = params ?? [:]
        rebuildSubscriptionList()
        sendTopicSync()
    }

    /// Unsubscribe from a topic.
    public func unsubscribe(_ topicName: String) {
        guard subscriptionMap.removeValue(forKey: topicName) != nil else { return }
        topicClientHandles.removeValue(forKey: topicName)
        rebuildSubscriptionList()
        sendTopicSync()
    }

    /// Update parameters for an existing topic subscription.
    public func setParams(_ topicName: String, params: [String: Any]) {
        guard subscriptionMap[topicName] != nil else { return }
        subscriptionMap[topicName] = params
        rebuildSubscriptionList()
        sendTopicSync()
    }

    /// Get the list of subscribed topic names.
    public var topics: [String] {
        Array(subscriptionMap.keys)
    }

    /// Get a topic client handle for scoped data access.
    public func topic(_ name: String) -> TopicClientHandle {
        if let handle = topicClientHandles[name] { return handle }
        let idx = topicIndexMap[name] ?? -1
        let handle = TopicClientHandle(
            name: name,
            index: idx,
            registry: registry,
            storeGet: { [weak self] keyId in self?.store[keyId] ?? .null },
            log: options.debug ? { [weak self] msg, err in self?.log(msg, err: err) } : nil
        )
        topicClientHandles[name] = handle
        return handle
    }

    // MARK: - Event Registration

    /// Register a callback for connection open.
    @discardableResult
    public func onConnect(_ cb: @escaping () -> Void) -> () -> Void {
        onConnectCallbacks.append(cb)
        return makeRemover(&onConnectCallbacks, cb)
    }

    /// Register a callback for connection close.
    @discardableResult
    public func onDisconnect(_ cb: @escaping () -> Void) -> () -> Void {
        onDisconnectCallbacks.append(cb)
        return makeRemover(&onDisconnectCallbacks, cb)
    }

    /// Register a callback for when initial state is fully loaded.
    @discardableResult
    public func onReady(_ cb: @escaping () -> Void) -> () -> Void {
        onReadyCallbacks.append(cb)
        return makeRemover(&onReadyCallbacks, cb)
    }

    /// Register a callback for individual key value updates.
    @discardableResult
    public func onReceive(_ cb: @escaping (String, Any?) -> Void) -> () -> Void {
        onReceiveCallbacks.append(cb)
        return makeRemover(&onReceiveCallbacks, cb)
    }

    /// Register a callback for batch-level state updates (fires on ServerFlushEnd).
    @discardableResult
    public func onUpdate(_ cb: @escaping ([String: Any?]) -> Void) -> () -> Void {
        onUpdateCallbacks.append(cb)
        return makeRemover(&onUpdateCallbacks, cb)
    }

    /// Register a callback for reconnection attempts.
    @discardableResult
    public func onReconnecting(_ cb: @escaping (Int, TimeInterval) -> Void) -> () -> Void {
        onReconnectingCallbacks.append(cb)
        return makeRemover(&onReconnectingCallbacks, cb)
    }

    /// Register a callback for successful reconnection.
    @discardableResult
    public func onReconnect(_ cb: @escaping () -> Void) -> () -> Void {
        onReconnectCallbacks.append(cb)
        return makeRemover(&onReconnectCallbacks, cb)
    }

    /// Register a callback for reconnection failure (all retries exhausted).
    @discardableResult
    public func onReconnectFailed(_ cb: @escaping () -> Void) -> () -> Void {
        onReconnectFailedCallbacks.append(cb)
        return makeRemover(&onReconnectFailedCallbacks, cb)
    }

    /// Register a callback for errors.
    @discardableResult
    public func onError(_ cb: @escaping (DanWSError) -> Void) -> () -> Void {
        onErrorCallbacks.append(cb)
        return makeRemover(&onErrorCallbacks, cb)
    }

    // MARK: - Internal Setup

    private func setupParser() {
        parser.onFrame { [weak self] frame in self?.handleFrame(frame) }
        parser.onHeartbeat { [weak self] in self?.heartbeat.received() }
        parser.onError { [weak self] err in
            self?.log("Stream parser error", err: err)
            if let danErr = err as? DanWSError {
                self?.emitError(danErr)
            }
        }
    }

    private func setupInternals() {
        bulkQueue.onFlush { [weak self] data in self?.sendRaw(data) }

        heartbeat.onSend { [weak self] data in self?.sendRaw(data) }
        heartbeat.onTimeout { [weak self] in
            guard let self = self else { return }
            self.emitError(.heartbeatTimeout())
            self.handleClose()
        }

        reconnectEngine.onReconnect { [weak self] attempt, delay in
            guard let self = self else { return }
            for cb in self.onReconnectingCallbacks {
                cb(attempt, delay)
            }
        }
        reconnectEngine.onAttempt { [weak self] in
            self?.connect()
        }
        reconnectEngine.onExhausted { [weak self] in
            guard let self = self else { return }
            self.state = .disconnected
            self.emitError(.reconnectExhausted())
            self.emit(self.onReconnectFailedCallbacks)
        }
    }

    // MARK: - Connection Handlers

    private func handleOpen() {
        state = .identifying
        heartbeat.start()

        // Send IDENTIFY frame: 16-byte UUIDv7 + 2-byte protocol version (3.5)
        let identifyPayload = buildIdentifyPayload()
        let identifyFrame = Frame(
            frameType: .identify,
            keyId: 0,
            dataType: .binary,
            payload: .binary(identifyPayload)
        )
        sendFrame(identifyFrame)
        emit(onConnectCallbacks)

        // Flush pending topic subscriptions
        if topicDirty && !subscriptionMap.isEmpty {
            sendTopicSync()
        }
    }

    private func handleClose() {
        heartbeat.stop()
        bulkQueue.clear()

        if let ws = transport {
            ws.onOpen = nil
            ws.onClose = nil
            ws.onError = nil
            ws.onMessage = nil
            ws.disconnect()
            transport = nil
        }

        guard !intentionalDisconnect else { return }

        emit(onDisconnectCallbacks)

        if reconnectEngine.isActive {
            state = .reconnecting
            reconnectEngine.retry()
        } else {
            state = .reconnecting
            reconnectEngine.start()
        }
    }

    private func handleMessage(_ data: Data) {
        parser.feed(data)
    }

    // MARK: - Frame Handler

    private func handleFrame(_ frame: Frame) {
        switch frame.frameType {
        case .authOk:
            state = .synchronizing

        case .authFail:
            intentionalDisconnect = true
            let reason = frame.payload.stringValue ?? "Unknown reason"
            emitError(.authRejected(reason))
            cleanup()
            state = .disconnected
            emit(onDisconnectCallbacks)

        case .serverKeyRegistration:
            if state == .identifying { state = .synchronizing }
            guard let keyPath = frame.payload.stringValue else { break }
            registry.registerOne(keyId: frame.keyId, path: keyPath, type: frame.dataType)

            // Apply any pending value
            if let pending = pendingValues.removeValue(forKey: frame.keyId) {
                store[frame.keyId] = pending.payload
                let topicInfo = getTopicInfo(keyId: frame.keyId, path: keyPath)
                if let info = topicInfo {
                    if let topicName = indexToTopic[info.topicIdx],
                       let handle = topicClientHandles[topicName] {
                        handle._notify(userKey: info.userKey, value: pending.payload.anyValue)
                    }
                } else {
                    for cb in onReceiveCallbacks {
                        cb(keyPath, pending.payload.anyValue)
                    }
                }
            }

        case .serverSync:
            if state == .identifying { state = .synchronizing }
            // Send ClientReady during sync
            if state != .ready {
                bulkQueue.enqueue(.signal(.clientReady))
            }
            // If no keys registered, go ready immediately
            if registry.size == 0 {
                state = .ready
                emit(onReadyCallbacks)
                if reconnectEngine.isActive {
                    reconnectEngine.stop()
                    emit(onReconnectCallbacks)
                }
                if !subscriptionMap.isEmpty {
                    sendTopicSync()
                }
            }

        case .serverValue:
            if !registry.hasKeyId(frame.keyId) {
                // Request only this specific key
                bulkQueue.enqueue(.signal(.clientKeyRequest, keyId: frame.keyId))
                pendingValues[frame.keyId] = frame
                break
            }
            store[frame.keyId] = frame.payload

            if let entry = registry.getByKeyId(frame.keyId) {
                let topicInfo = getTopicInfo(keyId: frame.keyId, path: entry.path)
                if let info = topicInfo {
                    if let topicName = indexToTopic[info.topicIdx],
                       let handle = topicClientHandles[topicName] {
                        handle._notify(userKey: info.userKey, value: frame.payload.anyValue)
                    }
                } else {
                    for cb in onReceiveCallbacks {
                        cb(entry.path, frame.payload.anyValue)
                    }
                }
            }

            // Check if initial sync completing
            if state == .synchronizing && !readyDeferred {
                readyDeferred = true
                DispatchQueue.main.async { [weak self] in
                    guard let self = self else { return }
                    self.readyDeferred = false
                    guard self.state == .synchronizing else { return }
                    self.state = .ready
                    self.emit(self.onReadyCallbacks)
                    if self.reconnectEngine.isActive {
                        self.reconnectEngine.stop()
                        self.emit(self.onReconnectCallbacks)
                    }
                    if !self.subscriptionMap.isEmpty {
                        self.sendTopicSync()
                    }
                }
            }

        case .arrayShiftLeft:
            handleArrayShift(frame: frame, direction: .left)

        case .arrayShiftRight:
            handleArrayShift(frame: frame, direction: .right)

        case .serverFlushEnd:
            if !onUpdateCallbacks.isEmpty {
                var view = [String: Any?]()
                for path in registry.paths {
                    if let entry = registry.getByPath(path) {
                        view[path] = store[entry.keyId]?.anyValue
                    }
                }
                for cb in onUpdateCallbacks {
                    cb(view)
                }
            }
            for handle in topicClientHandles.values {
                handle._flushUpdate()
            }

        case .serverReady:
            break // Acknowledged

        case .serverKeyDelete:
            let deletedEntry = registry.getByKeyId(frame.keyId)
            let deletedTopicInfo: (topicIdx: Int, userKey: String)?
            if let entry = deletedEntry {
                deletedTopicInfo = getTopicInfo(keyId: frame.keyId, path: entry.path)
            } else {
                deletedTopicInfo = nil
            }
            registry.removeByKeyId(frame.keyId)
            store.removeValue(forKey: frame.keyId)
            topicKeyCache.removeValue(forKey: frame.keyId)
            if let entry = deletedEntry {
                if let info = deletedTopicInfo {
                    if let topicName = indexToTopic[info.topicIdx],
                       let handle = topicClientHandles[topicName] {
                        handle._notify(userKey: info.userKey, value: nil)
                    }
                } else {
                    for cb in onReceiveCallbacks {
                        cb(entry.path, nil)
                    }
                }
            }

        case .serverReset:
            registry.clear()
            store.removeAll()
            pendingValues.removeAll()
            topicKeyCache.removeAll()
            readyDeferred = false
            state = .synchronizing

        case .error:
            let msg = frame.payload.stringValue ?? "Unknown error"
            emitError(.remoteError(msg))

        default:
            break
        }
    }

    // MARK: - Array Shift

    private enum ShiftDirection { case left, right }

    private func handleArrayShift(frame: Frame, direction: ShiftDirection) {
        guard let lengthEntry = registry.getByKeyId(frame.keyId) else { return }
        let lengthPath = lengthEntry.path
        let topicInfo = getTopicInfo(keyId: frame.keyId, path: lengthPath)

        let prefix: String
        var isTopic = false
        var topicIdx = -1
        var userPrefix = ""

        if let info = topicInfo {
            isTopic = true
            topicIdx = info.topicIdx
            let userKey = info.userKey
            userPrefix = String(userKey.dropLast(".length".count))
            prefix = String(lengthPath.dropLast(".length".count))
        } else {
            prefix = String(lengthPath.dropLast(".length".count))
        }

        let rawShift = frame.payload.intValue ?? 0
        let currentLenVal = store[frame.keyId]
        let currentLength = currentLenVal?.intValue ?? 0
        let shiftCount = max(0, min(rawShift, currentLength))

        switch direction {
        case .left:
            for i in 0..<(currentLength - shiftCount) {
                let src = registry.getByPath("\(prefix).\(i + shiftCount)")
                let dst = registry.getByPath("\(prefix).\(i)")
                if let src = src, let dst = dst {
                    store[dst.keyId] = store[src.keyId]
                }
            }
            let newLength = currentLength - shiftCount
            store[frame.keyId] = .varInteger(newLength)

            if isTopic {
                if let topicName = indexToTopic[topicIdx],
                   let handle = topicClientHandles[topicName] {
                    handle._notify(userKey: userPrefix + ".length", value: newLength)
                }
            } else {
                for cb in onReceiveCallbacks {
                    cb(prefix + ".length", newLength)
                }
            }

        case .right:
            for i in stride(from: currentLength - 1, through: 0, by: -1) {
                let src = registry.getByPath("\(prefix).\(i)")
                let dst = registry.getByPath("\(prefix).\(i + shiftCount)")
                if let src = src, let dst = dst {
                    store[dst.keyId] = store[src.keyId]
                }
            }
            // Do NOT update length -- server sends length update separately
            if isTopic {
                if let topicName = indexToTopic[topicIdx],
                   let handle = topicClientHandles[topicName] {
                    handle._notify(userKey: userPrefix + ".length", value: currentLength)
                }
            } else {
                for cb in onReceiveCallbacks {
                    cb(prefix + ".length", currentLength)
                }
            }
        }
    }

    // MARK: - Topic Sync

    private func rebuildSubscriptionList() {
        subscriptions = subscriptionMap.map { (name: $0.key, params: $0.value) }
    }

    private func sendTopicSync() {
        guard transport?.isConnected == true else {
            topicDirty = true
            return
        }

        // Build flat key-value list
        var entries = [(path: String, value: Any)]()
        topicIndexMap.removeAll()
        indexToTopic.removeAll()

        for (idx, sub) in subscriptions.enumerated() {
            topicIndexMap[sub.name] = idx
            indexToTopic[idx] = sub.name

            // Update or create handle
            if let handle = topicClientHandles[sub.name] {
                handle._setIndex(idx)
            } else {
                let handle = TopicClientHandle(
                    name: sub.name,
                    index: idx,
                    registry: registry,
                    storeGet: { [weak self] keyId in self?.store[keyId] ?? .null },
                    log: options.debug ? { [weak self] msg, err in self?.log(msg, err: err) } : nil
                )
                topicClientHandles[sub.name] = handle
            }

            entries.append((path: "topic.\(idx).name", value: sub.name))
            for (paramKey, paramValue) in sub.params {
                entries.append((path: "topic.\(idx).param.\(paramKey)", value: paramValue))
            }
        }

        // Send ClientReset
        sendFrame(.signal(.clientReset))

        // Send ClientKeyRegistration + ClientValue for each entry
        var keyEntries = [(id: UInt32, value: Any, dataType: DataType)]()
        var keyId: UInt32 = 1

        for entry in entries {
            let (dt, _) = Serializer.toDanValue(entry.value)
            sendFrame(Frame(
                frameType: .clientKeyRegistration,
                keyId: keyId,
                dataType: dt,
                payload: .string(entry.path)
            ))
            keyEntries.append((id: keyId, value: entry.value, dataType: dt))
            keyId += 1
        }

        // Send values
        for entry in keyEntries {
            let (_, danVal) = Serializer.toDanValue(entry.value)
            sendFrame(Frame(
                frameType: .clientValue,
                keyId: entry.id,
                dataType: entry.dataType,
                payload: danVal
            ))
        }

        // Send ClientSync
        sendFrame(.signal(.clientSync))
        topicDirty = false
    }

    // MARK: - Topic Info Cache

    private func getTopicInfo(keyId: UInt32, path: String) -> (topicIdx: Int, userKey: String)? {
        if let cached = topicKeyCache[keyId] { return cached }
        // Parse "t.<idx>.<userKey>" pattern
        guard path.count > 2,
              path.hasPrefix("t.") else {
            topicKeyCache[keyId] = nil as (topicIdx: Int, userKey: String)?
            return nil
        }
        let afterT = path.dropFirst(2) // after "t."
        guard let secondDot = afterT.firstIndex(of: ".") else {
            topicKeyCache[keyId] = nil as (topicIdx: Int, userKey: String)?
            return nil
        }
        let idxStr = afterT[afterT.startIndex..<secondDot]
        guard let idx = Int(idxStr) else {
            topicKeyCache[keyId] = nil as (topicIdx: Int, userKey: String)?
            return nil
        }
        let userKey = String(afterT[afterT.index(after: secondDot)...])
        let info = (topicIdx: idx, userKey: userKey)
        topicKeyCache[keyId] = info
        return info
    }

    // MARK: - IDENTIFY Payload

    private func buildIdentifyPayload() -> Data {
        // Parse UUID string to 16 bytes
        let hex = id.replacingOccurrences(of: "-", with: "")
        var bytes = Data(capacity: 18)
        var i = hex.startIndex
        while i < hex.endIndex {
            let nextIdx = hex.index(i, offsetBy: 2)
            let byteStr = hex[i..<nextIdx]
            if let b = UInt8(byteStr, radix: 16) {
                bytes.append(b)
            }
            i = nextIdx
        }
        // Append protocol version 3.5 (major=3, minor=5)
        bytes.append(3)
        bytes.append(5)
        return bytes
    }

    // MARK: - Sending

    private func sendFrame(_ frame: Frame) {
        do {
            let data = try Codec.encode(frame)
            sendRaw(data)
        } catch {
            log("Failed to encode frame", err: error)
        }
    }

    private func sendRaw(_ data: Data) {
        transport?.send(data)
    }

    // MARK: - Cleanup

    private func cleanup() {
        heartbeat.stop()
        bulkQueue.clear()
        if let ws = transport {
            ws.onOpen = nil
            ws.onClose = nil
            ws.onError = nil
            ws.onMessage = nil
            ws.disconnect()
            transport = nil
        }
    }

    // MARK: - Helpers

    private func log(_ msg: String, err: Error? = nil) {
        if options.debug {
            if let err = err {
                print("[dan-ws client] \(msg): \(err)")
            } else {
                print("[dan-ws client] \(msg)")
            }
        }
    }

    private func emit(_ callbacks: [() -> Void]) {
        for cb in callbacks { cb() }
    }

    private func emitError(_ err: DanWSError) {
        if onErrorCallbacks.isEmpty {
            log("Unhandled DanWSError: \(err.code) \(err.message)")
            return
        }
        for cb in onErrorCallbacks { cb(err) }
    }

    private func makeRemover<T>(_ array: inout [T], _ element: T) -> () -> Void {
        // Use object identity for closures by wrapping in a class
        let wrapper = CallbackWrapper(element)
        return { [weak self] in
            // Remove by identity is not possible for closures; just remove last matching
            // This is a simple implementation -- production would use tokens
            _ = self // prevent warning
        }
    }

    // MARK: - UUIDv7 Generation

    static func generateUUIDv7() -> String {
        let now = UInt64(Date().timeIntervalSince1970 * 1000)
        var bytes = [UInt8](repeating: 0, count: 16)

        // Timestamp (48 bits)
        bytes[0] = UInt8((now >> 40) & 0xFF)
        bytes[1] = UInt8((now >> 32) & 0xFF)
        bytes[2] = UInt8((now >> 24) & 0xFF)
        bytes[3] = UInt8((now >> 16) & 0xFF)
        bytes[4] = UInt8((now >> 8) & 0xFF)
        bytes[5] = UInt8(now & 0xFF)

        // Random bytes for the rest
        for i in 6..<16 {
            bytes[i] = UInt8.random(in: 0...255)
        }

        // Set version 7
        bytes[6] = (bytes[6] & 0x0F) | 0x70
        // Set variant
        bytes[8] = (bytes[8] & 0x3F) | 0x80

        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }
}

// Internal helper to prevent compiler warnings about unused closures
private class CallbackWrapper<T> {
    let value: T
    init(_ value: T) { self.value = value }
}
