import Foundation

/// Wire data types for the DanProtocol v3.5 binary format.
public enum DataType: UInt8, Sendable {
    case null       = 0x00
    case bool       = 0x01
    case uint8      = 0x02
    case uint16     = 0x03
    case uint32     = 0x04
    case uint64     = 0x05
    case int32      = 0x06
    case int64      = 0x07
    case float32    = 0x08
    case float64    = 0x09
    case string     = 0x0A
    case binary     = 0x0B
    case timestamp  = 0x0C
    case varInteger = 0x0D
    case varDouble  = 0x0E
    case varFloat   = 0x0F

    /// Fixed byte size for this data type. Returns -1 for variable-length types.
    public var fixedSize: Int {
        switch self {
        case .null:       return 0
        case .bool:       return 1
        case .uint8:      return 1
        case .uint16:     return 2
        case .uint32:     return 4
        case .uint64:     return 8
        case .int32:      return 4
        case .int64:      return 8
        case .float32:    return 4
        case .float64:    return 8
        case .string:     return -1
        case .binary:     return -1
        case .timestamp:  return 8
        case .varInteger: return -1
        case .varDouble:  return -1
        case .varFloat:   return -1
        }
    }
}
