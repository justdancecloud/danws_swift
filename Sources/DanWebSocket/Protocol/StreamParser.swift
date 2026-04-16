import Foundation

/// Incremental stream parser for DanProtocol frames.
/// Handles partial data, DLE escaping, and heartbeat detection.
public final class StreamParser: @unchecked Sendable {

    public typealias FrameHandler = (Frame) -> Void
    public typealias HeartbeatHandler = () -> Void
    public typealias ErrorHandler = (Error) -> Void

    private enum State {
        case idle
        case afterDLE       // saw DLE outside a frame
        case inFrame
        case inFrameAfterDLE // saw DLE inside a frame
    }

    private var state: State = .idle
    private var buffer: [UInt8]
    private let maxBufferSize: Int

    private var frameHandler: FrameHandler?
    private var heartbeatHandler: HeartbeatHandler?
    private var errorHandler: ErrorHandler?

    public init(maxBufferSize: Int = 1_048_576) {
        self.maxBufferSize = maxBufferSize
        self.buffer = []
        self.buffer.reserveCapacity(4096)
    }

    public func onFrame(_ handler: @escaping FrameHandler) {
        frameHandler = handler
    }

    public func onHeartbeat(_ handler: @escaping HeartbeatHandler) {
        heartbeatHandler = handler
    }

    public func onError(_ handler: @escaping ErrorHandler) {
        errorHandler = handler
    }

    public func reset() {
        state = .idle
        buffer.removeAll(keepingCapacity: true)
    }

    /// Feed a chunk of bytes into the parser.
    public func feed(_ chunk: Data) {
        for byte in chunk {
            processByte(byte)
        }
    }

    /// Feed raw bytes into the parser.
    public func feed(_ bytes: [UInt8]) {
        for byte in bytes {
            processByte(byte)
        }
    }

    private func processByte(_ byte: UInt8) {
        switch state {
        case .idle:
            if byte == DLEConstants.DLE {
                state = .afterDLE
            } else {
                emitError(DanWSError.frameParse(
                    "Unexpected byte 0x\(String(byte, radix: 16).leftPadded(to: 2)) outside frame"
                ))
            }

        case .afterDLE:
            if byte == DLEConstants.STX {
                state = .inFrame
                buffer.removeAll(keepingCapacity: true)
            } else if byte == DLEConstants.ENQ {
                heartbeatHandler?()
                state = .idle
            } else {
                emitError(DanWSError.invalidDLE(byte))
                state = .idle
            }

        case .inFrame:
            if byte == DLEConstants.DLE {
                state = .inFrameAfterDLE
            } else {
                if buffer.count >= maxBufferSize {
                    emitError(DanWSError("FRAME_TOO_LARGE", "Frame exceeds \(maxBufferSize) bytes"))
                    buffer.removeAll(keepingCapacity: true)
                    state = .idle
                } else {
                    buffer.append(byte)
                }
            }

        case .inFrameAfterDLE:
            if byte == DLEConstants.ETX {
                // Frame complete -- parse the accumulated body
                parseFrame()
                buffer.removeAll(keepingCapacity: true)
                state = .idle
            } else if byte == DLEConstants.DLE {
                // Escaped DLE -- decode immediately, store single 0x10
                buffer.append(DLEConstants.DLE)
                state = .inFrame
            } else {
                emitError(DanWSError.invalidDLE(byte))
                buffer.removeAll(keepingCapacity: true)
                state = .idle
            }
        }
    }

    private func parseFrame() {
        let body = Data(buffer)
        guard body.count >= 6 else {
            emitError(DanWSError.frameParse("Frame body too short: \(body.count) bytes"))
            return
        }

        guard let frameType = FrameType(rawValue: body[0]) else {
            emitError(DanWSError.frameParse("Unknown frame type: 0x\(String(body[0], radix: 16))"))
            return
        }

        let keyId = UInt32(body[1]) << 24
                  | UInt32(body[2]) << 16
                  | UInt32(body[3]) << 8
                  | UInt32(body[4])

        guard let dataType = DataType(rawValue: body[5]) else {
            emitError(DanWSError.unknownDataType(body[5]))
            return
        }

        let rawPayload = body.subdata(in: 6..<body.count)

        do {
            let payload: DanValue
            if frameType.isKeyRegistration {
                guard let str = String(data: rawPayload, encoding: .utf8) else {
                    throw DanWSError.invalidValueType("Invalid UTF-8 key path")
                }
                payload = .string(str)
            } else if frameType.isSignal {
                payload = .null
            } else {
                payload = try Serializer.deserialize(dataType, rawPayload)
            }

            let frame = Frame(frameType: frameType, keyId: keyId, dataType: dataType, payload: payload)
            frameHandler?(frame)
        } catch {
            emitError(error)
        }
    }

    private func emitError(_ error: Error) {
        errorHandler?(error)
    }
}
