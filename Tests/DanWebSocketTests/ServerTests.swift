import XCTest
@testable import DanWebSocket

// MARK: - Test Helpers

/// A pair of mock transports that simulate a client connected to the server.
/// The server sees `serverSide`; tests feed frames via `serverSide.simulateReceive`.
private func buildIdentifyPayload(uuid: String = "01234567-89ab-cdef-0123-456789abcdef") -> Data {
    let hex = uuid.replacingOccurrences(of: "-", with: "")
    var bytes = Data(capacity: 18)
    var i = hex.startIndex
    while i < hex.endIndex {
        let nextIdx = hex.index(i, offsetBy: 2)
        let byteStr = hex[i..<nextIdx]
        if let b = UInt8(byteStr, radix: 16) {
            bytes.append(b)
        }
        i = nextIdx
    }
    // Protocol version 3.5
    bytes.append(3)
    bytes.append(5)
    return bytes
}

private func encodeFrame(_ frame: Frame) -> Data {
    try! Codec.encode(frame)
}

private func makeIdentifyFrame(uuid: String = "01234567-89ab-cdef-0123-456789abcdef") -> Data {
    let payload = buildIdentifyPayload(uuid: uuid)
    return encodeFrame(Frame(
        frameType: .identify,
        keyId: 0,
        dataType: .binary,
        payload: .binary(payload)
    ))
}

private func makeClientReadyFrame() -> Data {
    encodeFrame(Frame.signal(.clientReady))
}

private func makeAuthFrame(token: String) -> Data {
    encodeFrame(Frame(
        frameType: .auth,
        keyId: 0,
        dataType: .string,
        payload: .string(token)
    ))
}

/// Parse all frames from accumulated sent data on a MockServerTransport.
private func parseSentFrames(_ transport: MockServerTransport) -> [Frame] {
    var frames = [Frame]()
    for data in transport.sentData {
        let parser = StreamParser()
        var parsed = [Frame]()
        parser.onFrame { f in parsed.append(f) }
        parser.onError { _ in }
        parser.feed(data)
        frames.append(contentsOf: parsed)
    }
    return frames
}

/// Wait for async flush by spinning the run loop briefly.
private func flushRunLoop(ms: Int = 200) {
    let deadline = Date().addingTimeInterval(Double(ms) / 1000.0)
    while Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
}

// MARK: - Broadcast Mode Tests

final class ServerBroadcastTests: XCTestCase {

    func testSetAndGet() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        server.set("score", 100)
        XCTAssertEqual(server.get("score") as? Int, 100)

        server.set("name", "Alice")
        XCTAssertEqual(server.get("name") as? String, "Alice")
    }

    func testKeys() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        server.set("a", 1)
        server.set("b", 2)
        let keys = Set(server.keys)
        XCTAssertTrue(keys.contains("a"))
        XCTAssertTrue(keys.contains("b"))
    }

    func testClearSingleKey() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        server.set("x", 10)
        server.set("y", 20)
        server.clear("x")
        XCTAssertNil(server.get("x"))
        XCTAssertEqual(server.get("y") as? Int, 20)
    }

    func testClearAll() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        server.set("a", 1)
        server.set("b", 2)
        server.clear()
        XCTAssertTrue(server.keys.isEmpty)
    }

    func testClientReceivesState() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        server.set("score", 42)

        let transport = MockServerTransport()
        server.handleConnection(transport)

        // Send IDENTIFY
        transport.simulateReceive(makeIdentifyFrame())
        flushRunLoop(ms: 300)

        // Send CLIENT_READY
        transport.simulateReceive(makeClientReadyFrame())
        flushRunLoop(ms: 300)

        // Parse sent frames
        let frames = parseSentFrames(transport)

        // Should contain ServerKeyRegistration, ServerSync, and ServerValue for "score"
        let keyRegs = frames.filter { $0.frameType == .serverKeyRegistration }
        let syncs = frames.filter { $0.frameType == .serverSync }
        let values = frames.filter { $0.frameType == .serverValue }

        XCTAssertFalse(keyRegs.isEmpty, "Should have key registration frames")
        XCTAssertFalse(syncs.isEmpty, "Should have sync frames")
        XCTAssertFalse(values.isEmpty, "Should have value frames")

        // Verify the key registration contains "score"
        let scorePath = keyRegs.first { $0.payload.stringValue == "score" }
        XCTAssertNotNil(scorePath, "Should register 'score' key")
    }

    func testOnConnectionCallback() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        var connectedSessionId: String?
        server.onConnection { session in
            connectedSessionId = session.id
        }

        let transport = MockServerTransport()
        server.handleConnection(transport)
        transport.simulateReceive(makeIdentifyFrame())
        flushRunLoop(ms: 150)

        XCTAssertEqual(connectedSessionId, "01234567-89ab-cdef-0123-456789abcdef")
    }

    func testPushValueAfterClientReady() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        let transport = MockServerTransport()
        server.handleConnection(transport)

        transport.simulateReceive(makeIdentifyFrame())
        flushRunLoop(ms: 300)
        transport.simulateReceive(makeClientReadyFrame())
        flushRunLoop(ms: 300)

        // Clear accumulated data to isolate the push
        transport.sentData.removeAll()

        // Now push a value
        server.set("live", "update")
        flushRunLoop(ms: 300)

        let frames = parseSentFrames(transport)
        let values = frames.filter { $0.frameType == .serverValue }
        XCTAssertFalse(values.isEmpty, "Should push value frame after set()")
    }
}

// MARK: - Principal Mode Tests

final class ServerPrincipalTests: XCTestCase {

    func testPrincipalIsolation() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .principal))
        defer { server.close() }

        let ptxAlice = server.principal("alice")
        let ptxBob = server.principal("bob")

        ptxAlice.set("score", 100)
        ptxBob.set("score", 200)

        XCTAssertEqual(ptxAlice.get("score") as? Int, 100)
        XCTAssertEqual(ptxBob.get("score") as? Int, 200)
    }

    func testPrincipalKeys() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .principal))
        defer { server.close() }

        let ptx = server.principal("user1")
        ptx.set("a", 1)
        ptx.set("b", "hello")

        let keys = Set(ptx.keys)
        XCTAssertTrue(keys.contains("a"))
        XCTAssertTrue(keys.contains("b"))
    }

    func testPrincipalClear() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .principal))
        defer { server.close() }

        let ptx = server.principal("user1")
        ptx.set("a", 1)
        ptx.set("b", 2)
        ptx.clear("a")

        XCTAssertNil(ptx.get("a"))
        XCTAssertEqual(ptx.get("b") as? Int, 2)

        ptx.clear()
        XCTAssertTrue(ptx.keys.isEmpty)
    }
}

// MARK: - Auth Tests

final class ServerAuthTests: XCTestCase {

    func testAuthReject() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        server.enableAuthorization(true, timeout: 5000)
        defer { server.close() }

        var receivedToken: String?
        server.onAuthorize { uuid, token in
            receivedToken = token
            server.reject(uuid, reason: "Bad token")
        }

        let transport = MockServerTransport()
        server.handleConnection(transport)

        // Identify
        transport.simulateReceive(makeIdentifyFrame())
        flushRunLoop(ms: 150)

        // Auth
        transport.simulateReceive(makeAuthFrame(token: "invalid-token"))
        flushRunLoop(ms: 150)

        XCTAssertEqual(receivedToken, "invalid-token")

        // Should have sent AUTH_FAIL
        let frames = parseSentFrames(transport)
        let authFails = frames.filter { $0.frameType == .authFail }
        XCTAssertFalse(authFails.isEmpty, "Should send AUTH_FAIL frame")
    }

    func testAuthAccept() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        server.enableAuthorization(true, timeout: 5000)
        defer { server.close() }

        let uuid = "01234567-89ab-cdef-0123-456789abcdef"

        server.onAuthorize { clientUuid, token in
            if token == "valid-token" {
                server.authorize(clientUuid, token: token, principal: "__broadcast__")
            }
        }

        let transport = MockServerTransport()
        server.handleConnection(transport)

        transport.simulateReceive(makeIdentifyFrame(uuid: uuid))
        flushRunLoop(ms: 150)

        transport.simulateReceive(makeAuthFrame(token: "valid-token"))
        flushRunLoop(ms: 150)

        let frames = parseSentFrames(transport)
        let authOks = frames.filter { $0.frameType == .authOk }
        XCTAssertFalse(authOks.isEmpty, "Should send AUTH_OK frame")
    }
}

// MARK: - Metrics Tests

final class ServerMetricsTests: XCTestCase {

    func testMetricsSnapshot() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        let m1 = server.metrics()
        XCTAssertEqual(m1.activeSessions, 0)
        XCTAssertEqual(m1.pendingSessions, 0)

        let transport = MockServerTransport()
        server.handleConnection(transport)
        transport.simulateReceive(makeIdentifyFrame())
        flushRunLoop(ms: 150)

        let m2 = server.metrics()
        XCTAssertEqual(m2.activeSessions, 1)
        XCTAssertTrue(m2.framesIn > 0, "Should count incoming frames")
    }

    func testMaxConnections() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        server.setMaxConnections(1)
        defer { server.close() }

        // First connection
        let t1 = MockServerTransport()
        server.handleConnection(t1)
        t1.simulateReceive(makeIdentifyFrame(uuid: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
        flushRunLoop(ms: 150)

        // Second connection should be rejected
        let t2 = MockServerTransport()
        server.handleConnection(t2)
        t2.simulateReceive(makeIdentifyFrame(uuid: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
        flushRunLoop(ms: 150)

        XCTAssertFalse(t2.isOpen, "Second connection should be closed (max connections reached)")
    }
}

// MARK: - Topic Mode Tests

final class ServerTopicTests: XCTestCase {

    func testTopicSubscribeCallback() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .sessionTopic))
        defer { server.close() }

        var subscribedTopic: String?
        server.topic.onSubscribe { session, handle in
            subscribedTopic = handle.name
            handle.payload.set("greeting", "hello")
        }

        let transport = MockServerTransport()
        server.handleConnection(transport)

        // Identify
        transport.simulateReceive(makeIdentifyFrame())
        flushRunLoop(ms: 200)

        // Client subscribes to a topic by sending ClientReset, ClientKeyReg, ClientValue, ClientSync
        let clientReset = encodeFrame(Frame.signal(.clientReset))
        let clientKeyReg = encodeFrame(Frame(
            frameType: .clientKeyRegistration,
            keyId: 1,
            dataType: .string,
            payload: .string("topic.0.name")
        ))
        let clientValue = encodeFrame(Frame(
            frameType: .clientValue,
            keyId: 1,
            dataType: .string,
            payload: .string("dashboard")
        ))
        let clientSync = encodeFrame(Frame.signal(.clientSync))

        transport.simulateReceive(clientReset)
        transport.simulateReceive(clientKeyReg)
        transport.simulateReceive(clientValue)
        transport.simulateReceive(clientSync)
        flushRunLoop(ms: 300)

        XCTAssertEqual(subscribedTopic, "dashboard")
    }

    func testTopicUnsubscribeCallback() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .sessionTopic))
        defer { server.close() }

        var unsubscribedTopic: String?
        server.topic.onSubscribe { _, handle in
            handle.payload.set("data", 1)
        }
        server.topic.onUnsubscribe { _, handle in
            unsubscribedTopic = handle.name
        }

        let transport = MockServerTransport()
        server.handleConnection(transport)
        transport.simulateReceive(makeIdentifyFrame())
        flushRunLoop(ms: 200)

        // Subscribe
        transport.simulateReceive(encodeFrame(Frame.signal(.clientReset)))
        transport.simulateReceive(encodeFrame(Frame(frameType: .clientKeyRegistration, keyId: 1, dataType: .string, payload: .string("topic.0.name"))))
        transport.simulateReceive(encodeFrame(Frame(frameType: .clientValue, keyId: 1, dataType: .string, payload: .string("dashboard"))))
        transport.simulateReceive(encodeFrame(Frame.signal(.clientSync)))
        flushRunLoop(ms: 200)

        // Unsubscribe by sending empty sync
        transport.simulateReceive(encodeFrame(Frame.signal(.clientReset)))
        transport.simulateReceive(encodeFrame(Frame.signal(.clientSync)))
        flushRunLoop(ms: 200)

        XCTAssertEqual(unsubscribedTopic, "dashboard")
    }
}

// MARK: - ArraySync Tests

final class ArraySyncTests: XCTestCase {

    func testPushAndGet() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        let arr = server.array("scores", capacity: 5)
        arr.push(10)
        arr.push(20)
        arr.push(30)

        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr.get(0) as? Int, 10)
        XCTAssertEqual(arr.get(1) as? Int, 20)
        XCTAssertEqual(arr.get(2) as? Int, 30)
    }

    func testPushBeyondCapacity() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        let arr = server.array("buf", capacity: 3)
        arr.push("a")
        arr.push("b")
        arr.push("c")
        arr.push("d") // should evict "a"

        XCTAssertEqual(arr.count, 3)
        XCTAssertEqual(arr.get(0) as? String, "b")
        XCTAssertEqual(arr.get(1) as? String, "c")
        XCTAssertEqual(arr.get(2) as? String, "d")
    }

    func testToArray() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        let arr = server.array("items", capacity: 10)
        arr.push(1)
        arr.push(2)

        let result = arr.toArray()
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0] as? Int, 1)
        XCTAssertEqual(result[1] as? Int, 2)
    }

    func testClear() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        let arr = server.array("data", capacity: 5)
        arr.push(1)
        arr.push(2)
        arr.clear()

        XCTAssertEqual(arr.count, 0)
    }
}

// MARK: - Session Tests

final class ServerSessionTests: XCTestCase {

    func testSessionIdMatchesIdentify() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        let uuid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
        var sessionId: String?
        server.onConnection { session in
            sessionId = session.id
        }

        let transport = MockServerTransport()
        server.handleConnection(transport)
        transport.simulateReceive(makeIdentifyFrame(uuid: uuid))
        flushRunLoop(ms: 150)

        XCTAssertEqual(sessionId, uuid)
    }

    func testGetSession() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        let uuid = "01234567-89ab-cdef-0123-456789abcdef"
        let transport = MockServerTransport()
        server.handleConnection(transport)
        transport.simulateReceive(makeIdentifyFrame(uuid: uuid))
        flushRunLoop(ms: 150)

        let session = server.getSession(uuid)
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.id, uuid)
    }

    func testIsConnected() {
        let server = DanWebSocketServer(options: ServerOptions(port: 0, mode: .broadcast))
        defer { server.close() }

        let uuid = "01234567-89ab-cdef-0123-456789abcdef"
        XCTAssertFalse(server.isConnected(uuid))

        let transport = MockServerTransport()
        server.handleConnection(transport)
        transport.simulateReceive(makeIdentifyFrame(uuid: uuid))
        flushRunLoop(ms: 150)

        XCTAssertTrue(server.isConnected(uuid))
    }
}

// MARK: - BytesToUuid Tests

final class BytesToUuidTests: XCTestCase {

    func testBytesToUuid() {
        let bytes = Data([
            0x01, 0x23, 0x45, 0x67,
            0x89, 0xAB, 0xCD, 0xEF,
            0x01, 0x23, 0x45, 0x67,
            0x89, 0xAB, 0xCD, 0xEF
        ])
        let uuid = DanWebSocketServer.bytesToUuid(bytes)
        XCTAssertEqual(uuid, "01234567-89ab-cdef-0123-456789abcdef")
    }
}
