import XCTest

@testable import SpeakCore

final class AnyCodableTests: XCTestCase {

    // MARK: - Decoding: Primitives

    func testDecode_null() throws {
        let json = "null".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssert(result.value is NSNull)
    }

    func testDecode_bool_true() throws {
        let json = "true".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(result.value as? Bool, true)
    }

    func testDecode_bool_false() throws {
        let json = "false".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(result.value as? Bool, false)
    }

    func testDecode_int() throws {
        let json = "42".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(result.value as? Int, 42)
    }

    func testDecode_double() throws {
        let json = "3.14".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(result.value as? Double, 3.14, accuracy: 0.0001)
    }

    func testDecode_string() throws {
        let json = "\"hello\"".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(result.value as? String, "hello")
    }

    func testDecode_emptyString() throws {
        let json = "\"\"".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(result.value as? String, "")
    }

    // MARK: - Decoding: Collections

    func testDecode_array_ofMixedTypes() throws {
        let json = "[1, \"two\", true, null]".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        let array = result.value as? [Any]
        XCTAssertNotNil(array)
        XCTAssertEqual(array?.count, 4)
        XCTAssertEqual(array?[0] as? Int, 1)
        XCTAssertEqual(array?[1] as? String, "two")
        XCTAssertEqual(array?[2] as? Bool, true)
        XCTAssert(array?[3] is NSNull)
    }

    func testDecode_array_empty() throws {
        let json = "[]".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        let array = result.value as? [Any]
        XCTAssertNotNil(array)
        XCTAssertEqual(array?.count, 0)
    }

    func testDecode_dictionary_ofMixedTypes() throws {
        let json = "{\"str\":\"val\",\"num\":7,\"flag\":false}".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        let dict = result.value as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["str"] as? String, "val")
        XCTAssertEqual(dict?["num"] as? Int, 7)
        XCTAssertEqual(dict?["flag"] as? Bool, false)
    }

    func testDecode_dictionary_empty() throws {
        let json = "{}".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        let dict = result.value as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?.count, 0)
    }

    func testDecode_nestedObject() throws {
        let json = "{\"outer\":{\"inner\":\"value\"}}".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        let outer = result.value as? [String: Any]
        let inner = outer?["outer"] as? [String: Any]
        XCTAssertEqual(inner?["inner"] as? String, "value")
    }

    // MARK: - Encoding: Primitives

    func testEncode_null() throws {
        let codable = AnyCodable(NSNull())
        let data = try JSONEncoder().encode(codable)
        XCTAssertEqual(String(data: data, encoding: .utf8), "null")
    }

    func testEncode_bool() throws {
        let codable = AnyCodable(true)
        let data = try JSONEncoder().encode(codable)
        XCTAssertEqual(String(data: data, encoding: .utf8), "true")
    }

    func testEncode_int() throws {
        let codable = AnyCodable(99)
        let data = try JSONEncoder().encode(codable)
        XCTAssertEqual(String(data: data, encoding: .utf8), "99")
    }

    func testEncode_double() throws {
        let codable = AnyCodable(2.5)
        let data = try JSONEncoder().encode(codable)
        let decoded = try JSONDecoder().decode(Double.self, from: data)
        XCTAssertEqual(decoded, 2.5, accuracy: 0.0001)
    }

    func testEncode_string() throws {
        let codable = AnyCodable("world")
        let data = try JSONEncoder().encode(codable)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"world\"")
    }

    func testEncode_array() throws {
        let codable = AnyCodable([1, "two", true] as [Any])
        let data = try JSONEncoder().encode(codable)
        let decoded = try JSONDecoder().decode([AnyCodable].self, from: data)
        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0].value as? Int, 1)
        XCTAssertEqual(decoded[1].value as? String, "two")
        XCTAssertEqual(decoded[2].value as? Bool, true)
    }

    func testEncode_dictionary() throws {
        let codable = AnyCodable(["key": "value"] as [String: Any])
        let data = try JSONEncoder().encode(codable)
        let dict = try JSONDecoder().decode([String: AnyCodable].self, from: data)
        XCTAssertEqual(dict["key"]?.value as? String, "value")
    }

    func testEncode_unsupportedType_throws() throws {
        struct Opaque {}
        let codable = AnyCodable(Opaque())
        XCTAssertThrowsError(try JSONEncoder().encode(codable)) { error in
            guard case EncodingError.invalidValue = error else {
                XCTFail("Expected EncodingError.invalidValue, got \(error)")
                return
            }
        }
    }

    // MARK: - Round-Trip

    func testRoundTrip_heterogeneousPayload() throws {
        let json = """
        {"name":"Alice","score":100,"active":true,"tags":["swift","testing"],"meta":null}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let reEncoded = try JSONEncoder().encode(decoded)
        let reDecoded = try JSONDecoder().decode(AnyCodable.self, from: reEncoded)

        let dict = reDecoded.value as? [String: Any]
        XCTAssertEqual(dict?["name"] as? String, "Alice")
        XCTAssertEqual(dict?["score"] as? Int, 100)
        XCTAssertEqual(dict?["active"] as? Bool, true)
        let tags = dict?["tags"] as? [Any]
        XCTAssertEqual(tags?.count, 2)
        XCTAssertEqual(tags?[0] as? String, "swift")
        XCTAssert(dict?["meta"] is NSNull)
    }

    // MARK: - Bool/Int priority

    func testDecode_boolTruePreferredOverInt() throws {
        // JSON `true` must decode as Bool, not Int
        let json = "true".data(using: .utf8)!
        let result = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertNotNil(result.value as? Bool, "Bool should be decoded as Bool, not Int")
        XCTAssertNil(result.value as? Int, "Bool value should not decode as Int")
    }
}
