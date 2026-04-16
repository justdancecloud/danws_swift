import Foundation

/// Frame types for the DanProtocol v3.5 binary protocol.
public enum FrameType: UInt8, Sendable {
    // Server -> Client data
    case serverKeyRegistration = 0x00
    case serverValue           = 0x01

    // Client -> Server data (topic mode)
    case clientKeyRegistration = 0x02
    case clientValue           = 0x03

    // Handshake / sync
    case serverSync            = 0x04
    case clientReady           = 0x05
    case clientSync            = 0x06
    case serverReady           = 0x07

    // Control
    case error                 = 0x08
    case serverReset           = 0x09
    case clientResyncReq       = 0x0A
    case clientReset           = 0x0B
    case serverResyncReq       = 0x0C

    // Authentication
    case identify              = 0x0D
    case auth                  = 0x0E
    case authOk                = 0x0F
    // 0x10 is reserved (DLE control character)
    case authFail              = 0x11

    // Array operations
    case arrayShiftLeft        = 0x20
    case arrayShiftRight       = 0x21

    // Key lifecycle
    case serverKeyDelete       = 0x22
    case clientKeyRequest      = 0x23

    // Batch boundary
    case serverFlushEnd        = 0xFF

    /// Whether this frame type is a signal (no payload).
    public var isSignal: Bool {
        switch self {
        case .serverSync, .clientReady, .clientSync, .serverReady,
             .serverReset, .clientResyncReq, .clientReset, .serverResyncReq,
             .authOk, .serverFlushEnd, .serverKeyDelete, .clientKeyRequest:
            return true
        default:
            return false
        }
    }

    /// Whether this frame type is a key registration.
    public var isKeyRegistration: Bool {
        self == .serverKeyRegistration || self == .clientKeyRegistration
    }
}
