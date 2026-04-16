import Foundation

/// Provides array-like access over flattened dot-path keys.
///
/// When the server sends auto-flattened array data (e.g., `scores.0`, `scores.1`,
/// `scores.length`), this view reconstructs the array for convenient access.
///
/// ```swift
/// let scores = ArrayView(prefix: "scores", client: client)
/// print("Length: \(scores.count)")
/// print("First: \(scores[0] ?? "nil")")
/// for value in scores {
///     print(value ?? "nil")
/// }
/// ```
public struct ArrayView: Sequence {
    private let prefix: String
    private let getter: (String) -> Any?

    /// Create an ArrayView from a DanWebSocketClient.
    public init(prefix: String, client: DanWebSocketClient) {
        self.prefix = prefix
        self.getter = { key in client.get(key) }
    }

    /// Create an ArrayView from a TopicClientHandle.
    public init(prefix: String, topic: TopicClientHandle) {
        self.prefix = prefix
        self.getter = { key in topic.get(key) }
    }

    /// Create an ArrayView with a custom getter.
    public init(prefix: String, getter: @escaping (String) -> Any?) {
        self.prefix = prefix
        self.getter = getter
    }

    /// The number of elements in the array.
    public var count: Int {
        (getter("\(prefix).length") as? Int) ?? 0
    }

    /// Whether the array is empty.
    public var isEmpty: Bool {
        count == 0
    }

    /// Access an element by index.
    public subscript(index: Int) -> Any? {
        guard index >= 0 && index < count else { return nil }
        return getter("\(prefix).\(index)")
    }

    /// Convert to a Swift array.
    public func toArray() -> [Any?] {
        let len = count
        var result = [Any?]()
        result.reserveCapacity(len)
        for i in 0..<len {
            result.append(getter("\(prefix).\(i)"))
        }
        return result
    }

    // MARK: - Sequence conformance

    public struct Iterator: IteratorProtocol {
        private let view: ArrayView
        private var index = 0
        private let length: Int

        init(_ view: ArrayView) {
            self.view = view
            self.length = view.count
        }

        public mutating func next() -> Any?? {
            guard index < length else { return nil }
            let value = view[index]
            index += 1
            return value
        }
    }

    public func makeIterator() -> Iterator {
        Iterator(self)
    }
}
