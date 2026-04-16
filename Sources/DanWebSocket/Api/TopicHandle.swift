import Foundation

/// Event types fired on topic callbacks.
public enum TopicEventType: String, Sendable {
    case subscribe = "subscribe"
    case changedParams = "changed_params"
    case delayedTask = "delayed_task"
}

/// Callback type for topic events.
public typealias TopicCallback = (TopicEventType, TopicHandle, DanWebSocketSession) -> Void

/// Payload data store scoped to a single topic instance.
public final class TopicPayload: @unchecked Sendable {
    private let index: Int
    private let allocateKeyId: () -> UInt32
    private var flatState: FlatStateManager
    private let maxValueSize: Int?

    init(index: Int, allocateKeyId: @escaping () -> UInt32, maxValueSize: Int? = nil) {
        self.index = index
        self.allocateKeyId = allocateKeyId
        self.maxValueSize = maxValueSize
        self.flatState = FlatStateManager(cb: FlatStateCallbacks(
            allocateKeyId: allocateKeyId,
            enqueue: { _ in },
            onResync: { },
            wirePrefix: "t.\(index).",
            maxValueSize: maxValueSize
        ))
    }

    func _bind(enqueue: @escaping (Frame) -> Void, onResync: @escaping () -> Void) {
        self.flatState = FlatStateManager(cb: FlatStateCallbacks(
            allocateKeyId: allocateKeyId,
            enqueue: enqueue,
            onResync: onResync,
            wirePrefix: "t.\(index).",
            maxValueSize: maxValueSize
        ))
    }

    /// Set a value within this topic's namespace.
    public func set(_ key: String, _ value: Any?) {
        flatState.set(key, value)
    }

    /// Get a value within this topic's namespace.
    public func get(_ key: String) -> Any? {
        flatState.get(key)
    }

    /// All keys in this topic's namespace.
    public var keys: [String] {
        flatState.keys
    }

    /// Clear a specific key or all keys.
    public func clear(_ key: String? = nil) {
        if let key = key {
            flatState.clear(key)
        } else {
            flatState.clear()
        }
    }

    func _buildKeyFrames() -> [Frame] { flatState.buildKeyFrames() }
    func _buildValueFrames() -> [Frame] { flatState.buildValueFrames() }

    var _size: Int { flatState.size }
    var _idx: Int { index }
}

/// Server-side handle representing a client's subscription to a specific topic.
public final class TopicHandle: @unchecked Sendable {
    /// The topic name.
    public let name: String

    /// The payload store scoped to this topic.
    public let payload: TopicPayload

    private var _params: [String: Any]
    private var callback: TopicCallback?
    private weak var session: DanWebSocketSession?
    private var delayMs: Int?
    private var timer: DispatchSourceTimer?
    private let log: ((String, Error?) -> Void)?

    init(
        name: String,
        params: [String: Any],
        payload: TopicPayload,
        session: DanWebSocketSession,
        log: ((String, Error?) -> Void)? = nil
    ) {
        self.name = name
        self._params = params
        self.payload = payload
        self.session = session
        self.log = log
    }

    /// Current subscription parameters.
    public var params: [String: Any] { _params }

    /// Set the callback for topic lifecycle events (subscribe, params change, delayed task).
    public func setCallback(_ fn: @escaping TopicCallback) {
        callback = fn
        guard let session = session else { return }
        fn(.subscribe, self, session)
    }

    /// Start a repeating delayed task at the given interval.
    public func setDelayedTask(ms: Int) {
        clearDelayedTask()
        delayMs = ms
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + .milliseconds(ms), repeating: .milliseconds(ms))
        source.setEventHandler { [weak self] in
            guard let self = self, let cb = self.callback, let session = self.session else { return }
            cb(.delayedTask, self, session)
        }
        source.resume()
        timer = source
    }

    /// Stop the delayed task timer.
    public func clearDelayedTask() {
        timer?.cancel()
        timer = nil
    }

    // MARK: - Internal

    func _updateParams(_ newParams: [String: Any]) {
        _params = newParams
        let hadTask = timer != nil
        let savedMs = delayMs

        clearDelayedTask()

        if let cb = callback, let session = session {
            cb(.changedParams, self, session)
        }

        if hadTask, let ms = savedMs {
            setDelayedTask(ms: ms)
        }
    }

    func _dispose() {
        clearDelayedTask()
        callback = nil
        delayMs = nil
    }
}

/// Namespace for registering topic subscribe/unsubscribe callbacks.
public final class TopicNamespace: @unchecked Sendable {
    var _onSubscribeCbs = [(DanWebSocketSession, TopicHandle) -> Void]()
    var _onUnsubscribeCbs = [(DanWebSocketSession, TopicHandle) -> Void]()

    /// Register a callback for when a client subscribes to a topic.
    public func onSubscribe(_ cb: @escaping (DanWebSocketSession, TopicHandle) -> Void) {
        _onSubscribeCbs.append(cb)
    }

    /// Register a callback for when a client unsubscribes from a topic.
    public func onUnsubscribe(_ cb: @escaping (DanWebSocketSession, TopicHandle) -> Void) {
        _onUnsubscribeCbs.append(cb)
    }
}
