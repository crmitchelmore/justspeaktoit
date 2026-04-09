import XCTest

@testable import SpeakCore

final class AnyCodableTests: XCTestCase {

    // MARK: - Decode Priority

    func testDecode_bool_preferredOverInt() throws {
        // "true" must decode as Bool, not Int (1)
        let data = Data("true".utf8)
        let result = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(result.value is Bool, "Bool JSON should decode as Bool, got \(type(of: result.value))")
        XCTAssertEqual(result.value as? Bool, true)
    }

    func testDecode_false_preferredOverInt() throws {
        let data = Data("false".utf8)
        let result = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(result.value is Bool, "Bool JSON should decode as Bool, got \(type(of: result.value))")
        XCTAssertEqual(result.value as? Bool, false)
    }

    func testDecode_integer_decodesAsInt() throws {
        let data = Data("42".utf8)
        let result = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(result.value as? Int, 42)
    }

    func testDecode_float_decodesAsDouble() throws {
        let data = Data("3.14".utf8)
        let result = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(result.value as? Double, 3.14, accuracy: 1e-10)
    }

    func testDecode_string_decodesAsString() throws {
        let data = Data("\"hello\"".utf8)
        let result = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(result.value as? String, "hello")
    }

    func testDecode_null_decodesAsNSNull() throws {
        let data = Data("null".utf8)
        let result = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(result.value is NSNull, "null JSON should decode as NSNull")
    }

    func testDecode_array_decodesAsArray() throws {
        let data = Data("[1, \"two\", true]".utf8)
        let result = try JSONDecoder().decode(AnyCodable.self, from: data)
        guard let array = result.value as? [Any] else {
            XCTFail("Expected [Any], got \(type(of: result.value))")
            return
        }
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array[0] as? Int, 1)
        XCTAssertEqual(array[1] as? String, "two")
        XCTAssertEqual(array[2] as? Bool, true)
    }

    func testDecode_dict_decodesAsStringKeyedDict() throws {
        let data = Data("{\"key\": 99}".utf8)
        let result = try JSONDecoder().decode(AnyCodable.self, from: data)
        guard let dict = result.value as? [String: Any] else {
            XCTFail("Expected [String: Any], got \(type(of: result.value))")
            return
        }
        XCTAssertEqual(dict["key"] as? Int, 99)
    }

    // MARK: - Encode Round-Trips

    func testRoundTrip_bool() throws {
        let original = AnyCodable(true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Bool, true)
    }

    func testRoundTrip_int() throws {
        let original = AnyCodable(7)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Int, 7)
    }

    func testRoundTrip_double() throws {
        let original = AnyCodable(2.718)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Double ?? 0, 2.718, accuracy: 1e-10)
    }

    func testRoundTrip_string() throws {
        let original = AnyCodable("swift")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? String, "swift")
    }

    func testRoundTrip_nsNull() throws {
        let original = AnyCodable(NSNull())
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testRoundTrip_array() throws {
        let original = AnyCodable([1, "two", false] as [Any])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        guard let array = decoded.value as? [Any] else {
            XCTFail("Expected array")
            return
        }
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array[0] as? Int, 1)
        XCTAssertEqual(array[1] as? String, "two")
        XCTAssertEqual(array[2] as? Bool, false)
    }

    func testRoundTrip_dict() throws {
        let original = AnyCodable(["x": 10, "y": 20] as [String: Any])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        guard let dict = decoded.value as? [String: Any] else {
            XCTFail("Expected [String: Any]")
            return
        }
        XCTAssertEqual(dict["x"] as? Int, 10)
        XCTAssertEqual(dict["y"] as? Int, 20)
    }

    func testRoundTrip_nested() throws {
        // Nested: dict containing array containing dict
        let original = AnyCodable(["items": [["id": 1], ["id": 2]]] as [String: Any])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        guard let outer = decoded.value as? [String: Any],
              let items = outer["items"] as? [Any],
              let first = items.first as? [String: Any]
        else {
            XCTFail("Unexpected structure")
            return
        }
        XCTAssertEqual(first["id"] as? Int, 1)
        XCTAssertEqual(items.count, 2)
    }

    // MARK: - Encode Error

    func testEncode_unsupportedType_throws() {
        struct Unsupported {}
        let codable = AnyCodable(Unsupported())
        XCTAssertThrowsError(try JSONEncoder().encode(codable)) { error in
            XCTAssertTrue(error is EncodingError, "Expected EncodingError, got \(type(of: error))")
        }
    }
}
