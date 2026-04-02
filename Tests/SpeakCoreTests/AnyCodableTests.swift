import XCTest
@testable import SpeakCore

final class AnyCodableTests: XCTestCase {

    // MARK: - Null round-trip

    func testNull_roundTrip() throws {
        let json = "null"
        let decoded = try decode(AnyCodable.self, from: json)
        XCTAssertTrue(decoded.value is NSNull)
        let reencoded = try encode(decoded)
        XCTAssertEqual(reencoded, json)
    }

    // MARK: - Bool round-trips

    func testBool_true_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "true")
        let value = try XCTUnwrap(decoded.value as? Bool)
        XCTAssertTrue(value)
        XCTAssertEqual(try encode(decoded), "true")
    }

    func testBool_false_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "false")
        let value = try XCTUnwrap(decoded.value as? Bool)
        XCTAssertFalse(value)
        XCTAssertEqual(try encode(decoded), "false")
    }

    // MARK: - Int round-trips

    func testInt_positive_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "42")
        let value = try XCTUnwrap(decoded.value as? Int)
        XCTAssertEqual(value, 42)
        XCTAssertEqual(try encode(decoded), "42")
    }

    func testInt_negative_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "-7")
        let value = try XCTUnwrap(decoded.value as? Int)
        XCTAssertEqual(value, -7)
    }

    func testInt_zero_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "0")
        XCTAssertNotNil(decoded.value as? Int, "0 should decode as Int (before Double)")
    }

    // MARK: - Double round-trips

    func testDouble_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "3.14")
        let value = try XCTUnwrap(decoded.value as? Double)
        XCTAssertEqual(value, 3.14, accuracy: 0.0001)
    }

    func testDouble_negative_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "-2.718")
        XCTAssertNotNil(decoded.value as? Double)
    }

    // MARK: - String round-trips

    func testString_simple_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "\"hello\"")
        let value = try XCTUnwrap(decoded.value as? String)
        XCTAssertEqual(value, "hello")
        XCTAssertEqual(try encode(decoded), "\"hello\"")
    }

    func testString_empty_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "\"\"")
        let value = try XCTUnwrap(decoded.value as? String)
        XCTAssertEqual(value, "")
    }

    func testString_withEscapes_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "\"hello\\nworld\"")
        let value = try XCTUnwrap(decoded.value as? String)
        XCTAssertEqual(value, "hello\nworld")
    }

    // MARK: - Array round-trips

    func testArray_homogeneous_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "[1,2,3]")
        let array = try XCTUnwrap(decoded.value as? [Any])
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array[0] as? Int, 1)
        XCTAssertEqual(array[1] as? Int, 2)
        XCTAssertEqual(array[2] as? Int, 3)
    }

    func testArray_mixed_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "[1,\"two\",true,null]")
        let array = try XCTUnwrap(decoded.value as? [Any])
        XCTAssertEqual(array.count, 4)
        XCTAssertEqual(array[0] as? Int, 1)
        XCTAssertEqual(array[1] as? String, "two")
        XCTAssertEqual(array[2] as? Bool, true)
        XCTAssertTrue(array[3] is NSNull)
    }

    func testArray_empty_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "[]")
        let array = try XCTUnwrap(decoded.value as? [Any])
        XCTAssertTrue(array.isEmpty)
        XCTAssertEqual(try encode(decoded), "[]")
    }

    func testArray_nested_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "[[1,2],[3,4]]")
        let outer = try XCTUnwrap(decoded.value as? [Any])
        XCTAssertEqual(outer.count, 2)
        let inner = try XCTUnwrap(outer[0] as? [Any])
        XCTAssertEqual(inner[0] as? Int, 1)
    }

    // MARK: - Dictionary round-trips

    func testDictionary_simple_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "{\"key\":\"value\"}")
        let dict = try XCTUnwrap(decoded.value as? [String: Any])
        XCTAssertEqual(dict["key"] as? String, "value")
    }

    func testDictionary_mixed_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "{\"n\":1,\"s\":\"hello\",\"b\":true}")
        let dict = try XCTUnwrap(decoded.value as? [String: Any])
        XCTAssertEqual(dict["n"] as? Int, 1)
        XCTAssertEqual(dict["s"] as? String, "hello")
        XCTAssertEqual(dict["b"] as? Bool, true)
    }

    func testDictionary_empty_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "{}")
        let dict = try XCTUnwrap(decoded.value as? [String: Any])
        XCTAssertTrue(dict.isEmpty)
    }

    func testDictionary_nested_roundTrip() throws {
        let decoded = try decode(AnyCodable.self, from: "{\"outer\":{\"inner\":42}}")
        let outer = try XCTUnwrap(decoded.value as? [String: Any])
        let inner = try XCTUnwrap(outer["outer"] as? [String: Any])
        XCTAssertEqual(inner["inner"] as? Int, 42)
    }

    // MARK: - Decode-priority ordering

    func testDecodePriority_boolBeforeInt() throws {
        // JSON `true`/`false` must decode as Bool, not Int
        let t = try decode(AnyCodable.self, from: "true")
        let f = try decode(AnyCodable.self, from: "false")
        XCTAssertTrue(t.value is Bool, "true must decode as Bool, not Int")
        XCTAssertTrue(f.value is Bool, "false must decode as Bool, not Int")
        XCTAssertFalse(t.value is Int)
        XCTAssertFalse(f.value is Int)
    }

    func testDecodePriority_intBeforeDouble() throws {
        // Whole-number JSON values should prefer Int over Double
        let decoded = try decode(AnyCodable.self, from: "5")
        XCTAssertTrue(decoded.value is Int, "Whole number should decode as Int before Double")
        XCTAssertFalse(decoded.value is Double)
    }

    // MARK: - Encode errors

    func testEncode_unsupportedType_throwsError() {
        struct Unsupported {}
        let subject = AnyCodable(Unsupported())
        XCTAssertThrowsError(try encode(subject), "Encoding unsupported type should throw")
    }

    // MARK: - AnyCodable initialiser wrapping

    func testInit_wrapsValue() {
        let value = "test"
        let wrapped = AnyCodable(value)
        XCTAssertEqual(wrapped.value as? String, value)
    }

    // MARK: - Encode from Swift value

    func testEncodeFromValue_string() throws {
        let subject = AnyCodable("hello")
        XCTAssertEqual(try encode(subject), "\"hello\"")
    }

    func testEncodeFromValue_int() throws {
        let subject = AnyCodable(99)
        XCTAssertEqual(try encode(subject), "99")
    }

    func testEncodeFromValue_bool() throws {
        let subject = AnyCodable(true)
        XCTAssertEqual(try encode(subject), "true")
    }

    func testEncodeFromValue_array() throws {
        let subject = AnyCodable([1, 2, 3])
        let json = try encode(subject)
        XCTAssertTrue(json.contains("1"))
        XCTAssertTrue(json.contains("2"))
        XCTAssertTrue(json.contains("3"))
    }

    func testEncodeFromValue_dict() throws {
        let subject = AnyCodable(["key": "val"])
        let json = try encode(subject)
        XCTAssertTrue(json.contains("key"))
        XCTAssertTrue(json.contains("val"))
    }
}

// MARK: - Helpers

private extension AnyCodableTests {
    func decode<T: Decodable>(_ type: T.Type, from jsonString: String) throws -> T {
        let data = Data(jsonString.utf8)
        return try JSONDecoder().decode(type, from: data)
    }

    func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8)!
    }
}
