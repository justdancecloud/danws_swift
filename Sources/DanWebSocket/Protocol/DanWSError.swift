import Foundation

/// Error type for DanWebSocket protocol and client errors.
public struct DanWSError: Error, LocalizedError, Sendable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        "[\(code)] \(message)"
    }

    // Common error codes
    public static func frameParse(_ message: String) -> DanWSError {
        DanWSError("FRAME_PARSE_ERROR", message)
    }

    public static func invalidDLE(_ byte: UInt8) -> DanWSError {
        DanWSError("INVALID_DLE_SEQUENCE", "Invalid DLE sequence: 0x10 0x\(String(byte, radix: 16, uppercase: false).leftPadded(to: 2))")
    }

    public static func payloadSizeMismatch(_ typeName: String, expected: Int, got: Int) -> DanWSError {
        DanWSError("PAYLOAD_SIZE_MISMATCH", "\(typeName) expects \(expected) bytes, got \(got)")
    }

    public static func invalidValueType(_ message: String) -> DanWSError {
        DanWSError("INVALID_VALUE_TYPE", message)
    }

    public static func unknownDataType(_ raw: UInt8) -> DanWSError {
        DanWSError("UNKNOWN_DATA_TYPE", "Unknown data type: 0x\(String(raw, radix: 16))")
    }

    public static func heartbeatTimeout() -> DanWSError {
        DanWSError("HEARTBEAT_TIMEOUT", "No heartbeat received within 15 seconds")
    }

    public static func reconnectExhausted() -> DanWSError {
        DanWSError("RECONNECT_EXHAUSTED", "All reconnection attempts exhausted")
    }

    public static func authRejected(_ reason: String) -> DanWSError {
        DanWSError("AUTH_REJECTED", reason)
    }

    public static func remoteError(_ message: String) -> DanWSError {
        DanWSError("REMOTE_ERROR", message)
    }
}

extension String {
    func leftPadded(to length: Int, with character: Character = "0") -> String {
        let deficit = length - count
        if deficit <= 0 { return self }
        return String(repeating: character, count: deficit) + self
    }
}
