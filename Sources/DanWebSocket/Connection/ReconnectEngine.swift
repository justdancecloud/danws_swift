import Foundation

/// Configuration options for automatic reconnection.
public struct ReconnectOptions: Sendable {
    public var enabled: Bool
    public var maxRetries: Int        // 0 = unlimited
    public var baseDelay: TimeInterval  // seconds
    public var maxDelay: TimeInterval   // seconds
    public var backoffMultiplier: Double
    public var jitter: Bool

    public init(
        enabled: Bool = true,
        maxRetries: Int = 10,
        baseDelay: TimeInterval = 1.0,
        maxDelay: TimeInterval = 30.0,
        backoffMultiplier: Double = 2.0,
        jitter: Bool = true
    ) {
        self.enabled = enabled
        self.maxRetries = maxRetries
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.backoffMultiplier = backoffMultiplier
        self.jitter = jitter
    }

    public static let `default` = ReconnectOptions()
}

/// Engine that manages exponential-backoff reconnection attempts.
public final class ReconnectEngine: @unchecked Sendable {

    private var _attempt = 0
    private var timer: DispatchWorkItem?
    private var _active = false
    private let options: ReconnectOptions
    private let queue: DispatchQueue

    private var onReconnectHandler: ((Int, TimeInterval) -> Void)?
    private var onExhaustedHandler: (() -> Void)?
    private var onAttemptHandler: (() -> Void)?

    public init(options: ReconnectOptions = .default, queue: DispatchQueue = .main) {
        self.options = options
        self.queue = queue
    }

    public func onReconnect(_ handler: @escaping (Int, TimeInterval) -> Void) {
        onReconnectHandler = handler
    }

    public func onExhausted(_ handler: @escaping () -> Void) {
        onExhaustedHandler = handler
    }

    public func onAttempt(_ handler: @escaping () -> Void) {
        onAttemptHandler = handler
    }

    public var attempt: Int { _attempt }
    public var isActive: Bool { _active }

    /// Start the reconnection cycle.
    public func start() {
        guard options.enabled, !_active else { return }
        _active = true
        _attempt = 0
        scheduleNext()
    }

    /// Stop the reconnection cycle.
    public func stop() {
        _active = false
        _attempt = 0
        timer?.cancel()
        timer = nil
    }

    /// Calculate delay for a given attempt (1-indexed).
    public func calculateDelay(attempt: Int) -> TimeInterval {
        let raw = options.baseDelay * pow(options.backoffMultiplier, Double(attempt - 1))
        let capped = min(raw, options.maxDelay)
        if options.jitter {
            return capped * (0.5 + Double.random(in: 0..<1))
        }
        return capped
    }

    /// Called when a reconnect attempt fails. Schedules the next attempt.
    public func retry() {
        if _active {
            scheduleNext()
        }
    }

    public func dispose() {
        stop()
        onReconnectHandler = nil
        onExhaustedHandler = nil
        onAttemptHandler = nil
    }

    private func scheduleNext() {
        _attempt += 1

        if options.maxRetries > 0 && _attempt > options.maxRetries {
            _active = false
            onExhaustedHandler?()
            return
        }

        let delay = calculateDelay(attempt: _attempt)
        onReconnectHandler?(_attempt, delay)

        let work = DispatchWorkItem { [weak self] in
            self?.timer = nil
            self?.onAttemptHandler?()
        }
        timer = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
