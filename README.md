# DanWebSocket (Swift)

A Swift client library for the **DanProtocol v3.5** real-time state synchronization protocol. Lightweight, zero-dependency, built on Apple's `URLSessionWebSocketTask`.

[![Swift 5.9+](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2015%20%7C%20macOS%2012-blue.svg)](https://developer.apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

## What is DanWebSocket?

DanWebSocket connects your iOS/macOS app to a DanProtocol server over WebSocket. The server pushes state updates in a compact binary format, and the client automatically maintains a synchronized copy of that state. Think of it as a real-time key-value store that syncs across devices.

**Why use this?**

- **Real-time dashboards** — display live sensor data, stock prices, game scores
- **Collaborative apps** — shared state between multiple users/devices
- **IoT monitoring** — push device telemetry to mobile apps with minimal bandwidth
- **Live feeds** — scrolling data with efficient array shift operations

**Key features:**

- Binary protocol: a boolean update is ~13 bytes (vs ~30+ for JSON)
- Auto-reconnection with exponential backoff
- Topic-based subscriptions with parameters
- Heartbeat-based connection health monitoring
- Zero external dependencies (uses Foundation's URLSessionWebSocketTask)
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

## Quick Start

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
    // Subscribe to a topic with parameters
    client.subscribe("dashboard", params: ["roomId": "abc123"])
}

// Access topic-scoped data
let handle = client.topic("dashboard")
handle.onReceive { key, value in
    print("Dashboard.\(key) = \(value ?? "nil")")
}
handle.onUpdate { topic in
    // Fires once per batch (efficient for UI updates)
    print("Dashboard updated, keys: \(topic.keys)")
}

client.connect()
```

### SwiftUI Integration

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

### Batch Updates (Efficient Rendering)

```swift
// onReceive fires per-key (N times per batch)
client.onReceive { key, value in
    // Fine-grained: per-key update
}

// onUpdate fires once per server flush (1 time per batch)
client.onUpdate { state in
    // Batch-level: update UI once with all current values
    let temp = state["sensor.temperature"]
    let humid = state["sensor.humidity"]
    updateUI(temp: temp, humid: humid)
}
```

## Configuration

### Reconnection Options

```swift
let options = ClientOptions(
    reconnect: ReconnectOptions(
        enabled: true,       // Auto-reconnect on disconnect
        maxRetries: 10,      // 0 = unlimited
        baseDelay: 1.0,      // Initial delay (seconds)
        maxDelay: 30.0,      // Maximum delay (seconds)
        backoffMultiplier: 2.0,
        jitter: true         // Randomize delay to prevent thundering herd
    ),
    debug: true  // Enable debug logging
)

let client = DanWebSocketClient(url: "ws://localhost:8080/ws", options: options)
```

### Reconnection Events

```swift
client.onReconnecting { attempt, delay in
    print("Reconnecting... attempt \(attempt), waiting \(delay)s")
}

client.onReconnect {
    print("Reconnected successfully!")
}

client.onReconnectFailed {
    print("All reconnection attempts exhausted")
}
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

### Events

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
