import Foundation

/// Manages heartbeat sending and timeout detection.
public final class HeartbeatManager: @unchecked Sendable {

    private static let sendInterval: TimeInterval = 10.0   // 10 seconds
    private static let timeoutThreshold: TimeInterval = 15.0 // 15 seconds
    private static let checkInterval: TimeInterval = 5.0    // 5 seconds

    private var sendTimer: DispatchSourceTimer?
    private var timeoutTimer: DispatchSourceTimer?
    private var lastReceived: Date = Date()
    private let queue: DispatchQueue

    private var onSendHandler: ((Data) -> Void)?
    private var onTimeoutHandler: (() -> Void)?

    public init(queue: DispatchQueue = .main) {
        self.queue = queue
    }

    public func onSend(_ handler: @escaping (Data) -> Void) {
        onSendHandler = handler
    }

    public func onTimeout(_ handler: @escaping () -> Void) {
        onTimeoutHandler = handler
    }

    public func start() {
        stop()
        lastReceived = Date()

        // Send heartbeat every 10s
        let send = DispatchSource.makeTimerSource(queue: queue)
        send.schedule(deadline: .now() + Self.sendInterval, repeating: Self.sendInterval)
        send.setEventHandler { [weak self] in
            self?.onSendHandler?(Codec.encodeHeartbeat())
        }
        send.resume()
        sendTimer = send

        // Check timeout every 5s
        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + Self.checkInterval, repeating: Self.checkInterval)
        timeout.setEventHandler { [weak self] in
            guard let self = self else { return }
            let elapsed = Date().timeIntervalSince(self.lastReceived)
            if elapsed > Self.timeoutThreshold {
                self.stop()
                self.onTimeoutHandler?()
            }
        }
        timeout.resume()
        timeoutTimer = timeout
    }

    /// Called when any message is received from the remote side.
    public func received() {
        lastReceived = Date()
    }

    public func stop() {
        sendTimer?.cancel()
        sendTimer = nil
        timeoutTimer?.cancel()
        timeoutTimer = nil
    }

    public var isRunning: Bool {
        sendTimer != nil
    }

    public func dispose() {
        stop()
        onSendHandler = nil
        onTimeoutHandler = nil
    }
}
