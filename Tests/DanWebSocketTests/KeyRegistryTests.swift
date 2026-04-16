import XCTest
@testable import DanWebSocket

final class KeyRegistryTests: XCTestCase {

    func testRegisterAndLookup() {
        let registry = KeyRegistry()
        registry.registerOne(keyId: 1, path: "sensor.temperature", type: .varDouble)

        XCTAssertNotNil(registry.getByKeyId(1))
        XCTAssertNotNil(registry.getByPath("sensor.temperature"))
        XCTAssertEqual(registry.getByKeyId(1)?.path, "sensor.temperature")
        XCTAssertEqual(registry.getByPath("sensor.temperature")?.keyId, 1)
    }

    func testRegisterMultiple() {
        let registry = KeyRegistry()
        registry.registerOne(keyId: 1, path: "key1", type: .varInteger)
        registry.registerOne(keyId: 2, path: "key2", type: .string)
        registry.registerOne(keyId: 3, path: "key3", type: .bool)

        XCTAssertEqual(registry.size, 3)
        XCTAssertTrue(registry.hasKeyId(1))
        XCTAssertTrue(registry.hasKeyId(2))
        XCTAssertTrue(registry.hasKeyId(3))
        XCTAssertFalse(registry.hasKeyId(4))
    }

    func testRemoveByKeyId() {
        let registry = KeyRegistry()
        registry.registerOne(keyId: 1, path: "key1", type: .string)
        registry.registerOne(keyId: 2, path: "key2", type: .string)

        XCTAssertTrue(registry.removeByKeyId(1))
        XCTAssertFalse(registry.hasKeyId(1))
        XCTAssertFalse(registry.hasPath("key1"))
        XCTAssertEqual(registry.size, 1)
    }

    func testRemoveNonExistent() {
        let registry = KeyRegistry()
        XCTAssertFalse(registry.removeByKeyId(999))
    }

    func testClear() {
        let registry = KeyRegistry()
        registry.registerOne(keyId: 1, path: "key1", type: .string)
        registry.registerOne(keyId: 2, path: "key2", type: .string)

        registry.clear()
        XCTAssertEqual(registry.size, 0)
        XCTAssertFalse(registry.hasKeyId(1))
        XCTAssertFalse(registry.hasKeyId(2))
    }

    func testPaths() {
        let registry = KeyRegistry()
        registry.registerOne(keyId: 1, path: "alpha", type: .string)
        registry.registerOne(keyId: 2, path: "beta", type: .string)

        let paths = registry.paths
        XCTAssertEqual(paths.count, 2)
        XCTAssertTrue(paths.contains("alpha"))
        XCTAssertTrue(paths.contains("beta"))
    }

    func testOverwriteSameKeyId() {
        let registry = KeyRegistry()
        registry.registerOne(keyId: 1, path: "old_path", type: .string)
        registry.registerOne(keyId: 1, path: "new_path", type: .varInteger)

        XCTAssertEqual(registry.getByKeyId(1)?.path, "new_path")
        XCTAssertEqual(registry.getByKeyId(1)?.type, .varInteger)
    }

    func testValidateKeyPath() {
        XCTAssertNoThrow(try KeyRegistry.validateKeyPath("sensor.temperature"))
        XCTAssertNoThrow(try KeyRegistry.validateKeyPath("root.users.0.name"))
        XCTAssertNoThrow(try KeyRegistry.validateKeyPath("simple"))

        XCTAssertThrowsError(try KeyRegistry.validateKeyPath(""))
        XCTAssertThrowsError(try KeyRegistry.validateKeyPath(".leading"))
        XCTAssertThrowsError(try KeyRegistry.validateKeyPath("trailing."))
        XCTAssertThrowsError(try KeyRegistry.validateKeyPath("double..dot"))
        XCTAssertThrowsError(try KeyRegistry.validateKeyPath("invalid chars!"))
    }

    func testTopicPrefixPaths() {
        let registry = KeyRegistry()
        registry.registerOne(keyId: 1, path: "t.0.items.length", type: .varInteger)
        registry.registerOne(keyId: 2, path: "t.0.items.0.title", type: .string)
        registry.registerOne(keyId: 3, path: "t.1.value", type: .varDouble)

        XCTAssertEqual(registry.size, 3)
        XCTAssertTrue(registry.hasPath("t.0.items.length"))
        XCTAssertTrue(registry.hasPath("t.1.value"))
    }
}
