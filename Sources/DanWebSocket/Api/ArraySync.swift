import Foundation

/// Server-side ring buffer for array synchronization.
/// Wraps a PrincipalTX to manage a fixed-capacity array with shift operations.
public final class ArraySync: @unchecked Sendable {
    private let key: String
    private let capacity: Int
    private let ptx: PrincipalTX

    init(key: String, capacity: Int, ptx: PrincipalTX) {
        self.key = key
        self.capacity = capacity
        self.ptx = ptx

        // Initialize length if not already set
        if ptx.get("\(key).length") == nil {
            ptx.set("\(key).length", 0)
        }
    }

    /// Current number of elements in the array.
    public var count: Int {
        (ptx.get("\(key).length") as? Int) ?? 0
    }

    /// Push a value to the end of the array. If at capacity, the oldest element is removed.
    public func push(_ value: Any?) {
        var currentLength = count
        if currentLength >= capacity {
            // Shift left to make room
            for i in 0..<(currentLength - 1) {
                let srcVal = ptx.get("\(key).\(i + 1)")
                ptx.set("\(key).\(i)", srcVal)
            }
            currentLength = capacity - 1
        }
        ptx.set("\(key).\(currentLength)", value)
        ptx.set("\(key).length", currentLength + 1)
    }

    /// Get the value at a specific index.
    public func get(_ index: Int) -> Any? {
        guard index >= 0 && index < count else { return nil }
        return ptx.get("\(key).\(index)")
    }

    /// Convert to a Swift array.
    public func toArray() -> [Any?] {
        let len = count
        var result = [Any?]()
        result.reserveCapacity(len)
        for i in 0..<len {
            result.append(ptx.get("\(key).\(i)"))
        }
        return result
    }

    /// Clear all elements.
    public func clear() {
        let len = count
        for i in 0..<len {
            ptx.clear("\(key).\(i)")
        }
        ptx.set("\(key).length", 0)
    }
}
