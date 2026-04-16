import Foundation

/// Callbacks for FlatStateManager to communicate with its owner.
struct FlatStateCallbacks {
    var allocateKeyId: () -> UInt32
    var enqueue: (Frame) -> Void
    var onResync: () -> Void
    var wirePrefix: String
    var onIncrementalKey: ((Frame, Frame, Frame) -> Void)?
    var onKeyStructureChange: (() -> Void)?
    var maxValueSize: Int?
}

/// Internal entry in the flat state store.
private struct FlatEntry {
    let keyId: UInt32
    var type: DataType
    var value: Any?
}

/// Shared flatten + diff + setLeaf logic.
/// Used by PrincipalTX, DanWebSocketSession, and TopicPayload via composition.
final class FlatStateManager {
    private var entries = [String: FlatEntry]()
    private var byKeyId = [UInt32: (key: String, entry: FlatEntry)]()
    private var flattenedKeys = [String: Set<String>]()
    private var previousArrays = [String: [Any]]()
    private var cb: FlatStateCallbacks
    private var freedKeyIds = [UInt32]()

    init(cb: FlatStateCallbacks) {
        self.cb = cb
    }

    private func allocateKeyId() -> UInt32 {
        if !freedKeyIds.isEmpty {
            return freedKeyIds.removeLast()
        }
        return cb.allocateKeyId()
    }

    private func freeKeyId(_ keyId: UInt32) {
        if freedKeyIds.count < 10_000 {
            freedKeyIds.append(keyId)
        }
    }

    // MARK: - Public API

    func set(_ key: String, _ value: Any?) {
        if shouldFlatten(value) {
            if let arr = value as? [Any] {
                previousArrays[key] = arr
            }

            let flattened = flattenValue(key, value!)
            let newKeys = Set(flattened.keys)
            let oldKeys = flattenedKeys[key]

            var structureChanged = false
            if let oldKeys = oldKeys {
                for oldPath in oldKeys {
                    if !newKeys.contains(oldPath) {
                        if let entry = entries[oldPath] {
                            cb.enqueue(Frame(
                                frameType: .serverKeyDelete,
                                keyId: entry.keyId,
                                dataType: .null,
                                payload: .null
                            ))
                            freeKeyId(entry.keyId)
                            byKeyId.removeValue(forKey: entry.keyId)
                            entries.removeValue(forKey: oldPath)
                            structureChanged = true
                        }
                    }
                }
            }
            flattenedKeys[key] = newKeys
            for (path, leaf) in flattened {
                _ = setLeaf(path, leaf)
            }
            if structureChanged { cb.onKeyStructureChange?() }
            return
        }
        if setLeaf(key, value) {
            cb.onResync()
        }
    }

    func get(_ key: String) -> Any? {
        entries[key]?.value
    }

    var keys: [String] {
        Array(entries.keys)
    }

    var size: Int {
        entries.count
    }

    func clear(_ key: String? = nil) {
        if let key = key {
            if let flatKeys = flattenedKeys[key] {
                for path in flatKeys {
                    if let entry = entries[path] {
                        cb.enqueue(Frame(
                            frameType: .serverKeyDelete,
                            keyId: entry.keyId,
                            dataType: .null,
                            payload: .null
                        ))
                        freeKeyId(entry.keyId)
                        byKeyId.removeValue(forKey: entry.keyId)
                        entries.removeValue(forKey: path)
                    }
                }
                flattenedKeys.removeValue(forKey: key)
                previousArrays.removeValue(forKey: key)
                cb.onKeyStructureChange?()
            } else if let entry = entries[key] {
                cb.enqueue(Frame(
                    frameType: .serverKeyDelete,
                    keyId: entry.keyId,
                    dataType: .null,
                    payload: .null
                ))
                freeKeyId(entry.keyId)
                byKeyId.removeValue(forKey: entry.keyId)
                entries.removeValue(forKey: key)
                previousArrays.removeValue(forKey: key)
                cb.onKeyStructureChange?()
            }
        } else {
            if !entries.isEmpty {
                for entry in entries.values {
                    freedKeyIds.append(entry.keyId)
                }
                entries.removeAll()
                byKeyId.removeAll()
                flattenedKeys.removeAll()
                previousArrays.removeAll()
                cb.onKeyStructureChange?()
                cb.onResync()
            }
        }
    }

    // MARK: - Frame Building

    func buildKeyFrames() -> [Frame] {
        var frames = [Frame]()
        for (key, entry) in entries {
            let wirePath = cb.wirePrefix.isEmpty ? key : "\(cb.wirePrefix)\(key)"
            frames.append(Frame(
                frameType: .serverKeyRegistration,
                keyId: entry.keyId,
                dataType: entry.type,
                payload: .string(wirePath)
            ))
        }
        return frames
    }

    func buildValueFrames() -> [Frame] {
        var frames = [Frame]()
        for entry in entries.values {
            if entry.value != nil {
                let (dt, dv) = Serializer.toDanValue(entry.value)
                frames.append(Frame(
                    frameType: .serverValue,
                    keyId: entry.keyId,
                    dataType: dt,
                    payload: dv
                ))
            }
        }
        return frames
    }

    func buildAllFrames() -> (keyFrames: [Frame], valueFrames: [Frame]) {
        var keyFrames = [Frame]()
        var valueFrames = [Frame]()
        for (key, entry) in entries {
            let wirePath = cb.wirePrefix.isEmpty ? key : "\(cb.wirePrefix)\(key)"
            keyFrames.append(Frame(
                frameType: .serverKeyRegistration,
                keyId: entry.keyId,
                dataType: entry.type,
                payload: .string(wirePath)
            ))
            if entry.value != nil {
                let (dt, dv) = Serializer.toDanValue(entry.value)
                valueFrames.append(Frame(
                    frameType: .serverValue,
                    keyId: entry.keyId,
                    dataType: dt,
                    payload: dv
                ))
            }
        }
        return (keyFrames, valueFrames)
    }

    func getByKeyId(_ keyId: UInt32) -> (key: String, entry: (keyId: UInt32, type: DataType, value: Any?))? {
        guard let result = byKeyId[keyId] else { return nil }
        return (key: result.key, entry: (keyId: result.entry.keyId, type: result.entry.type, value: result.entry.value))
    }

    // MARK: - Private

    /// Returns true if resync is needed (currently always false since type change is handled incrementally).
    @discardableResult
    private func setLeaf(_ key: String, _ value: Any?) -> Bool {
        let (newType, newDanValue) = Serializer.toDanValue(value)

        if var existing = entries[key] {
            if existing.type != newType {
                // Type changed -- delete old key, register new
                cb.enqueue(Frame(frameType: .serverKeyDelete, keyId: existing.keyId, dataType: .null, payload: .null))
                freeKeyId(existing.keyId)
                byKeyId.removeValue(forKey: existing.keyId)
                entries.removeValue(forKey: key)
                cb.onKeyStructureChange?()

                let newKeyId = allocateKeyId()
                let newEntry = FlatEntry(keyId: newKeyId, type: newType, value: value)
                entries[key] = newEntry
                byKeyId[newKeyId] = (key: key, entry: newEntry)

                let wirePath = cb.wirePrefix.isEmpty ? key : "\(cb.wirePrefix)\(key)"
                cb.enqueue(Frame(frameType: .serverKeyRegistration, keyId: newKeyId, dataType: newType, payload: .string(wirePath)))
                cb.enqueue(Frame.signal(.serverSync))
                cb.enqueue(Frame(frameType: .serverValue, keyId: newKeyId, dataType: newType, payload: newDanValue))
                return false
            }

            existing.value = value
            entries[key] = existing
            byKeyId[existing.keyId] = (key: key, entry: existing)
            cb.enqueue(Frame(
                frameType: .serverValue,
                keyId: existing.keyId,
                dataType: existing.type,
                payload: newDanValue
            ))
            return false
        }

        // New key
        let keyId = allocateKeyId()
        let newEntry = FlatEntry(keyId: keyId, type: newType, value: value)
        entries[key] = newEntry
        byKeyId[keyId] = (key: key, entry: newEntry)
        cb.onKeyStructureChange?()

        let wirePath = cb.wirePrefix.isEmpty ? key : "\(cb.wirePrefix)\(key)"
        let keyFrame = Frame(frameType: .serverKeyRegistration, keyId: keyId, dataType: newType, payload: .string(wirePath))
        let syncFrame = Frame.signal(.serverSync)
        let valueFrame = Frame(frameType: .serverValue, keyId: keyId, dataType: newType, payload: newDanValue)

        if let onInc = cb.onIncrementalKey {
            onInc(keyFrame, syncFrame, valueFrame)
        } else {
            cb.enqueue(keyFrame)
            cb.enqueue(syncFrame)
            cb.enqueue(valueFrame)
        }
        return false
    }

    // MARK: - Flatten Helpers

    private func shouldFlatten(_ value: Any?) -> Bool {
        guard let value = value else { return false }
        return value is [Any] || value is [String: Any]
    }

    private func flattenValue(_ prefix: String, _ value: Any) -> [(String, Any)] {
        var result = [(String, Any)]()

        if let arr = value as? [Any] {
            result.append(("\(prefix).length", arr.count))
            for (i, item) in arr.enumerated() {
                if shouldFlatten(item) {
                    result.append(contentsOf: flattenValue("\(prefix).\(i)", item))
                } else {
                    result.append(("\(prefix).\(i)", item))
                }
            }
        } else if let dict = value as? [String: Any] {
            for (key, val) in dict {
                if shouldFlatten(val) {
                    result.append(contentsOf: flattenValue("\(prefix).\(key)", val))
                } else {
                    result.append(("\(prefix).\(key)", val))
                }
            }
        }

        return result
    }
}
