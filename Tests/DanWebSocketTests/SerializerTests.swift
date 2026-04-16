import XCTest
@testable import DanWebSocket

final class SerializerTests: XCTestCase {

    // MARK: - Null

    func testNullRoundtrip() throws {
        let data = try Serializer.serialize(.null, .null)
        XCTAssertEqual(data.count, 0)
        let result = try Serializer.deserialize(.null, data)
        XCTAssertEqual(result, .null)
    }

    // MARK: - Bool

    func testBoolTrue() throws {
        let data = try Serializer.serialize(.bool, .bool(true))
        XCTAssertEqual(data, Data([0x01]))
        let result = try Serializer.deserialize(.bool, data)
        XCTAssertEqual(result, .bool(true))
    }

    func testBoolFalse() throws {
        let data = try Serializer.serialize(.bool, .bool(false))
        XCTAssertEqual(data, Data([0x00]))
        let result = try Serializer.deserialize(.bool, data)
        XCTAssertEqual(result, .bool(false))
    }

    // MARK: - Uint8

    func testUint8() throws {
        let data = try Serializer.serialize(.uint8, .uint8(42))
        XCTAssertEqual(data, Data([42]))
        let result = try Serializer.deserialize(.uint8, data)
        XCTAssertEqual(result, .uint8(42))
    }

    // MARK: - Uint16

    func testUint16() throws {
        let data = try Serializer.serialize(.uint16, .uint16(0x1234))
        XCTAssertEqual(data, Data([0x12, 0x34]))
        let result = try Serializer.deserialize(.uint16, data)
        XCTAssertEqual(result, .uint16(0x1234))
    }

    // MARK: - Uint32

    func testUint32() throws {
        let data = try Serializer.serialize(.uint32, .uint32(0x12345678))
        XCTAssertEqual(data, Data([0x12, 0x34, 0x56, 0x78]))
        let result = try Serializer.deserialize(.uint32, data)
        XCTAssertEqual(result, .uint32(0x12345678))
    }

    // MARK: - Int32

    func testInt32Positive() throws {
        let data = try Serializer.serialize(.int32, .int32(42))
        let result = try Serializer.deserialize(.int32, data)
        XCTAssertEqual(result, .int32(42))
    }

    func testInt32Negative() throws {
        let data = try Serializer.serialize(.int32, .int32(-100))
        let result = try Serializer.deserialize(.int32, data)
        XCTAssertEqual(result, .int32(-100))
    }

    // MARK: - Int64

    func testInt64() throws {
        let data = try Serializer.serialize(.int64, .int64(Int64.max))
        let result = try Serializer.deserialize(.int64, data)
        XCTAssertEqual(result, .int64(Int64.max))
    }

    // MARK: - Uint64

    func testUint64() throws {
        let data = try Serializer.serialize(.uint64, .uint64(UInt64.max))
        let result = try Serializer.deserialize(.uint64, data)
        XCTAssertEqual(result, .uint64(UInt64.max))
    }

    // MARK: - Float32

    func testFloat32() throws {
        let data = try Serializer.serialize(.float32, .float32(3.14))
        XCTAssertEqual(data.count, 4)
        let result = try Serializer.deserialize(.float32, data)
        if case .float32(let v) = result {
            XCTAssertEqual(v, 3.14, accuracy: 0.001)
        } else {
            XCTFail("Expected float32")
        }
    }

    // MARK: - Float64

    func testFloat64() throws {
        let data = try Serializer.serialize(.float64, .float64(3.141592653589793))
        XCTAssertEqual(data.count, 8)
        let result = try Serializer.deserialize(.float64, data)
        XCTAssertEqual(result, .float64(3.141592653589793))
    }

    // MARK: - String

    func testString() throws {
        let data = try Serializer.serialize(.string, .string("Hello, World!"))
        let result = try Serializer.deserialize(.string, data)
        XCTAssertEqual(result, .string("Hello, World!"))
    }

    func testStringEmpty() throws {
        let data = try Serializer.serialize(.string, .string(""))
        XCTAssertEqual(data.count, 0)
        let result = try Serializer.deserialize(.string, data)
        XCTAssertEqual(result, .string(""))
    }

    func testStringUnicode() throws {
        let data = try Serializer.serialize(.string, .string("Hello 🌍 World 한글"))
        let result = try Serializer.deserialize(.string, data)
        XCTAssertEqual(result, .string("Hello 🌍 World 한글"))
    }

    // MARK: - Binary

    func testBinary() throws {
        let bytes = Data([0x00, 0x01, 0x10, 0xFF])
        let data = try Serializer.serialize(.binary, .binary(bytes))
        let result = try Serializer.deserialize(.binary, data)
        XCTAssertEqual(result, .binary(bytes))
    }

    // MARK: - Timestamp

    func testTimestamp() throws {
        let date = Date(timeIntervalSince1970: 1700000000.0)
        let data = try Serializer.serialize(.timestamp, .timestamp(date))
        XCTAssertEqual(data.count, 8)
        let result = try Serializer.deserialize(.timestamp, data)
        if case .timestamp(let d) = result {
            XCTAssertEqual(d.timeIntervalSince1970, 1700000000.0, accuracy: 0.001)
        } else {
            XCTFail("Expected timestamp")
        }
    }

    // MARK: - VarInteger

    func testVarIntegerZero() throws {
        let data = Serializer.serializeVarInteger(0)
        XCTAssertEqual(data, Data([0x00]))
        let result = try Serializer.deserializeVarInteger(data)
        XCTAssertEqual(result, 0)
    }

    func testVarIntegerPositive() throws {
        let data = Serializer.serializeVarInteger(1)
        XCTAssertEqual(data, Data([0x02]))
        let result = try Serializer.deserializeVarInteger(data)
        XCTAssertEqual(result, 1)
    }

    func testVarIntegerNegative() throws {
        let data = Serializer.serializeVarInteger(-1)
        XCTAssertEqual(data, Data([0x01]))
        let result = try Serializer.deserializeVarInteger(data)
        XCTAssertEqual(result, -1)
    }

    func testVarInteger42() throws {
        let data = Serializer.serializeVarInteger(42)
        // zigzag(42) = 84 = 0x54
        XCTAssertEqual(data, Data([0x54]))
        let result = try Serializer.deserializeVarInteger(data)
        XCTAssertEqual(result, 42)
    }

    func testVarIntegerMinus42() throws {
        let data = Serializer.serializeVarInteger(-42)
        // zigzag(-42) = 83 = 0x53
        XCTAssertEqual(data, Data([0x53]))
        let result = try Serializer.deserializeVarInteger(data)
        XCTAssertEqual(result, -42)
    }

    func testVarInteger64() throws {
        let data = Serializer.serializeVarInteger(64)
        // zigzag(64) = 128 -> 0x80 0x01
        XCTAssertEqual(data, Data([0x80, 0x01]))
        let result = try Serializer.deserializeVarInteger(data)
        XCTAssertEqual(result, 64)
    }

    func testVarInteger300() throws {
        let data = Serializer.serializeVarInteger(300)
        // zigzag(300) = 600 -> 0xD8 0x04
        XCTAssertEqual(data, Data([0xD8, 0x04]))
        let result = try Serializer.deserializeVarInteger(data)
        XCTAssertEqual(result, 300)
    }

    func testVarInteger100000() throws {
        let data = Serializer.serializeVarInteger(100000)
        // zigzag(100000) = 200000 -> 0xC0 0x9A 0x0C
        XCTAssertEqual(data, Data([0xC0, 0x9A, 0x0C]))
        let result = try Serializer.deserializeVarInteger(data)
        XCTAssertEqual(result, 100000)
    }

    // MARK: - VarDouble

    func testVarDouble3_14() throws {
        let data = Serializer.serializeVarDouble(3.14)
        // scale=2, positive, mantissa=314 -> first byte = 0x02, varint(314) = 0xBA 0x02
        XCTAssertEqual(data, Data([0x02, 0xBA, 0x02]))
        let result = try Serializer.deserializeVarDouble(data)
        XCTAssertEqual(result, 3.14, accuracy: 0.0001)
    }

    func testVarDoubleMinus7_5() throws {
        let data = Serializer.serializeVarDouble(-7.5)
        // scale=1, negative, mantissa=75 -> first byte = 64+1=65=0x41, varint(75) = 0x4B
        XCTAssertEqual(data, Data([0x41, 0x4B]))
        let result = try Serializer.deserializeVarDouble(data)
        XCTAssertEqual(result, -7.5, accuracy: 0.0001)
    }

    func testVarDouble0_001() throws {
        let data = Serializer.serializeVarDouble(0.001)
        // scale=3, positive, mantissa=1 -> first byte = 0x03, varint(1) = 0x01
        XCTAssertEqual(data, Data([0x03, 0x01]))
        let result = try Serializer.deserializeVarDouble(data)
        XCTAssertEqual(result, 0.001, accuracy: 0.00001)
    }

    func testVarDoubleNaN() throws {
        let data = Serializer.serializeVarDouble(Double.nan)
        XCTAssertEqual(data.count, 9) // fallback
        XCTAssertEqual(data[data.startIndex], 0x80) // fallback marker
        let result = try Serializer.deserializeVarDouble(data)
        XCTAssert(result.isNaN)
    }

    func testVarDoubleInfinity() throws {
        let data = Serializer.serializeVarDouble(Double.infinity)
        XCTAssertEqual(data.count, 9) // fallback
        let result = try Serializer.deserializeVarDouble(data)
        XCTAssertEqual(result, Double.infinity)
    }

    // MARK: - VarFloat

    func testVarFloat3_14() throws {
        let data = Serializer.serializeVarFloat(Float(3.14))
        let result = try Serializer.deserializeVarFloat(data)
        XCTAssertEqual(Float(result), Float(3.14), accuracy: 0.01)
    }

    func testVarFloatNaN() throws {
        let data = Serializer.serializeVarFloat(Float.nan)
        XCTAssertEqual(data.count, 5) // fallback float32
        XCTAssertEqual(data[data.startIndex], 0x80)
        let result = try Serializer.deserializeVarFloat(data)
        XCTAssert(result.isNaN)
    }

    // MARK: - Type detection

    func testAutoDetect() {
        XCTAssertEqual(Serializer.detectDataType(nil), .null)
        XCTAssertEqual(Serializer.detectDataType(true), .bool)
        XCTAssertEqual(Serializer.detectDataType(42 as Int), .varInteger)
        XCTAssertEqual(Serializer.detectDataType(3.14 as Double), .varDouble)
        XCTAssertEqual(Serializer.detectDataType("hello"), .string)
        XCTAssertEqual(Serializer.detectDataType(Data()), .binary)
        XCTAssertEqual(Serializer.detectDataType(Date()), .timestamp)
    }
}
