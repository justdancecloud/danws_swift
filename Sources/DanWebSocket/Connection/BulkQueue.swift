import Foundation

/// Batches frames for efficient network transmission.
/// Value frames are deduplicated per keyId -- only the latest value is kept.
public final class BulkQueue: @unchecked Sendable {

    private var queue = [Frame]()
    private var valueFrames = [UInt32: Frame]()
    private var timer: DispatchWorkItem?
    private var onFlushHandler: ((Data) -> Void)?
    private var onOverflowHandler: (() -> Void)?
    private let flushInterval: TimeInterval
    private let emitFlushEnd: Bool
    private let maxQueueSize: Int
    private let dispatchQueue: DispatchQueue
    private var disposed = false

    public init(
        flushIntervalMs: Int = 100,
        emitFlushEnd: Bool = false,
        maxQueueSize: Int = 50_000,
        queue: DispatchQueue = .main
    ) {
        self.flushInterval = TimeInterval(flushIntervalMs) / 1000.0
        self.emitFlushEnd = emitFlushEnd
        self.maxQueueSize = maxQueueSize
        self.dispatchQueue = queue
    }

    public func onFlush(_ handler: @escaping (Data) -> Void) {
        onFlushHandler = handler
    }

    public func onOverflow(_ handler: @escaping () -> Void) {
        onOverflowHandler = handler
    }

    /// Enqueue a frame for batched sending.
    public func enqueue(_ frame: Frame) {
        guard !disposed else { return }

        let totalPending = queue.count + valueFrames.count
        if totalPending >= maxQueueSize {
            dispose()
            onOverflowHandler?()
            return
        }

        if isValueFrame(frame.frameType) {
            valueFrames[frame.keyId] = frame
        } else {
            queue.append(frame)
        }

        startTimer()
    }

    /// Immediately flush all queued frames.
    public func flush() {
        stopTimer()

        var frames = queue + Array(valueFrames.values)
        queue.removeAll(keepingCapacity: true)
        valueFrames.removeAll(keepingCapacity: true)

        if frames.isEmpty { return }

        if emitFlushEnd {
            frames.append(.signal(.serverFlushEnd))
        }

        if let handler = onFlushHandler {
            do {
                let data = try Codec.encodeBatch(frames)
                handler(data)
            } catch {
                // Encoding error -- silently drop
            }
        }
    }

    /// Discard all queued frames without sending.
    public func clear() {
        stopTimer()
        queue.removeAll(keepingCapacity: true)
        valueFrames.removeAll(keepingCapacity: true)
    }

    public var pending: Int {
        queue.count + valueFrames.count
    }

    public func dispose() {
        clear()
        onFlushHandler = nil
        disposed = true
    }

    private func startTimer() {
        guard timer == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.timer = nil
            self?.flush()
        }
        timer = work
        dispatchQueue.asyncAfter(deadline: .now() + flushInterval, execute: work)
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func isValueFrame(_ frameType: FrameType) -> Bool {
        frameType == .serverValue || frameType == .clientValue
    }
}
