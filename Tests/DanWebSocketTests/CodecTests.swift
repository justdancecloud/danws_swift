import XCTest
@testable import DanWebSocket

final class CodecTests: XCTestCase {

    // MARK: - DLE Encoding

    func testDleEncodeNoDLE() {
        let input = Data([0x01, 0x02, 0x03])
        let result = Codec.dleEncode(input)
        XCTAssertEqual(result, input)
    }

    func testDleEncodeWithDLE() {
        let input = Data([0x01, 0x10, 0x03])
        let result = Codec.dleEncode(input)
        XCTAssertEqual(result, Data([0x01, 0x10, 0x10, 0x03]))
    }

    func testDleDecodeNoDLE() {
        let input = Data([0x01, 0x02, 0x03])
        let result = Codec.dleDecode(input)
        XCTAssertEqual(result, input)
    }

    func testDleDecodeWithDLE() {
        let input = Data([0x01, 0x10, 0x10, 0x03])
        let result = Codec.dleDecode(input)
        XCTAssertEqual(result, Data([0x01, 0x10, 0x03]))
    }

    func testDleRoundtrip() {
        let input = Data([0x10, 0x10, 0x10, 0x00, 0xFF])
        let encoded = Codec.dleEncode(input)
        let decoded = Codec.dleDecode(encoded)
        XCTAssertEqual(decoded, input)
    }

    // MARK: - Frame Encoding/Decoding

    func testEncodeBoolFrame() throws {
        let frame = Frame(
            frameType: .serverValue,
            keyId: 0x00000001,
            dataType: .bool,
            payload: .bool(true)
        )
        let data = try Codec.encode(frame)

        // Expected: 10 02 01 00 00 00 01 01 01 10 03
        let expected = Data([0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x10, 0x03])
        XCTAssertEqual(data, expected)
    }

    func testDecodesBoolFrame() throws {
        let data = Data([0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x10, 0x03])
        let frames = try Codec.decode(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameType, .serverValue)
        XCTAssertEqual(frames[0].keyId, 1)
        XCTAssertEqual(frames[0].dataType, .bool)
        XCTAssertEqual(frames[0].payload, .bool(true))
    }

    func testEncodeSignalFrame() throws {
        let frame = Frame.signal(.serverSync)
        let data = try Codec.encode(frame)
        // Expected: 10 02 04 00 00 00 00 00 10 03 (10 bytes)
        let expected = Data([0x10, 0x02, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x03])
        XCTAssertEqual(data, expected)
    }

    func testEncodeStringFrame() throws {
        let frame = Frame(
            frameType: .serverValue,
            keyId: 0x00000002,
            dataType: .string,
            payload: .string("Alice")
        )
        let data = try Codec.encode(frame)
        // Expected: 10 02 01 00 00 00 02 0a 41 6c 69 63 65 10 03
        let expected = Data([0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x02, 0x0A, 0x41, 0x6C, 0x69, 0x63, 0x65, 0x10, 0x03])
        XCTAssertEqual(data, expected)
    }

    func testKeyIdWithDLEByte() throws {
        // KeyID 0x00000010 contains a DLE byte -- should be escaped
        let frame = Frame(
            frameType: .serverValue,
            keyId: 0x00000010,
            dataType: .string,
            payload: .string("test")
        )
        let data = try Codec.encode(frame)

        // The KeyID byte 0x10 should be escaped to 0x10 0x10
        let frames = try Codec.decode(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].keyId, 0x00000010)
        XCTAssertEqual(frames[0].payload, .string("test"))
    }

    func testVarIntegerFrame() throws {
        let frame = Frame(
            frameType: .serverValue,
            keyId: 0x00000003,
            dataType: .varInteger,
            payload: .varInteger(42)
        )
        let data = try Codec.encode(frame)
        // Expected: 10 02 01 00 00 00 03 0d 54 10 03
        let expected = Data([0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x03, 0x0D, 0x54, 0x10, 0x03])
        XCTAssertEqual(data, expected)
    }

    func testVarDoubleFrame() throws {
        let frame = Frame(
            frameType: .serverValue,
            keyId: 0x00000004,
            dataType: .varDouble,
            payload: .varDouble(3.14)
        )
        let data = try Codec.encode(frame)
        // Expected: 10 02 01 00 00 00 04 0e 02 ba 02 10 03
        let expected = Data([0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x04, 0x0E, 0x02, 0xBA, 0x02, 0x10, 0x03])
        XCTAssertEqual(data, expected)
    }

    func testKeyRegistrationFrame() throws {
        let frame = Frame(
            frameType: .serverKeyRegistration,
            keyId: 0x00000001,
            dataType: .string,
            payload: .string("sensor.temperature")
        )
        let data = try Codec.encode(frame)
        let decoded = try Codec.decode(data)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].frameType, .serverKeyRegistration)
        XCTAssertEqual(decoded[0].payload, .string("sensor.temperature"))
    }

    func testDecodeBatch() throws {
        let frame1 = Frame(frameType: .serverValue, keyId: 1, dataType: .bool, payload: .bool(true))
        let frame2 = Frame(frameType: .serverValue, keyId: 2, dataType: .varInteger, payload: .varInteger(42))
        let batch = try Codec.encodeBatch([frame1, frame2])
        let decoded = try Codec.decode(batch)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertEqual(decoded[0].payload, .bool(true))
        XCTAssertEqual(decoded[1].payload, .varInteger(42))
    }

    func testHeartbeat() {
        let data = Codec.encodeHeartbeat()
        XCTAssertEqual(data, Data([0x10, 0x05]))
    }

    // MARK: - Roundtrip for all types

    func testRoundtripAllTypes() throws {
        let testCases: [(DataType, DanValue)] = [
            (.null, .null),
            (.bool, .bool(true)),
            (.bool, .bool(false)),
            (.uint8, .uint8(255)),
            (.uint16, .uint16(65535)),
            (.uint32, .uint32(0xDEADBEEF)),
            (.int32, .int32(-12345)),
            (.int64, .int64(-9876543210)),
            (.uint64, .uint64(0xFEDCBA9876543210)),
            (.float32, .float32(1.5)),
            (.float64, .float64(3.141592653589793)),
            (.string, .string("Hello, World!")),
            (.binary, .binary(Data([0x00, 0x10, 0xFF]))),
            (.varInteger, .varInteger(42)),
            (.varInteger, .varInteger(-100)),
            (.varDouble, .varDouble(3.14)),
            (.varDouble, .varDouble(-7.5)),
        ]

        for (i, (dt, val)) in testCases.enumerated() {
            let frame = Frame(frameType: .serverValue, keyId: UInt32(i + 1), dataType: dt, payload: val)
            let encoded = try Codec.encode(frame)
            let decoded = try Codec.decode(encoded)
            XCTAssertEqual(decoded.count, 1, "Test case \(i): \(dt)")
            XCTAssertEqual(decoded[0].keyId, UInt32(i + 1), "Test case \(i): keyId")
            XCTAssertEqual(decoded[0].dataType, dt, "Test case \(i): dataType")

            // Compare values (special case for float32 due to precision)
            if dt == .float32 {
                if case .float32(let expected) = val, case .float32(let actual) = decoded[0].payload {
                    XCTAssertEqual(actual, expected, accuracy: 0.001, "Test case \(i): float32")
                }
            } else {
                XCTAssertEqual(decoded[0].payload, val, "Test case \(i): payload")
            }
        }
    }

    func testArrayShiftLeftFrame() throws {
        // Wire example from spec
        let data = Data([0x10, 0x02, 0x20, 0x00, 0x00, 0x00, 0x05, 0x06, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03])
        let frames = try Codec.decode(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameType, .arrayShiftLeft)
        XCTAssertEqual(frames[0].keyId, 5)
        XCTAssertEqual(frames[0].dataType, .int32)
        XCTAssertEqual(frames[0].payload, .int32(1))
    }

    func testArrayShiftRightFrame() throws {
        let data = Data([0x10, 0x02, 0x21, 0x00, 0x00, 0x00, 0x05, 0x06, 0x00, 0x00, 0x00, 0x01, 0x10, 0x03])
        let frames = try Codec.decode(data)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameType, .arrayShiftRight)
        XCTAssertEqual(frames[0].keyId, 5)
    }
}
