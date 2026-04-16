import Foundation

/// DLE-based framing constants.
public enum DLEConstants {
    public static let DLE: UInt8 = 0x10
    public static let STX: UInt8 = 0x02
    public static let ETX: UInt8 = 0x03
    public static let ENQ: UInt8 = 0x05
}

/// Codec for encoding and decoding DanProtocol frames with DLE framing.
public enum Codec {

    // MARK: - DLE Encoding/Decoding

    /// DLE-stuff a payload: every 0x10 byte becomes 0x10 0x10.
    public static func dleEncode(_ payload: Data) -> Data {
        var dleCount = 0
        for byte in payload {
            if byte == DLEConstants.DLE { dleCount += 1 }
        }
        if dleCount == 0 { return payload }

        var out = Data(capacity: payload.count + dleCount)
        for byte in payload {
            out.append(byte)
            if byte == DLEConstants.DLE {
                out.append(DLEConstants.DLE)
            }
        }
        return out
    }

    /// DLE-unstuff a payload: 0x10 0x10 becomes 0x10.
    public static func dleDecode(_ data: Data) -> Data {
        var dleCount = 0
        var i = data.startIndex
        while i < data.endIndex {
            if data[i] == DLEConstants.DLE {
                i += 1 // skip paired DLE
                dleCount += 1
            }
            i += 1
        }
        if dleCount == 0 { return data }

        var out = Data(capacity: data.count - dleCount)
        i = data.startIndex
        while i < data.endIndex {
            if data[i] == DLEConstants.DLE {
                i += 1 // skip the doubled DLE
            }
            out.append(data[i])
            i += 1
        }
        return out
    }

    // MARK: - Frame Encoding

    /// Encode a single Frame into bytes with DLE STX/ETX framing and DLE escaping.
    public static func encode(_ frame: Frame) throws -> Data {
        // Serialize payload based on frame type
        let rawPayload: Data
        if frame.frameType.isKeyRegistration {
            guard let str = frame.payload.stringValue else {
                throw DanWSError("ENCODE_ERROR", "Key registration payload must be a string")
            }
            rawPayload = str.data(using: .utf8) ?? Data()
        } else if frame.frameType.isSignal {
            rawPayload = Data()
        } else {
            rawPayload = try Serializer.serialize(frame.dataType, frame.payload)
        }

        // Build raw body: [FrameType:1] [KeyID:4 BE] [DataType:1] [Payload:N]
        var rawBody = Data(capacity: 6 + rawPayload.count)
        rawBody.append(frame.frameType.rawValue)
        rawBody.append(UInt8((frame.keyId >> 24) & 0xFF))
        rawBody.append(UInt8((frame.keyId >> 16) & 0xFF))
        rawBody.append(UInt8((frame.keyId >> 8) & 0xFF))
        rawBody.append(UInt8(frame.keyId & 0xFF))
        rawBody.append(frame.dataType.rawValue)
        rawBody.append(rawPayload)

        // DLE-escape the entire body
        let escapedBody = dleEncode(rawBody)

        // Wrap with DLE STX ... DLE ETX
        var result = Data(capacity: 4 + escapedBody.count)
        result.append(DLEConstants.DLE)
        result.append(DLEConstants.STX)
        result.append(escapedBody)
        result.append(DLEConstants.DLE)
        result.append(DLEConstants.ETX)

        return result
    }

    /// Encode multiple frames and concatenate into a single buffer.
    public static func encodeBatch(_ frames: [Frame]) throws -> Data {
        var result = Data()
        for frame in frames {
            result.append(try encode(frame))
        }
        return result
    }

    /// Encode heartbeat: DLE ENQ (2 bytes).
    public static func encodeHeartbeat() -> Data {
        Data([DLEConstants.DLE, DLEConstants.ENQ])
    }

    // MARK: - Frame Decoding

    /// Decode a byte buffer containing one or more frames.
    public static func decode(_ bytes: Data) throws -> [Frame] {
        var frames = [Frame]()
        var i = bytes.startIndex

        while i < bytes.endIndex {
            guard i + 1 < bytes.endIndex else {
                throw DanWSError.frameParse("Unexpected end of data")
            }
            guard bytes[i] == DLEConstants.DLE && bytes[i + 1] == DLEConstants.STX else {
                throw DanWSError.frameParse(
                    "Expected DLE STX at offset \(i - bytes.startIndex), got 0x\(String(bytes[i], radix: 16).leftPadded(to: 2)) 0x\(String(bytes[i + 1], radix: 16).leftPadded(to: 2))"
                )
            }
            i += 2 // skip DLE STX

            let bodyStart = i
            var bodyEnd = -1

            while i < bytes.endIndex {
                if bytes[i] == DLEConstants.DLE {
                    guard i + 1 < bytes.endIndex else {
                        throw DanWSError.frameParse("Unexpected end of data after DLE")
                    }
                    if bytes[i + 1] == DLEConstants.ETX {
                        bodyEnd = i
                        i += 2 // skip DLE ETX
                        break
                    } else if bytes[i + 1] == DLEConstants.DLE {
                        i += 2 // escaped DLE
                    } else {
                        throw DanWSError.invalidDLE(bytes[i + 1])
                    }
                } else {
                    i += 1
                }
            }

            guard bodyEnd >= 0 else {
                throw DanWSError.frameParse("Missing DLE ETX terminator")
            }

            let rawEscaped = bytes.subdata(in: bodyStart..<bodyEnd)
            let decoded = dleDecode(rawEscaped)

            guard decoded.count >= 6 else {
                throw DanWSError.frameParse("Frame body too short: \(decoded.count) bytes (minimum 6)")
            }

            guard let frameType = FrameType(rawValue: decoded[decoded.startIndex]) else {
                throw DanWSError.frameParse("Unknown frame type: 0x\(String(decoded[decoded.startIndex], radix: 16))")
            }

            let keyId = UInt32(decoded[decoded.startIndex + 1]) << 24
                      | UInt32(decoded[decoded.startIndex + 2]) << 16
                      | UInt32(decoded[decoded.startIndex + 3]) << 8
                      | UInt32(decoded[decoded.startIndex + 4])

            guard let dataType = DataType(rawValue: decoded[decoded.startIndex + 5]) else {
                throw DanWSError.unknownDataType(decoded[decoded.startIndex + 5])
            }

            let rawPayload = decoded.subdata(in: (decoded.startIndex + 6)..<decoded.endIndex)

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

            frames.append(Frame(frameType: frameType, keyId: keyId, dataType: dataType, payload: payload))
        }

        return frames
    }
}
