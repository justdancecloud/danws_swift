import Foundation

/// A single DanProtocol frame with type, key ID, data type, and payload.
public struct Frame: Sendable {
    public let frameType: FrameType
    public let keyId: UInt32
    public let dataType: DataType
    public let payload: DanValue

    public init(frameType: FrameType, keyId: UInt32, dataType: DataType, payload: DanValue) {
        self.frameType = frameType
        self.keyId = keyId
        self.dataType = dataType
        self.payload = payload
    }

    /// Create a signal frame (no payload).
    public static func signal(_ frameType: FrameType, keyId: UInt32 = 0) -> Frame {
        Frame(frameType: frameType, keyId: keyId, dataType: .null, payload: .null)
    }
}

/// Type-safe wrapper for DanProtocol values.
public enum DanValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case uint8(UInt8)
    case uint16(UInt16)
    case uint32(UInt32)
    case uint64(UInt64)
    case int32(Int32)
    case int64(Int64)
    case float32(Float)
    case float64(Double)
    case string(String)
    case binary(Data)
    case timestamp(Date)
    case varInteger(Int)
    case varDouble(Double)
    case varFloat(Float)

    /// Convert to Swift `Any?` for use with untyped APIs.
    public var anyValue: Any? {
        switch self {
        case .null: return nil
        case .bool(let v): return v
        case .uint8(let v): return v
        case .uint16(let v): return v
        case .uint32(let v): return v
        case .uint64(let v): return v
        case .int32(let v): return v
        case .int64(let v): return v
        case .float32(let v): return v
        case .float64(let v): return v
        case .string(let v): return v
        case .varInteger(let v): return v
        case .varDouble(let v): return v
        case .varFloat(let v): return v
        case .binary(let v): return v
        case .timestamp(let v): return v
        }
    }

    /// Extract as String, if applicable.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// Extract as Int, if applicable (handles varInteger, int32, uint8, etc.).
    public var intValue: Int? {
        switch self {
        case .varInteger(let v): return v
        case .int32(let v): return Int(v)
        case .uint8(let v): return Int(v)
        case .uint16(let v): return Int(v)
        case .uint32(let v): return Int(v)
        default: return nil
        }
    }

    /// Extract as Double, if applicable.
    public var doubleValue: Double? {
        switch self {
        case .float64(let v): return v
        case .varDouble(let v): return v
        case .float32(let v): return Double(v)
        case .varFloat(let v): return Double(v)
        case .varInteger(let v): return Double(v)
        case .int32(let v): return Double(v)
        case .uint32(let v): return Double(v)
        default: return nil
        }
    }

    /// Extract as Bool, if applicable.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }
}
