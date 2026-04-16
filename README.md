# DanWebSocket (Swift)

A Swift client **and server** library for the **DanProtocol v3.5** real-time state synchronization protocol. Lightweight, zero-dependency, built on Apple's `URLSessionWebSocketTask` (client) and `Network.framework` (server).

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015%20%7C%20macOS%2012-blue.svg)](https://developer.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## What is DanWebSocket?

DanWebSocket connects your iOS/macOS app to a DanProtocol server over WebSocket, or lets you **run a DanProtocol server** natively in Swift. The protocol pushes state updates in a compact binary format, and clients automatically maintain a synchronized copy of that state.

**Why use this?**

- **Real-time dashboards** -- display live sensor data, stock prices, game scores
- **Collaborative apps** -- shared state between multiple users/devices
- **IoT monitoring** -- push device telemetry to mobile apps with minimal bandwidth
- **Live feeds** -- scrolling data with efficient array shift operations
- **Embedded servers** -- run a DanProtocol server directly inside your Swift app

**Key features:**

- **Client + Server** in a single package
- Binary protocol: a boolean update is ~13 bytes (vs ~30+ for JSON)
- 4 server modes: broadcast, principal, session_topic, session_principal_topic
- Auto-reconnection with exponential backoff (client)
- Topic-based subscriptions with parameters
- Heartbeat-based connection health monitoring
- Zero external dependencies (uses Foundation + Network.framework)
- Full Swift concurrency support

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/justdancecloud/danws_swift.git", from: "1.0.0")
]
```

Or in Xcode: **File > Add Package Dependencies** and paste:
```
https://github.com/justdancecloud/danws_swift.git
```

## Quick Start -- Client

### Basic Connection

```swift
import DanWebSocket

let client = DanWebSocketClient(url: "ws://localhost:8080/ws")

client.onReady {
    print("Connected! Initial state loaded.")
    print("Temperature: \(client.get("sensor.temperature") ?? "N/A")")
}

client.onReceive { key, value in
    print("\(key) updated to \(value ?? "nil")")
}

client.onError { error in
    print("Error: \(error.message)")
}

client.connect()
```

### With Authentication

```swift
let client = DanWebSocketClient(url: "ws://example.com/ws")

client.onConnect {
    client.authorize("your-auth-token")
}

client.onReady {
    print("Authenticated and ready!")
}

client.connect()
```

### Topic Subscriptions

```swift
let client = DanWebSocketClient(url: "ws://example.com/ws")

client.onReady {
    client.subscribe("dashboard", params: ["roomId": "abc123"])
}

let handle = client.topic("dashboard")
handle.onReceive { key, value in
    print("Dashboard.\(key) = \(value ?? "nil")")
}
handle.onUpdate { topic in
    print("Dashboard updated, keys: \(topic.keys)")
}

client.connect()
```

## Quick Start -- Server

### Broadcast Mode

All connected clients see the same shared state.

```swift
import DanWebSocket

let server = DanWebSocketServer(options: ServerOptions(
    port: 8080,
    mode: .broadcast
))

server.set("score", 0)
server.set("status", "waiting")

server.onConnection { session in
    print("Client connected: \(session.id)")
}

// Update state -- all clients receive the change automatically
Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
    let current = (server.get("score") as? Int) ?? 0
    server.set("score", current + 1)
}
```

### Principal Mode

Each user (principal) has isolated state. Multiple sessions from the same principal share their state.

```swift
let server = DanWebSocketServer(options: ServerOptions(
    port: 8080,
    mode: .principal
))

server.enableAuthorization(true, timeout: 5000)

server.onAuthorize { clientUuid, token in
    // Validate the token and assign a principal
    if token == "alice-token" {
        server.authorize(clientUuid, token: token, principal: "alice")
    } else {
        server.reject(clientUuid, reason: "Invalid token")
    }
}

server.onConnection { session in
    let ptx = server.principal(session.principal ?? "default")
    ptx.set("welcome", "Hello, \(session.principal ?? "user")!")
    ptx.set("loginTime", Date().timeIntervalSince1970)
}
```

### Topic Mode

Clients subscribe to named topics with parameters. The server responds with per-topic data.

```swift
let server = DanWebSocketServer(options: ServerOptions(
    port: 8080,
    mode: .sessionTopic
))

server.topic.onSubscribe { session, handle in
    print("Client \(session.id) subscribed to \(handle.name) with params: \(handle.params)")

    // Set topic-scoped data
    handle.payload.set("title", "Live Dashboard")
    handle.payload.set("refreshRate", 1000)

    // Start a repeating task
    handle.setDelayedTask(ms: 1000)
    handle.setCallback { event, topic, session in
        if event == .delayedTask {
            topic.payload.set("timestamp", Date().timeIntervalSince1970)
        }
    }
}

server.topic.onUnsubscribe { session, handle in
    print("Client \(session.id) unsubscribed from \(handle.name)")
}
```

### ArraySync (Ring Buffer)

Efficient server-side array with fixed capacity. Oldest items are evicted when full.

```swift
let server = DanWebSocketServer(options: ServerOptions(
    port: 8080,
    mode: .broadcast
))

let logs = server.array("logs", capacity: 100)

// Push items -- when capacity is reached, oldest items are removed
logs.push("Server started")
logs.push("Client connected")
logs.push("Processing request...")

// Access items
print("Total: \(logs.count)")
print("Latest: \(logs.get(logs.count - 1) ?? "nil")")

// Convert to array
let allLogs = logs.toArray()
```

### Authorization

```swift
let server = DanWebSocketServer(options: ServerOptions(
    port: 8080,
    mode: .principal
))

server.enableAuthorization(true, timeout: 5000)

server.onAuthorize { clientUuid, token in
    // Your auth logic here
    validateToken(token) { isValid, username in
        if isValid {
            server.authorize(clientUuid, token: token, principal: username)
        } else {
            server.reject(clientUuid, reason: "Invalid credentials")
        }
    }
}
```

### Metrics

```swift
let m = server.metrics()
print("Active sessions: \(m.activeSessions)")
print("Pending auth: \(m.pendingSessions)")
print("Principals: \(m.principalCount)")
print("Frames in: \(m.framesIn)")
print("Frames out: \(m.framesOut)")
```

### Connection Limits

```swift
server.setMaxConnections(100)    // 0 = unlimited
server.setMaxFramesPerSec(60)    // 0 = unlimited
```

## SwiftUI Integration

```swift
import SwiftUI
import DanWebSocket

class DashboardViewModel: ObservableObject {
    @Published var temperature: Double = 0
    @Published var humidity: Double = 0
    @Published var isConnected = false

    private let client: DanWebSocketClient

    init() {
        client = DanWebSocketClient(url: "ws://localhost:8080/ws")

        client.onReady { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = true
            }
        }

        client.onReceive { [weak self] key, value in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch key {
                case "sensor.temperature":
                    self.temperature = (value as? Double) ?? 0
                case "sensor.humidity":
                    self.humidity = (value as? Double) ?? 0
                default:
                    break
                }
            }
        }

        client.onDisconnect { [weak self] in
            DispatchQueue.main.async {
                self?.isConnected = false
            }
        }

        client.connect()
    }

    deinit {
        client.disconnect()
    }
}

struct DashboardView: View {
    @StateObject private var viewModel = DashboardViewModel()

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Circle()
                    .fill(viewModel.isConnected ? Color.green : Color.red)
                    .frame(width: 10, height: 10)
                Text(viewModel.isConnected ? "Connected" : "Disconnected")
            }

            VStack {
                Text("Temperature")
                    .font(.headline)
                Text(String(format: "%.1f C", viewModel.temperature))
                    .font(.largeTitle)
            }

            VStack {
                Text("Humidity")
                    .font(.headline)
                Text(String(format: "%.1f%%", viewModel.humidity))
                    .font(.largeTitle)
            }
        }
        .padding()
    }
}
```

## Configuration

### Reconnection Options (Client)

```swift
let options = ClientOptions(
    reconnect: ReconnectOptions(
        enabled: true,
        maxRetries: 10,
        baseDelay: 1.0,
        maxDelay: 30.0,
        backoffMultiplier: 2.0,
        jitter: true
    ),
    debug: true
)

let client = DanWebSocketClient(url: "ws://localhost:8080/ws", options: options)
```

### Server Options

```swift
let server = DanWebSocketServer(options: ServerOptions(
    port: 8080,
    path: "/ws",
    mode: .broadcast,
    sessionTtl: 600_000,          // 10 min session TTL
    principalEvictionTtl: 300_000, // 5 min before evicting idle principal data
    debug: true,
    flushIntervalMs: 100,
    maxMessageSize: 1_048_576,    // 1 MB
    maxValueSize: 65_536,         // 64 KB
    maxConnections: 0,            // unlimited
    maxFramesPerSec: 0            // unlimited
))
```

## API Reference

### DanWebSocketClient

| Property/Method | Description |
|---|---|
| `id: String` | Unique client identifier (UUIDv7) |
| `state: ClientState` | Current connection state |
| `connect()` | Connect to the server |
| `disconnect()` | Disconnect from the server |
| `authorize(_ token:)` | Send authentication token |
| `get(_ key:) -> Any?` | Get current value for a key |
| `getValue(_ key:) -> DanValue` | Get typed value for a key |
| `keys: [String]` | All registered key paths |
| `subscribe(_ topic:, params:)` | Subscribe to a topic |
| `unsubscribe(_ topic:)` | Unsubscribe from a topic |
| `topic(_ name:) -> TopicClientHandle` | Get scoped topic handle |

### DanWebSocketServer

| Property/Method | Description |
|---|---|
| `mode: ServerMode` | Server operating mode |
| `set(_ key:, _ value:)` | Set value (broadcast mode) |
| `get(_ key:) -> Any?` | Get value (broadcast mode) |
| `keys: [String]` | All keys (broadcast mode) |
| `clear(_ key:)` | Clear key or all (broadcast mode) |
| `array(_ key:, capacity:)` | Create ArraySync ring buffer |
| `principal(_ name:) -> PrincipalTX` | Access principal state |
| `enableAuthorization(_ enabled:, timeout:)` | Enable/disable auth |
| `authorize(_ clientUuid:, token:, principal:)` | Accept auth request |
| `reject(_ clientUuid:, reason:)` | Reject auth request |
| `setMaxConnections(_ max:)` | Set connection limit |
| `setMaxFramesPerSec(_ max:)` | Set frame rate limit |
| `metrics() -> ServerMetrics` | Get server metrics |
| `topic: TopicNamespace` | Topic event namespace |
| `onConnection(_ cb:)` | New connection callback |
| `onAuthorize(_ cb:)` | Auth request callback |
| `close()` | Shut down server |

### Server Modes

| Mode | Description |
|---|---|
| `.broadcast` | All clients share one global state |
| `.principal` | Per-user isolated state via principals |
| `.sessionTopic` | Clients subscribe to topics with parameters |
| `.sessionPrincipalTopic` | Topics + per-user principal state |

### Events (Client)

| Event | Callback | Description |
|---|---|---|
| `onConnect` | `() -> Void` | WebSocket connection opened |
| `onDisconnect` | `() -> Void` | WebSocket connection closed |
| `onReady` | `() -> Void` | Initial state fully loaded |
| `onReceive` | `(String, Any?) -> Void` | Individual key update |
| `onUpdate` | `([String: Any?]) -> Void` | Batch update (once per flush) |
| `onError` | `(DanWSError) -> Void` | Error occurred |
| `onReconnecting` | `(Int, TimeInterval) -> Void` | Reconnection attempt starting |
| `onReconnect` | `() -> Void` | Successfully reconnected |
| `onReconnectFailed` | `() -> Void` | All retries exhausted |

## Requirements

- Swift 5.9+
- iOS 15+ / macOS 12+ / tvOS 15+ / watchOS 8+
- No external dependencies

## Protocol Compatibility

This library implements DanProtocol v3.5 and is wire-compatible with:
- [dan-websocket (TypeScript)](https://www.npmjs.com/package/dan-websocket) - npm
- [dan-websocket (Java)](https://central.sonatype.com/artifact/io.github.justdancecloud/dan-websocket) - Maven Central

## License

MIT
