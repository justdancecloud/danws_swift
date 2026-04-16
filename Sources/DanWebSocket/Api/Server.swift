import Foundation
#if canImport(Network)
import Network
#endif

/// Server operating modes.
public enum ServerMode: String, Sendable {
    case broadcast
    case principal
    case sessionTopic = "session_topic"
    case sessionPrincipalTopic = "session_principal_topic"
}

/// Configuration options for the DanWebSocket server.
public struct ServerOptions: Sendable {
    public var port: Int
    public var path: String
    public var mode: ServerMode
    public var sessionTtl: Int // ms
    public var principalEvictionTtl: Int // ms
    public var debug: Bool
    public var flushIntervalMs: Int?
    public var maxMessageSize: Int
    public var maxValueSize: Int
    public var maxConnections: Int
    public var maxFramesPerSec: Int

    public init(
        port: Int,
        path: String = "/",
        mode: ServerMode = .principal,
        sessionTtl: Int = 600_000,
        principalEvictionTtl: Int = 300_000,
        debug: Bool = false,
        flushIntervalMs: Int? = nil,
        maxMessageSize: Int = 1_048_576,
        maxValueSize: Int = 65_536,
        maxConnections: Int = 0,
        maxFramesPerSec: Int = 0
    ) {
        self.port = port
        self.path = path
        self.mode = mode
        self.sessionTtl = sessionTtl
        self.principalEvictionTtl = principalEvictionTtl
        self.debug = debug
        self.flushIntervalMs = flushIntervalMs
        self.maxMessageSize = maxMessageSize
        self.maxValueSize = maxValueSize
        self.maxConnections = maxConnections
        self.maxFramesPerSec = maxFramesPerSec
    }
}

/// Metrics snapshot of the server.
public struct ServerMetrics: Sendable {
    public let activeSessions: Int
    public let pendingSessions: Int
    public let principalCount: Int
    public let framesIn: Int
    public let framesOut: Int
}

/// Internal session data.
private final class InternalSession {
    let session: DanWebSocketSession
    var transport: ServerClientTransport?
    var bulkQueue: BulkQueue
    var heartbeat: HeartbeatManager
    var authPhase: AuthPhase = .awaitingIdentify
    var authToken: String?
    var ttlTimer: DispatchWorkItem?
    var clientRegistry: KeyRegistry?
    var clientValues: [UInt32: Any]?

    init(session: DanWebSocketSession, transport: ServerClientTransport?,
         bulkQueue: BulkQueue, heartbeat: HeartbeatManager) {
        self.session = session
        self.transport = transport
        self.bulkQueue = bulkQueue
        self.heartbeat = heartbeat
    }
}

/// Auth phases for a session.
private enum AuthPhase {
    case awaitingIdentify
    case awaitingAuth
    case authorized
    case rejected
}

private let BROADCAST_PRINCIPAL = "__broadcast__"

/// Protocol for server-side client transport (one per connected client).
public protocol ServerClientTransport: AnyObject {
    func send(_ data: Data)
    func close()
    var isOpen: Bool { get }
}

/// DanProtocol WebSocket server.
///
/// Supports all four modes: broadcast, principal, session_topic, session_principal_topic.
///
/// ```swift
/// let server = DanWebSocketServer(options: ServerOptions(port: 8080, mode: .broadcast))
/// server.set("score", 100)
/// server.onConnection { session in
///     print("Client connected: \(session.id)")
/// }
/// ```
public final class DanWebSocketServer: @unchecked Sendable {

    /// Protocol version: 3.5
    public static let PROTOCOL_MAJOR: UInt8 = 3
    public static let PROTOCOL_MINOR: UInt8 = 5

    /// Server operating mode.
    public let mode: ServerMode

    /// Topic namespace for registering subscribe/unsubscribe callbacks.
    public let topic: TopicNamespace

    private let principals: PrincipalManager
    private let path: String
    private let ttl: Int
    private var authEnabled = false
    private var authTimeout = 5000
    private let debug: Bool
    private let flushIntervalMs: Int?
    private let maxValueSize: Int
    private let maxMessageSize: Int
    private let principalEvictionTtl: Int

    private var sessions = [String: InternalSession]()
    private var tmpSessions = [String: InternalSession]()
    private var principalIndex = [String: Set<ObjectIdentifier>]()
    private var principalIndexMap = [ObjectIdentifier: InternalSession]()
    private var principalEvictionTimers = [String: DispatchWorkItem]()
    private var pendingCloseTimers = Set<DispatchWorkItem>()

    // Callbacks
    private var onConnectionCallbacks = [(DanWebSocketSession) -> Void]()
    private var onAuthorizeCallbacks = [(String, String) -> Void]()
    private var onSessionExpiredCallbacks = [(DanWebSocketSession) -> Void]()

    // Rate limits & metrics
    private var _maxConnections: Int
    private var _maxFramesPerSec: Int
    private var framesIn = 0
    private var framesOut = 0
    private var frameCounters = [String: (count: Int, windowStart: Date)]()

    // NWListener for WebSocket server
    #if canImport(Network)
    private var listener: NWListener?
    #endif

    // For testing / custom transports: inject connections directly
    private var externalConnectionHandler: ((ServerClientTransport) -> Void)?

    private var isTopicMode: Bool {
        mode == .sessionTopic || mode == .sessionPrincipalTopic
    }

    // MARK: - Init

    public init(options: ServerOptions) {
        self.mode = options.mode
        self.path = options.path
        self.ttl = options.sessionTtl
        self.debug = options.debug
        self.flushIntervalMs = options.flushIntervalMs
        self.maxValueSize = options.maxValueSize
        self.maxMessageSize = options.maxMessageSize
        self.principalEvictionTtl = options.principalEvictionTtl
        self._maxConnections = options.maxConnections
        self._maxFramesPerSec = options.maxFramesPerSec

        self.topic = TopicNamespace()
        self.principals = PrincipalManager()
        principals._setMaxValueSize(maxValueSize)

        if !isTopicMode {
            principals._setOnNewPrincipal { [weak self] ptx in
                self?.bindPrincipalTX(ptx)
            }
        }

        #if canImport(Network)
        startListener(port: options.port)
        #endif
    }

    // MARK: - Broadcast Mode API

    /// Set a key-value pair (broadcast mode only).
    public func set(_ key: String, _ value: Any?) {
        assertMode(.broadcast, "set")
        principals.principal(BROADCAST_PRINCIPAL).set(key, value)
    }

    /// Get a value by key (broadcast mode only).
    public func get(_ key: String) -> Any? {
        assertMode(.broadcast, "get")
        return principals.principal(BROADCAST_PRINCIPAL).get(key)
    }

    /// All registered keys (broadcast mode only).
    public var keys: [String] {
        guard mode == .broadcast else { return [] }
        return principals.principal(BROADCAST_PRINCIPAL).keys
    }

    /// Clear a specific key or all keys (broadcast mode only).
    public func clear(_ key: String? = nil) {
        assertMode(.broadcast, "clear")
        if let key = key {
            principals.principal(BROADCAST_PRINCIPAL).clear(key)
        } else {
            principals.principal(BROADCAST_PRINCIPAL).clear()
        }
    }

    /// Create an ArraySync ring buffer (broadcast mode only).
    public func array(_ key: String, capacity: Int) -> ArraySync {
        assertMode(.broadcast, "array")
        return ArraySync(key: key, capacity: capacity, ptx: principals.principal(BROADCAST_PRINCIPAL))
    }

    // MARK: - Principal Mode API

    /// Access a named principal's TX state (principal/session_principal_topic modes).
    public func principal(_ name: String) -> PrincipalTX {
        guard mode == .principal || mode == .sessionPrincipalTopic else {
            fatalError("server.principal() is only available in principal/session_principal_topic mode.")
        }
        return principals.principal(name)
    }

    /// Names of all active principals.
    public var principalNames: [String] {
        principals.principalNames
    }

    // MARK: - Common API

    /// Enable or disable authorization.
    public func enableAuthorization(_ enabled: Bool, timeout: Int = 5000) {
        authEnabled = enabled
        authTimeout = timeout
    }

    /// Accept a client's auth request.
    public func authorize(_ clientUuid: String, token: String, principal: String) {
        guard let internal_ = tmpSessions[clientUuid] else { return }

        tmpSessions.removeValue(forKey: clientUuid)
        internal_.authPhase = .authorized
        internal_.session._authorize(principal)

        sendFrame(internal_, Frame.signal(.authOk))

        sessions[clientUuid] = internal_
        activateSession(internal_, principal: principal)
    }

    /// Reject a client's auth request.
    public func reject(_ clientUuid: String, reason: String = "Rejected") {
        guard let internal_ = tmpSessions[clientUuid] else { return }

        tmpSessions.removeValue(forKey: clientUuid)
        sendFrame(internal_, Frame(
            frameType: .authFail,
            keyId: 0,
            dataType: .string,
            payload: .string(reason)
        ))

        if let transport = internal_.transport {
            let work = DispatchWorkItem { [weak self, weak transport] in
                transport?.close()
                if let work = self?.pendingCloseTimers.first(where: { _ in true }) {
                    self?.pendingCloseTimers.remove(work)
                }
            }
            pendingCloseTimers.insert(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
        }
    }

    /// Set maximum concurrent connections (0 = unlimited).
    public func setMaxConnections(_ max: Int) { _maxConnections = max }

    /// Set maximum frames per second per client (0 = unlimited).
    public func setMaxFramesPerSec(_ max: Int) { _maxFramesPerSec = max }

    /// Get a snapshot of server metrics.
    public func metrics() -> ServerMetrics {
        ServerMetrics(
            activeSessions: sessions.count,
            pendingSessions: tmpSessions.count,
            principalCount: principals.size,
            framesIn: framesIn,
            framesOut: framesOut
        )
    }

    /// Get a session by UUID.
    public func getSession(_ uuid: String) -> DanWebSocketSession? {
        sessions[uuid]?.session
    }

    /// Get all sessions for a principal.
    public func getSessionsByPrincipal(_ principal: String) -> [DanWebSocketSession] {
        let effectivePrincipal = mode == .broadcast ? BROADCAST_PRINCIPAL : principal
        guard let ids = principalIndex[effectivePrincipal] else { return [] }
        return ids.compactMap { id in principalIndexMap[id]?.session }
    }

    /// Check if a client is connected.
    public func isConnected(_ uuid: String) -> Bool {
        sessions[uuid]?.session.connected ?? false
    }

    // MARK: - Event Registration

    /// Register a callback for new client connections.
    @discardableResult
    public func onConnection(_ cb: @escaping (DanWebSocketSession) -> Void) -> () -> Void {
        onConnectionCallbacks.append(cb)
        let index = onConnectionCallbacks.count - 1
        return { [weak self] in
            guard let self = self, index < self.onConnectionCallbacks.count else { return }
            self.onConnectionCallbacks.remove(at: index)
        }
    }

    /// Register a callback for authorization requests.
    @discardableResult
    public func onAuthorize(_ cb: @escaping (String, String) -> Void) -> () -> Void {
        onAuthorizeCallbacks.append(cb)
        let index = onAuthorizeCallbacks.count - 1
        return { [weak self] in
            guard let self = self, index < self.onAuthorizeCallbacks.count else { return }
            self.onAuthorizeCallbacks.remove(at: index)
        }
    }

    /// Register a callback for when sessions expire.
    @discardableResult
    public func onSessionExpired(_ cb: @escaping (DanWebSocketSession) -> Void) -> () -> Void {
        onSessionExpiredCallbacks.append(cb)
        let index = onSessionExpiredCallbacks.count - 1
        return { [weak self] in
            guard let self = self, index < self.onSessionExpiredCallbacks.count else { return }
            self.onSessionExpiredCallbacks.remove(at: index)
        }
    }

    // MARK: - Lifecycle

    /// Shut down the server and close all connections.
    public func close() {
        for internal_ in sessions.values {
            internal_.session._disposeAllTopicHandles()
            internal_.session._handleDisconnect()
            internal_.heartbeat.stop()
            internal_.bulkQueue.dispose()
            internal_.ttlTimer?.cancel()
            internal_.transport?.close()
        }
        for internal_ in tmpSessions.values {
            internal_.heartbeat.stop()
            internal_.transport?.close()
        }
        sessions.removeAll()
        tmpSessions.removeAll()
        principalIndex.removeAll()
        principalIndexMap.removeAll()
        for work in principalEvictionTimers.values { work.cancel() }
        principalEvictionTimers.removeAll()
        for work in pendingCloseTimers { work.cancel() }
        pendingCloseTimers.removeAll()

        #if canImport(Network)
        listener?.cancel()
        listener = nil
        #endif
    }

    // MARK: - External Connection Injection (for testing)

    /// Inject a raw transport connection. Used for testing without Network.framework.
    public func handleConnection(_ transport: ServerClientTransport) {
        _handleConnection(transport)
    }

    // MARK: - NWListener Setup

    #if canImport(Network)
    private func startListener(port: Int) {
        let params = NWParameters.tcp
        let wsOptions = NWProtocolWebSocket.Options()
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)

        do {
            listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: UInt16(port)))
        } catch {
            log("Failed to create NWListener: \(error)")
            return
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNWConnection(connection)
        }

        listener?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.log("Server listening on port \(port)")
            case .failed(let error):
                self?.log("Listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: .main)
    }

    private func handleNWConnection(_ connection: NWConnection) {
        let transport = NWConnectionTransport(connection: connection)
        connection.start(queue: .main)
        _handleConnection(transport)
    }
    #endif

    // MARK: - Connection Handling

    private func _handleConnection(_ transport: ServerClientTransport) {
        let parser = StreamParser(maxBufferSize: maxMessageSize)
        var identified = false
        var clientUuid = ""

        parser.onHeartbeat { [weak self] in
            guard let self = self else { return }
            let internal_ = self.sessions[clientUuid] ?? self.tmpSessions[clientUuid]
            internal_?.heartbeat.received()
        }

        parser.onFrame { [weak self] frame in
            guard let self = self else { return }
            self.framesIn += 1

            // Rate limiting
            if self._maxFramesPerSec > 0 && !clientUuid.isEmpty {
                let now = Date()
                var rc = self.frameCounters[clientUuid] ?? (count: 0, windowStart: now)
                if now.timeIntervalSince(rc.windowStart) >= 1.0 {
                    rc = (count: 0, windowStart: now)
                }
                rc.count += 1
                self.frameCounters[clientUuid] = rc
                if rc.count > self._maxFramesPerSec {
                    self.log("Frame rate exceeded (\(self._maxFramesPerSec)/s) -- closing \(clientUuid)")
                    transport.close()
                    return
                }
            }

            if !identified {
                guard frame.frameType == .identify else {
                    transport.close()
                    return
                }
                guard case .binary(let payload) = frame.payload,
                      (payload.count == 16 || payload.count == 18) else {
                    transport.close()
                    return
                }

                // Check protocol version compatibility
                if payload.count == 18 {
                    let clientMajor = payload[16]
                    if clientMajor != DanWebSocketServer.PROTOCOL_MAJOR {
                        self.log("Rejecting client with incompatible protocol major: \(clientMajor)")
                        transport.close()
                        return
                    }
                }

                clientUuid = Self.bytesToUuid(payload.prefix(16))
                identified = true
                self.handleIdentified(transport: transport, clientUuid: clientUuid, parser: parser)
                return
            }

            // Auth frame
            if frame.frameType == .auth {
                if let internal_ = self.tmpSessions[clientUuid], self.authEnabled {
                    let token = frame.payload.stringValue ?? ""
                    internal_.authToken = token
                    for cb in self.onAuthorizeCallbacks {
                        cb(clientUuid, token)
                    }
                }
                return
            }

            // Client->Server topic frames
            if self.isTopicMode {
                if let internal_ = self.sessions[clientUuid] {
                    if frame.frameType == .clientReset ||
                       frame.frameType == .clientKeyRegistration ||
                       frame.frameType == .clientValue ||
                       frame.frameType == .clientSync {
                        self.handleClientTopicFrame(internal_, frame)
                        return
                    }
                }
            }

            // Route to session handler
            if let internal_ = self.sessions[clientUuid] {
                internal_.session._handleFrame(frame)
            }
        }

        parser.onError { [weak self] err in
            self?.log("Stream parser error: \(err)")
        }

        // Wire up transport message handler
        if let nwTransport = transport as? NWConnectionTransport {
            nwTransport.onReceive = { [weak parser] data in
                parser?.feed(data)
            }
            nwTransport.onDisconnect = { [weak self] in
                if !clientUuid.isEmpty {
                    self?.handleSessionDisconnect(clientUuid)
                }
            }
            nwTransport.startReceiving()
        } else if let mockTransport = transport as? MockServerTransport {
            mockTransport.onReceive = { [weak parser] data in
                parser?.feed(data)
            }
            mockTransport.onDisconnect = { [weak self] in
                if !clientUuid.isEmpty {
                    self?.handleSessionDisconnect(clientUuid)
                }
            }
        }
    }

    private func handleIdentified(transport: ServerClientTransport, clientUuid: String, parser: StreamParser) {
        let total = sessions.count + tmpSessions.count
        if _maxConnections > 0 && sessions[clientUuid] == nil && total >= _maxConnections {
            log("Max connections reached (\(_maxConnections)) -- rejecting \(clientUuid)")
            transport.close()
            return
        }

        // Reconnection
        if let existing = sessions[clientUuid] {
            existing.transport?.close()
            existing.ttlTimer?.cancel()
            existing.ttlTimer = nil

            existing.transport = transport
            existing.session._handleReconnect()
            existing.heartbeat.start()
            existing.bulkQueue.onFlush { data in
                if transport.isOpen { transport.send(data) }
            }

            if authEnabled {
                tmpSessions[clientUuid] = existing
                sessions.removeValue(forKey: clientUuid)
                existing.authPhase = .awaitingAuth
                startAuthTimeout(clientUuid: clientUuid, transport: transport)
            } else {
                let principal = existing.session.principal ?? BROADCAST_PRINCIPAL
                existing.session._authorize(principal)
                activateSession(existing, principal: principal)
            }
            return
        }

        // New session
        let session = DanWebSocketSession(clientUuid)
        session._setDebug(debug)
        session._setMaxValueSize(maxValueSize)
        let bulkQueue = BulkQueue(flushIntervalMs: flushIntervalMs ?? 100, emitFlushEnd: false)
        let heartbeat = HeartbeatManager()

        let internal_ = InternalSession(
            session: session,
            transport: transport,
            bulkQueue: bulkQueue,
            heartbeat: heartbeat
        )

        session._setEnqueue { f in bulkQueue.enqueue(f) }
        bulkQueue.onFlush { data in
            if transport.isOpen { transport.send(data) }
        }
        bulkQueue.onOverflow { transport.close() }
        heartbeat.onSend { data in
            if transport.isOpen { transport.send(data) }
        }
        heartbeat.onTimeout { [weak self] in
            self?.handleSessionDisconnect(clientUuid)
        }
        heartbeat.start()

        if authEnabled {
            tmpSessions[clientUuid] = internal_
            internal_.authPhase = .awaitingAuth
            startAuthTimeout(clientUuid: clientUuid, transport: transport)
        } else {
            let defaultPrincipal = mode == .broadcast ? BROADCAST_PRINCIPAL : "default"
            session._authorize(defaultPrincipal)
            sessions[clientUuid] = internal_
            activateSession(internal_, principal: defaultPrincipal)
        }
    }

    private func activateSession(_ internal_: InternalSession, principal: String) {
        if isTopicMode {
            internal_.session._bindSessionTX(enqueue: { f in internal_.bulkQueue.enqueue(f) })
            for cb in onConnectionCallbacks { cb(internal_.session) }
            internal_.bulkQueue.enqueue(Frame.signal(.serverSync))
        } else {
            let effectivePrincipal = mode == .broadcast ? BROADCAST_PRINCIPAL : principal
            let ptx = principals.principal(effectivePrincipal)
            principals._addSession(effectivePrincipal)
            cancelPrincipalEviction(effectivePrincipal)
            indexAddSession(effectivePrincipal, internal_)

            internal_.session._setTxProviders(
                keyFrames: { ptx._buildKeyFrames() },
                valueFrames: { ptx._buildValueFrames() }
            )

            for cb in onConnectionCallbacks { cb(internal_.session) }
            internal_.session._startSync()
        }
    }

    // MARK: - Client Topic Frame Handling

    private func handleClientTopicFrame(_ internal_: InternalSession, _ frame: Frame) {
        switch frame.frameType {
        case .clientReset:
            if internal_.clientRegistry != nil { internal_.clientRegistry!.clear() }
            else { internal_.clientRegistry = KeyRegistry() }
            if internal_.clientValues != nil { internal_.clientValues!.removeAll() }
            else { internal_.clientValues = [:] }

        case .clientKeyRegistration:
            if internal_.clientRegistry == nil { internal_.clientRegistry = KeyRegistry() }
            if let path = frame.payload.stringValue {
                internal_.clientRegistry!.registerOne(keyId: frame.keyId, path: path, type: frame.dataType)
            }

        case .clientValue:
            if internal_.clientValues == nil { internal_.clientValues = [:] }
            internal_.clientValues![frame.keyId] = frame.payload.anyValue

        case .clientSync:
            processTopicSync(internal_)

        default:
            break
        }
    }

    private static let topicNameRegex = try! NSRegularExpression(pattern: "^[a-zA-Z0-9_.\\-]{1,128}$")
    private static let maxTopicsPerSession = 100

    private func processTopicSync(_ internal_: InternalSession) {
        let session = internal_.session

        var newTopics = [(String, [String: Any])]()
        var newTopicSet = Set<String>()
        var nameToIndex = [String: Int]()

        if let reg = internal_.clientRegistry, let vals = internal_.clientValues {
            var indexToName = [String: String]()

            for path in reg.paths {
                guard let entry = reg.getByPath(path) else { continue }

                if path.hasPrefix("topic.") && path.hasSuffix(".name") {
                    let idxStr = String(path.dropFirst(6).dropLast(5))
                    if let topicName = vals[entry.keyId] as? String,
                       !topicName.isEmpty,
                       Self.isValidTopicName(topicName),
                       topicName != BROADCAST_PRINCIPAL,
                       newTopics.count < Self.maxTopicsPerSession {
                        indexToName[idxStr] = topicName
                        nameToIndex[topicName] = Int(idxStr) ?? 0
                        if !newTopicSet.contains(topicName) {
                            newTopics.append((topicName, [:]))
                            newTopicSet.insert(topicName)
                        }
                    }
                } else if path.hasPrefix("topic.") {
                    if let paramIdx = path.range(of: ".param.") {
                        let afterTopic = path.dropFirst(6)
                        let idxStr = String(afterTopic[afterTopic.startIndex..<afterTopic.firstIndex(of: ".")!])
                        let paramKey = String(path[paramIdx.upperBound...])
                        if let topicName = indexToName[idxStr] {
                            let value = vals[entry.keyId]
                            if let idx = newTopics.firstIndex(where: { $0.0 == topicName }) {
                                if let value = value {
                                    newTopics[idx].1[paramKey] = value
                                }
                            }
                        }
                    }
                }
            }
        }

        // Diff: unsubscribed topics
        let oldTopicNames = Set(session.topicNames)
        for oldName in oldTopicNames {
            if !newTopicSet.contains(oldName) {
                if let handle = session.getTopicHandle(oldName) {
                    for cb in topic._onUnsubscribeCbs { cb(session, handle) }
                }
                session._removeTopicHandle(oldName)
                session._removeTopic(oldName)
            }
        }

        // Diff: new / changed topics
        for (name, params) in newTopics {
            let existingHandle = session.getTopicHandle(name)
            let existingInfo = session.topic(name)

            if existingHandle == nil && existingInfo == nil {
                let clientIdx = nameToIndex[name] ?? session._nextTopicIndex
                let handle = session._createTopicHandle(name, params: params, wireIndex: clientIdx)
                for cb in topic._onSubscribeCbs { cb(session, handle) }
            } else {
                let oldParams = existingHandle?.params ?? existingInfo?.params
                if !shallowEqual(oldParams ?? [:], params) {
                    existingHandle?._updateParams(params)
                    session._updateTopicParams(name, params: params)
                }
            }
        }
    }

    // MARK: - Session Disconnect

    private func handleSessionDisconnect(_ uuid: String) {
        frameCounters.removeValue(forKey: uuid)

        guard let internal_ = sessions[uuid] else {
            if let tmp = tmpSessions[uuid] {
                tmpSessions.removeValue(forKey: uuid)
                tmp.heartbeat.stop()
            }
            return
        }

        guard internal_.session.connected else { return }

        internal_.session._disposeAllTopicHandles()
        internal_.session._handleDisconnect()
        internal_.heartbeat.stop()
        internal_.bulkQueue.clear()
        internal_.transport = nil

        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.sessions.removeValue(forKey: uuid)
            let principal = internal_.session.principal
            if let principal = principal, !self.isTopicMode {
                let effectivePrincipal = self.mode == .broadcast ? BROADCAST_PRINCIPAL : principal
                let noSessions = self.principals._removeSession(effectivePrincipal)
                self.indexRemoveSession(effectivePrincipal, internal_)
                if noSessions {
                    self.schedulePrincipalEviction(effectivePrincipal)
                }
            }
            for cb in self.onSessionExpiredCallbacks { cb(internal_.session) }
        }
        internal_.ttlTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(ttl), execute: work)
    }

    // MARK: - Principal Index Management

    private func indexAddSession(_ principal: String, _ internal_: InternalSession) {
        let id = ObjectIdentifier(internal_)
        principalIndexMap[id] = internal_
        if principalIndex[principal] == nil {
            principalIndex[principal] = Set()
        }
        principalIndex[principal]!.insert(id)
    }

    private func indexRemoveSession(_ principal: String, _ internal_: InternalSession) {
        let id = ObjectIdentifier(internal_)
        principalIndexMap.removeValue(forKey: id)
        principalIndex[principal]?.remove(id)
        if principalIndex[principal]?.isEmpty == true {
            principalIndex.removeValue(forKey: principal)
        }
    }

    private func getSessionsForPrincipal(_ principalName: String) -> [InternalSession] {
        guard let ids = principalIndex[principalName] else { return [] }
        return ids.compactMap { principalIndexMap[$0] }
    }

    // MARK: - PrincipalTX Binding

    private func bindPrincipalTX(_ ptx: PrincipalTX) {
        ptx._onValue { [weak self, weak ptx] frame in
            guard let self = self, let ptx = ptx else { return }
            for internal_ in self.getSessionsForPrincipal(ptx.name) {
                if internal_.session.state == .ready,
                   let transport = internal_.transport, transport.isOpen {
                    internal_.bulkQueue.enqueue(frame)
                }
            }
        }

        ptx._onIncremental { [weak self, weak ptx] keyFrame, syncFrame, valueFrame in
            guard let self = self, let ptx = ptx else { return }
            for internal_ in self.getSessionsForPrincipal(ptx.name) {
                if internal_.session.state == .ready,
                   let transport = internal_.transport, transport.isOpen {
                    internal_.bulkQueue.enqueue(keyFrame)
                    internal_.bulkQueue.enqueue(syncFrame)
                    internal_.bulkQueue.enqueue(valueFrame)
                }
            }
        }

        ptx._onResync { [weak self, weak ptx] in
            guard let self = self, let ptx = ptx else { return }
            let keyFrames = ptx._buildKeyFrames()
            for internal_ in self.getSessionsForPrincipal(ptx.name) {
                if internal_.session.connected,
                   let transport = internal_.transport, transport.isOpen {
                    internal_.bulkQueue.enqueue(Frame.signal(.serverReset))
                    for f in keyFrames { internal_.bulkQueue.enqueue(f) }
                }
            }
        }
    }

    // MARK: - Principal Eviction

    private func schedulePrincipalEviction(_ principal: String) {
        guard principalEvictionTtl > 0 else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.principalEvictionTimers.removeValue(forKey: principal)
            if !self.principals._hasActiveSessions(principal) {
                self.log("Evicting principal \"\(principal)\" data")
                self.principals.delete(principal)
            }
        }
        principalEvictionTimers[principal] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(principalEvictionTtl), execute: work)
    }

    private func cancelPrincipalEviction(_ principal: String) {
        if let work = principalEvictionTimers.removeValue(forKey: principal) {
            work.cancel()
        }
    }

    // MARK: - Auth Timeout

    private func startAuthTimeout(clientUuid: String, transport: ServerClientTransport) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(authTimeout)) { [weak self] in
            guard let self = self else { return }
            if let tmp = self.tmpSessions[clientUuid], tmp.authPhase == .awaitingAuth {
                self.tmpSessions.removeValue(forKey: clientUuid)
                transport.close()
            }
        }
    }

    // MARK: - Sending

    private func sendFrame(_ internal_: InternalSession, _ frame: Frame) {
        guard let transport = internal_.transport, transport.isOpen else { return }
        framesOut += 1
        do {
            let data = try Codec.encode(frame)
            transport.send(data)
        } catch {
            log("Failed to encode frame: \(error)")
        }
    }

    // MARK: - Helpers

    private func assertMode(_ expected: ServerMode, _ method: String) {
        if mode != expected {
            fatalError("server.\(method)() is only available in \(expected.rawValue) mode.")
        }
    }

    private func log(_ msg: String) {
        if debug {
            print("[dan-ws server] \(msg)")
        }
    }

    static func bytesToUuid(_ bytes: Data) -> String {
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "\(hex.prefix(8))-\(hex.dropFirst(8).prefix(4))-\(hex.dropFirst(12).prefix(4))-\(hex.dropFirst(16).prefix(4))-\(hex.dropFirst(20))"
    }

    private func shallowEqual(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        guard a.count == b.count else { return false }
        for (key, val) in a {
            guard let bVal = b[key] else { return false }
            if !isEqual(val, bVal) { return false }
        }
        return true
    }

    private func isEqual(_ a: Any, _ b: Any) -> Bool {
        switch (a, b) {
        case (let a as Int, let b as Int): return a == b
        case (let a as Double, let b as Double): return a == b
        case (let a as String, let b as String): return a == b
        case (let a as Bool, let b as Bool): return a == b
        default: return false
        }
    }

    private static func isValidTopicName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return topicNameRegex.firstMatch(in: name, range: range) != nil
    }
}

// MARK: - NWConnection-based Transport

#if canImport(Network)
/// WebSocket transport wrapping an NWConnection (server-side, one per client).
final class NWConnectionTransport: ServerClientTransport {
    private let connection: NWConnection
    private var _isOpen = true

    var onReceive: ((Data) -> Void)?
    var onDisconnect: (() -> Void)?

    var isOpen: Bool { _isOpen }

    init(connection: NWConnection) {
        self.connection = connection
    }

    func send(_ data: Data) {
        guard _isOpen else { return }
        let metadata = NWProtocolWebSocket.Metadata(opcode: .binary)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [metadata])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
    }

    func close() {
        guard _isOpen else { return }
        _isOpen = false
        connection.cancel()
    }

    func startReceiving() {
        receiveMessage()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                self?._isOpen = false
                self?.onDisconnect?()
            default:
                break
            }
        }
    }

    private func receiveMessage() {
        connection.receiveMessage { [weak self] content, context, isComplete, error in
            guard let self = self, self._isOpen else { return }
            if let error = error {
                self._isOpen = false
                self.onDisconnect?()
                return
            }
            if let data = content {
                self.onReceive?(data)
            }
            self.receiveMessage()
        }
    }
}
#endif

// MARK: - Mock Transport for Testing

/// In-memory transport for unit testing without a real network connection.
public final class MockServerTransport: ServerClientTransport {
    public private(set) var sentData = [Data]()
    public private(set) var _isOpen = true

    public var onReceive: ((Data) -> Void)?
    public var onDisconnect: (() -> Void)?

    public var isOpen: Bool { _isOpen }

    public init() {}

    public func send(_ data: Data) {
        guard _isOpen else { return }
        sentData.append(data)
    }

    public func close() {
        guard _isOpen else { return }
        _isOpen = false
        onDisconnect?()
    }

    /// Simulate receiving data from a client.
    public func simulateReceive(_ data: Data) {
        onReceive?(data)
    }

    /// Simulate client disconnect.
    public func simulateDisconnect() {
        close()
    }
}
