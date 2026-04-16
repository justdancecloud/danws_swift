import Foundation

/// Serialization and deserialization of DanProtocol typed values.
public enum Serializer {

    // MARK: - Serialize

    /// Serialize a DanValue according to its DataType into raw bytes.
    public static func serialize(_ dataType: DataType, _ value: DanValue) throws -> Data {
        switch dataType {
        case .null:
            return Data()

        case .bool:
            guard case .bool(let v) = value else {
                throw DanWSError.invalidValueType("Bool requires .bool value")
            }
            return Data([v ? 0x01 : 0x00])

        case .uint8:
            guard case .uint8(let v) = value else {
                throw DanWSError.invalidValueType("Uint8 requires .uint8 value")
            }
            return Data([v])

        case .uint16:
            guard case .uint16(let v) = value else {
                throw DanWSError.invalidValueType("Uint16 requires .uint16 value")
            }
            return bigEndian(v)

        case .uint32:
            guard case .uint32(let v) = value else {
                throw DanWSError.invalidValueType("Uint32 requires .uint32 value")
            }
            return bigEndian(v)

        case .uint64:
            guard case .uint64(let v) = value else {
                throw DanWSError.invalidValueType("Uint64 requires .uint64 value")
            }
            return bigEndian(v)

        case .int32:
            guard case .int32(let v) = value else {
                throw DanWSError.invalidValueType("Int32 requires .int32 value")
            }
            return bigEndian(v)

        case .int64:
            guard case .int64(let v) = value else {
                throw DanWSError.invalidValueType("Int64 requires .int64 value")
            }
            return bigEndian(v)

        case .float32:
            guard case .float32(let v) = value else {
                throw DanWSError.invalidValueType("Float32 requires .float32 value")
            }
            return bigEndianFloat(v)

        case .float64:
            guard case .float64(let v) = value else {
                throw DanWSError.invalidValueType("Float64 requires .float64 value")
            }
            return bigEndianDouble(v)

        case .string:
            guard case .string(let v) = value else {
                throw DanWSError.invalidValueType("String requires .string value")
            }
            guard let data = v.data(using: .utf8) else {
                throw DanWSError.invalidValueType("String is not valid UTF-8")
            }
            return data

        case .binary:
            guard case .binary(let v) = value else {
                throw DanWSError.invalidValueType("Binary requires .binary value")
            }
            return v

        case .timestamp:
            guard case .timestamp(let v) = value else {
                throw DanWSError.invalidValueType("Timestamp requires .timestamp value")
            }
            let ms = UInt64(v.timeIntervalSince1970 * 1000)
            return bigEndian(ms)

        case .varInteger:
            guard case .varInteger(let v) = value else {
                throw DanWSError.invalidValueType("VarInteger requires .varInteger value")
            }
            return serializeVarInteger(v)

        case .varDouble:
            guard case .varDouble(let v) = value else {
                throw DanWSError.invalidValueType("VarDouble requires .varDouble value")
            }
            return serializeVarDouble(v)

        case .varFloat:
            guard case .varFloat(let v) = value else {
                throw DanWSError.invalidValueType("VarFloat requires .varFloat value")
            }
            return serializeVarFloat(v)
        }
    }

    // MARK: - Deserialize

    /// Deserialize raw bytes into a DanValue according to the DataType.
    public static func deserialize(_ dataType: DataType, _ payload: Data) throws -> DanValue {
        let expectedSize = dataType.fixedSize
        if expectedSize >= 0 && payload.count != expectedSize {
            throw DanWSError.payloadSizeMismatch(
                String(describing: dataType),
                expected: expectedSize,
                got: payload.count
            )
        }

        switch dataType {
        case .null:
            return .null

        case .bool:
            if payload[payload.startIndex] == 0x01 { return .bool(true) }
            if payload[payload.startIndex] == 0x00 { return .bool(false) }
            throw DanWSError.invalidValueType("Bool payload must be 0x00 or 0x01, got 0x\(String(payload[payload.startIndex], radix: 16))")

        case .uint8:
            return .uint8(payload[payload.startIndex])

        case .uint16:
            return .uint16(readBigEndianUInt16(payload))

        case .uint32:
            return .uint32(readBigEndianUInt32(payload))

        case .uint64:
            return .uint64(readBigEndianUInt64(payload))

        case .int32:
            return .int32(readBigEndianInt32(payload))

        case .int64:
            return .int64(readBigEndianInt64(payload))

        case .float32:
            return .float32(readBigEndianFloat(payload))

        case .float64:
            return .float64(readBigEndianDouble(payload))

        case .string:
            guard let str = String(data: payload, encoding: .utf8) else {
                throw DanWSError.invalidValueType("Invalid UTF-8 data")
            }
            return .string(str)

        case .binary:
            return .binary(Data(payload))

        case .timestamp:
            let ms = readBigEndianUInt64(payload)
            let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
            return .timestamp(date)

        case .varInteger:
            return .varInteger(try deserializeVarInteger(payload))

        case .varDouble:
            return .varDouble(try deserializeVarDouble(payload))

        case .varFloat:
            return .varFloat(Float(try deserializeVarFloat(payload)))
        }
    }

    // MARK: - Big-Endian Helpers

    private static func bigEndian(_ v: UInt16) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 2)
    }

    private static func bigEndian(_ v: UInt32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private static func bigEndian(_ v: UInt64) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 8)
    }

    private static func bigEndian(_ v: Int32) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 4)
    }

    private static func bigEndian(_ v: Int64) -> Data {
        var be = v.bigEndian
        return Data(bytes: &be, count: 8)
    }

    private static func bigEndianFloat(_ v: Float) -> Data {
        var bits = v.bitPattern.bigEndian
        return Data(bytes: &bits, count: 4)
    }

    private static func bigEndianDouble(_ v: Double) -> Data {
        var bits = v.bitPattern.bigEndian
        return Data(bytes: &bits, count: 8)
    }

    private static func readBigEndianUInt16(_ data: Data) -> UInt16 {
        data.withUnsafeBytes { buf in
            UInt16(bigEndian: buf.loadUnaligned(as: UInt16.self))
        }
    }

    private static func readBigEndianUInt32(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { buf in
            UInt32(bigEndian: buf.loadUnaligned(as: UInt32.self))
        }
    }

    private static func readBigEndianUInt64(_ data: Data) -> UInt64 {
        data.withUnsafeBytes { buf in
            UInt64(bigEndian: buf.loadUnaligned(as: UInt64.self))
        }
    }

    private static func readBigEndianInt32(_ data: Data) -> Int32 {
        data.withUnsafeBytes { buf in
            Int32(bigEndian: buf.loadUnaligned(as: Int32.self))
        }
    }

    private static func readBigEndianInt64(_ data: Data) -> Int64 {
        data.withUnsafeBytes { buf in
            Int64(bigEndian: buf.loadUnaligned(as: Int64.self))
        }
    }

    private static func readBigEndianFloat(_ data: Data) -> Float {
        let bits = readBigEndianUInt32(data)
        return Float(bitPattern: bits)
    }

    private static func readBigEndianDouble(_ data: Data) -> Double {
        let bits = readBigEndianUInt64(data)
        return Double(bitPattern: bits)
    }

    // MARK: - VarInt Encoding (protobuf-style unsigned)

    static func encodeVarInt(_ value: UInt64) -> Data {
        if value == 0 { return Data([0]) }
        var v = value
        var bytes = [UInt8]()
        while v > 0 {
            var b = UInt8(v & 0x7F)
            v >>= 7
            if v > 0 { b |= 0x80 }
            bytes.append(b)
        }
        return Data(bytes)
    }

    static func decodeVarInt(_ data: Data, offset: Int = 0) -> UInt64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        var i = data.startIndex + offset
        while i < data.endIndex {
            let b = data[i]
            value += UInt64(b & 0x7F) << shift
            shift += 7
            i += 1
            if (b & 0x80) == 0 { break }
        }
        return value
    }

    // MARK: - VarInteger (0x0D)

    static func serializeVarInteger(_ value: Int) -> Data {
        // Zigzag encode: 0->0, -1->1, 1->2, -2->3, 2->4, ...
        let zigzag: UInt64
        if value >= 0 {
            zigzag = UInt64(value) * 2
        } else {
            zigzag = UInt64(-value) * 2 - 1
        }
        return encodeVarInt(zigzag)
    }

    static func deserializeVarInteger(_ payload: Data) throws -> Int {
        if payload.isEmpty {
            throw DanWSError.payloadSizeMismatch("VarInteger", expected: 1, got: 0)
        }
        let zigzag = decodeVarInt(payload)
        // Zigzag decode
        if (zigzag & 1) != 0 {
            return -Int(zigzag / 2) - 1
        } else {
            return Int(zigzag / 2)
        }
    }

    // MARK: - VarDouble (0x0E)

    static func serializeVarDouble(_ value: Double) -> Data {
        // Fallback cases
        if value.isNaN || value.isInfinite || value.isZero && value.sign == .minus {
            return fallbackFloat64(value)
        }

        let abs = Swift.abs(value)
        let str = formatDecimal(abs)

        // Check for scientific notation
        if str.contains("e") || str.contains("E") {
            return fallbackFloat64(value)
        }

        var scale = 0
        var mantissa: UInt64 = 0

        if let dotIdx = str.firstIndex(of: ".") {
            scale = str.distance(from: str.index(after: dotIdx), to: str.endIndex)
            if scale > 63 { return fallbackFloat64(value) }
            let clean = str.replacingOccurrences(of: ".", with: "")
            guard let m = UInt64(clean) else {
                return fallbackFloat64(value)
            }
            mantissa = m
        } else {
            guard let m = UInt64(str) else {
                return fallbackFloat64(value)
            }
            mantissa = m
        }

        // Check max safe integer (2^53 - 1)
        if mantissa > 9007199254740991 {
            return fallbackFloat64(value)
        }

        let negative = value < 0
        let firstByte = UInt8(negative ? (scale + 64) : scale)
        let varint = encodeVarInt(mantissa)
        var result = Data(capacity: 1 + varint.count)
        result.append(firstByte)
        result.append(varint)
        return result
    }

    static func deserializeVarDouble(_ payload: Data) throws -> Double {
        if payload.isEmpty {
            throw DanWSError.payloadSizeMismatch("VarDouble", expected: 1, got: 0)
        }

        let firstByte = payload[payload.startIndex]

        if firstByte == 0x80 {
            // Fallback Float64
            if payload.count < 9 {
                throw DanWSError.payloadSizeMismatch("VarDouble fallback", expected: 9, got: payload.count)
            }
            return readBigEndianDouble(payload.subdata(in: (payload.startIndex + 1)..<(payload.startIndex + 9)))
        }

        let negative = firstByte >= 64
        let scale = negative ? Int(firstByte) - 64 : Int(firstByte)

        let mantissa = decodeVarInt(payload, offset: 1)

        var result = Double(mantissa) / pow(10.0, Double(scale))
        if negative { result = -result }
        return result
    }

    // MARK: - VarFloat (0x0F)

    static func serializeVarFloat(_ value: Float) -> Data {
        let doubleVal = Double(value)
        if value.isNaN || value.isInfinite || value.isZero && value.sign == .minus {
            return fallbackFloat32(value)
        }

        let abs = Swift.abs(doubleVal)
        let str = formatDecimal(abs)

        if str.contains("e") || str.contains("E") {
            return fallbackFloat32(value)
        }

        var scale = 0
        var mantissa: UInt64 = 0

        if let dotIdx = str.firstIndex(of: ".") {
            scale = str.distance(from: str.index(after: dotIdx), to: str.endIndex)
            if scale > 63 { return fallbackFloat32(value) }
            let clean = str.replacingOccurrences(of: ".", with: "")
            guard let m = UInt64(clean) else {
                return fallbackFloat32(value)
            }
            mantissa = m
        } else {
            guard let m = UInt64(str) else {
                return fallbackFloat32(value)
            }
            mantissa = m
        }

        if mantissa > 9007199254740991 {
            return fallbackFloat32(value)
        }

        let negative = value < 0
        let firstByte = UInt8(negative ? (scale + 64) : scale)
        let varint = encodeVarInt(mantissa)
        var result = Data(capacity: 1 + varint.count)
        result.append(firstByte)
        result.append(varint)
        return result
    }

    static func deserializeVarFloat(_ payload: Data) throws -> Double {
        if payload.isEmpty {
            throw DanWSError.payloadSizeMismatch("VarFloat", expected: 1, got: 0)
        }

        let firstByte = payload[payload.startIndex]

        if firstByte == 0x80 {
            // Fallback Float32 (4 bytes)
            if payload.count < 5 {
                throw DanWSError.payloadSizeMismatch("VarFloat fallback", expected: 5, got: payload.count)
            }
            return Double(readBigEndianFloat(payload.subdata(in: (payload.startIndex + 1)..<(payload.startIndex + 5))))
        }

        let negative = firstByte >= 64
        let scale = negative ? Int(firstByte) - 64 : Int(firstByte)

        let mantissa = decodeVarInt(payload, offset: 1)

        var result = Double(mantissa) / pow(10.0, Double(scale))
        if negative { result = -result }
        return result
    }

    // MARK: - Fallback helpers

    private static func fallbackFloat64(_ value: Double) -> Data {
        var result = Data(capacity: 9)
        result.append(0x80)
        result.append(bigEndianDouble(value))
        return result
    }

    private static func fallbackFloat32(_ value: Float) -> Data {
        var result = Data(capacity: 5)
        result.append(0x80)
        result.append(bigEndianFloat(value))
        return result
    }

    /// Format a decimal number to a string without scientific notation.
    /// Uses the same approach as TS: string representation to determine scale.
    private static func formatDecimal(_ value: Double) -> String {
        // Use a formatter that avoids scientific notation
        if value == value.rounded(.towardZero) && value < 1e15 {
            return String(format: "%.0f", value)
        }
        // Try to find exact decimal representation
        let str = "\(value)"
        if str.contains("e") || str.contains("E") {
            // Fallback: use Decimal for exact representation
            let dec = Decimal(value)
            return "\(dec)"
        }
        return str
    }

    // MARK: - Auto-detect data type

    /// Auto-detect the DataType for a given Swift value.
    public static func detectDataType(_ value: Any?) -> DataType {
        guard let value = value else { return .null }
        switch value {
        case is Bool: return .bool
        case let v as Int:
            if v >= 0 && v <= Int(UInt64.max) { return .varInteger }
            return .varInteger
        case is Int32: return .varInteger
        case is UInt32: return .varInteger
        case is Int64: return .varInteger
        case is UInt64: return .uint64
        case let v as Double:
            if v == v.rounded(.towardZero) && !v.isNaN && !v.isInfinite {
                return .varInteger
            }
            return .varDouble
        case is Float: return .varFloat
        case is String: return .string
        case is Data: return .binary
        case is Date: return .timestamp
        default: return .string
        }
    }

    /// Convert a Swift `Any?` to a `DanValue` with auto-detected type.
    public static func toDanValue(_ value: Any?) -> (DataType, DanValue) {
        guard let value = value else { return (.null, .null) }
        switch value {
        case let v as Bool: return (.bool, .bool(v))
        case let v as Int: return (.varInteger, .varInteger(v))
        case let v as Int32: return (.varInteger, .varInteger(Int(v)))
        case let v as UInt32: return (.varInteger, .varInteger(Int(v)))
        case let v as Int64: return (.varInteger, .varInteger(Int(v)))
        case let v as UInt64: return (.uint64, .uint64(v))
        case let v as Double:
            if v == v.rounded(.towardZero) && !v.isNaN && !v.isInfinite && abs(v) < 9007199254740991 {
                return (.varInteger, .varInteger(Int(v)))
            }
            return (.varDouble, .varDouble(v))
        case let v as Float: return (.varFloat, .varFloat(v))
        case let v as String: return (.string, .string(v))
        case let v as Data: return (.binary, .binary(v))
        case let v as Date: return (.timestamp, .timestamp(v))
        default:
            return (.string, .string(String(describing: value)))
        }
    }
}
