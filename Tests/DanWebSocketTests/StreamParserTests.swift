import XCTest
@testable import DanWebSocket

final class StreamParserTests: XCTestCase {

    // MARK: - Basic Frame Parsing

    func testParseSingleFrame() throws {
        let parser = StreamParser()
        var frames = [Frame]()
        parser.onFrame { frames.append($0) }

        // Bool true for keyId 1: 10 02 01 00 00 00 01 01 01 10 03
        let data = Data([0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x10, 0x03])
        parser.feed(data)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameType, .serverValue)
        XCTAssertEqual(frames[0].keyId, 1)
        XCTAssertEqual(frames[0].payload, .bool(true))
    }

    func testParseMultipleFrames() throws {
        let parser = StreamParser()
        var frames = [Frame]()
        parser.onFrame { frames.append($0) }

        // Two bool frames
        var data = Data()
        data.append(contentsOf: [0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x10, 0x03])
        data.append(contentsOf: [0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x02, 0x01, 0x00, 0x10, 0x03])
        parser.feed(data)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].payload, .bool(true))
        XCTAssertEqual(frames[1].payload, .bool(false))
    }

    // MARK: - Partial Feed

    func testPartialFeed() throws {
        let parser = StreamParser()
        var frames = [Frame]()
        parser.onFrame { frames.append($0) }

        let fullFrame = Data([0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x10, 0x03])

        // Feed byte by byte
        for byte in fullFrame {
            parser.feed(Data([byte]))
        }

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, .bool(true))
    }

    func testPartialFeedSplitInMiddle() throws {
        let parser = StreamParser()
        var frames = [Frame]()
        parser.onFrame { frames.append($0) }

        // Split in the middle
        let part1 = Data([0x10, 0x02, 0x01, 0x00, 0x00])
        let part2 = Data([0x00, 0x01, 0x01, 0x01, 0x10, 0x03])

        parser.feed(part1)
        XCTAssertEqual(frames.count, 0)
        parser.feed(part2)
        XCTAssertEqual(frames.count, 1)
    }

    // MARK: - DLE Escaping

    func testDLEEscapingInPayload() throws {
        let parser = StreamParser()
        var frames = [Frame]()
        parser.onFrame { frames.append($0) }

        // KeyID 0x00000010 with DLE escaping
        // Frame body: 01 00 00 00 10 0a [payload]
        // After DLE escape: 01 00 00 00 10 10 0a [payload]
        let data = Data([
            0x10, 0x02,                     // DLE STX
            0x01,                           // FrameType = ServerValue
            0x00, 0x00, 0x00, 0x10, 0x10,   // KeyID 0x00000010 (0x10 escaped)
            0x0A,                           // DataType = String
            0x68, 0x69,                     // "hi"
            0x10, 0x03                      // DLE ETX
        ])
        parser.feed(data)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].keyId, 0x00000010)
        XCTAssertEqual(frames[0].payload, .string("hi"))
    }

    // MARK: - Heartbeat

    func testHeartbeatDetection() {
        let parser = StreamParser()
        var heartbeatCount = 0
        var frames = [Frame]()
        parser.onHeartbeat { heartbeatCount += 1 }
        parser.onFrame { frames.append($0) }

        // Heartbeat (DLE ENQ) followed by a frame
        var data = Data()
        data.append(contentsOf: [0x10, 0x05]) // heartbeat
        data.append(contentsOf: [0x10, 0x02, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x03]) // ServerSync
        parser.feed(data)

        XCTAssertEqual(heartbeatCount, 1)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameType, .serverSync)
    }

    func testMultipleHeartbeats() {
        let parser = StreamParser()
        var heartbeatCount = 0
        parser.onHeartbeat { heartbeatCount += 1 }

        let data = Data([0x10, 0x05, 0x10, 0x05, 0x10, 0x05])
        parser.feed(data)

        XCTAssertEqual(heartbeatCount, 3)
    }

    // MARK: - Error Handling

    func testInvalidByteOutsideFrame() {
        let parser = StreamParser()
        var errors = [Error]()
        parser.onError { errors.append($0) }

        parser.feed(Data([0xFF]))

        XCTAssertEqual(errors.count, 1)
    }

    func testInvalidDLESequence() {
        let parser = StreamParser()
        var errors = [Error]()
        parser.onError { errors.append($0) }

        parser.feed(Data([0x10, 0x99])) // Invalid DLE sequence

        XCTAssertEqual(errors.count, 1)
    }

    // MARK: - Reset

    func testReset() {
        let parser = StreamParser()
        var frames = [Frame]()
        parser.onFrame { frames.append($0) }

        // Feed partial frame
        parser.feed(Data([0x10, 0x02, 0x01, 0x00]))
        parser.reset()

        // Feed complete frame
        parser.feed(Data([0x10, 0x02, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x10, 0x03]))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, .bool(true))
    }

    // MARK: - Signal Frames

    func testSignalFrame() throws {
        let parser = StreamParser()
        var frames = [Frame]()
        parser.onFrame { frames.append($0) }

        // ServerSync signal
        let data = Data([0x10, 0x02, 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x03])
        parser.feed(data)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameType, .serverSync)
        XCTAssertEqual(frames[0].payload, .null)
    }

    func testServerFlushEndSignal() throws {
        let parser = StreamParser()
        var frames = [Frame]()
        parser.onFrame { frames.append($0) }

        let data = Data([0x10, 0x02, 0xFF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x03])
        parser.feed(data)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].frameType, .serverFlushEnd)
    }
}
