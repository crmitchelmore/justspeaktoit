import XCTest
import Foundation

@testable import SpeakCore

final class AnyCodableTests: XCTestCase {

    // MARK: - Helpers

    private func roundTrip<T: Codable>(_ value: T) throws -> Any {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        return decoded.value
    }

    private func decodeJSON(_ json: String) throws -> AnyCodable {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(AnyCodable.self, from: data)
    }

    private func encodeToJSON(_ value: Any) throws -> String {
        let wrapped = AnyCodable(value)
        let data = try JSONEncoder().encode(wrapped)
        return String(data: data, encoding: .utf8)!
    }

    // MARK: - Decode: null

    func testDecode_null_yieldsNSNull() throws {
        let result = try decodeJSON("null")
        XCTAssertTrue(result.value is NSNull, "null JSON should decode to NSNull")
    }

    // MARK: - Decode: Bool

    func testDecode_boolTrue_yieldsBool() throws {
        let result = try decodeJSON("true")
        guard let boolVal = result.value as? Bool else {
            return XCTFail("Expected Bool, got \(type(of: result.value))")
        }
        XCTAssertTrue(boolVal)
    }

    func testDecode_boolFalse_yieldsBool() throws {
        let result = try decodeJSON("false")
        guard let boolVal = result.value as? Bool else {
            return XCTFail("Expected Bool, got \(type(of: result.value))")
        }
        XCTAssertFalse(boolVal)
    }

    // MARK: - Decode: Numeric priority (Bool before Int before Double)

    func testDecode_integer_yieldsInt() throws {
        let result = try decodeJSON("42")
        XCTAssertTrue(result.value is Int, "Integer JSON should decode to Int, got \(type(of: result.value))")
        XCTAssertEqual(result.value as? Int, 42)
    }

    func testDecode_negativeInteger_yieldsInt() throws {
        let result = try decodeJSON("-7")
        XCTAssertEqual(result.value as? Int, -7)
    }

    func testDecode_floatingPoint_yieldsDouble() throws {
        let result = try decodeJSON("3.14")
        XCTAssertTrue(result.value is Double, "Float JSON should decode to Double")
        XCTAssertEqual(result.value as? Double, 3.14, accuracy: 1e-10)
    }

    // MARK: - Decode: String

    func testDecode_string_yieldsString() throws {
        let result = try decodeJSON("\"hello world\"")
        XCTAssertEqual(result.value as? String, "hello world")
    }

    func testDecode_emptyString_yieldsEmptyString() throws {
        let result = try decodeJSON("\"\"")
        XCTAssertEqual(result.value as? String, "")
    }

    func testDecode_unicodeString_preservesCharacters() throws {
        let result = try decodeJSON("\"Héllo, 世界 🎙️\"")
        XCTAssertEqual(result.value as? String, "Héllo, 世界 🎙️")
    }

    // MARK: - Decode: Array

    func testDecode_array_yieldsArrayOfValues() throws {
        let result = try decodeJSON("[1, 2, 3]")
        guard let array = result.value as? [Any] else {
            return XCTFail("Expected [Any] for array JSON")
        }
        XCTAssertEqual(array.count, 3)
        XCTAssertEqual(array[0] as? Int, 1)
        XCTAssertEqual(array[1] as? Int, 2)
        XCTAssertEqual(array[2] as? Int, 3)
    }

    func testDecode_emptyArray_yieldsEmptyArray() throws {
        let result = try decodeJSON("[]")
        guard let array = result.value as? [Any] else {
            return XCTFail("Expected [Any]")
        }
        XCTAssertTrue(array.isEmpty)
    }

    func testDecode_mixedArray_preservesTypes() throws {
        let result = try decodeJSON("[true, 42, \"text\", null]")
        guard let array = result.value as? [Any] else {
            return XCTFail("Expected [Any]")
        }
        XCTAssertEqual(array.count, 4)
        XCTAssertTrue(array[0] is Bool)
        XCTAssertTrue(array[1] is Int)
        XCTAssertTrue(array[2] is String)
        XCTAssertTrue(array[3] is NSNull)
    }

    // MARK: - Decode: Object

    func testDecode_object_yieldsDictionary() throws {
        let result = try decodeJSON(#"{"key":"value","count":10}"#)
        guard let dict = result.value as? [String: Any] else {
            return XCTFail("Expected [String: Any] for object JSON")
        }
        XCTAssertEqual(dict["key"] as? String, "value")
        XCTAssertEqual(dict["count"] as? Int, 10)
    }

    func testDecode_emptyObject_yieldsEmptyDictionary() throws {
        let result = try decodeJSON("{}")
        guard let dict = result.value as? [String: Any] else {
            return XCTFail("Expected [String: Any]")
        }
        XCTAssertTrue(dict.isEmpty)
    }

    func testDecode_nestedObject_preservesDepth() throws {
        let result = try decodeJSON(#"{"outer":{"inner":"value"}}"#)
        guard let outer = result.value as? [String: Any],
              let inner = outer["outer"] as? [String: Any] else {
            return XCTFail("Expected nested [String: Any]")
        }
        XCTAssertEqual(inner["inner"] as? String, "value")
    }

    // MARK: - Encode: null

    func testEncode_NSNull_producesNullJSON() throws {
        let json = try encodeToJSON(NSNull())
        XCTAssertEqual(json, "null")
    }

    // MARK: - Encode: Bool

    func testEncode_boolTrue_producesTrueJSON() throws {
        let json = try encodeToJSON(true)
        XCTAssertEqual(json, "true")
    }

    func testEncode_boolFalse_producesFalseJSON() throws {
        let json = try encodeToJSON(false)
        XCTAssertEqual(json, "false")
    }

    // MARK: - Encode: Numeric

    func testEncode_int_producesIntegerJSON() throws {
        let json = try encodeToJSON(99)
        XCTAssertEqual(json, "99")
    }

    func testEncode_double_producesDecimalJSON() throws {
        let json = try encodeToJSON(2.5)
        XCTAssertEqual(json, "2.5")
    }

    // MARK: - Encode: String

    func testEncode_string_producesQuotedJSON() throws {
        let json = try encodeToJSON("hello")
        XCTAssertEqual(json, "\"hello\"")
    }

    // MARK: - Encode: Array

    func testEncode_intArray_producesArrayJSON() throws {
        let json = try encodeToJSON([1, 2, 3] as [Any])
        XCTAssertEqual(json, "[1,2,3]")
    }

    // MARK: - Encode: unsupported type throws

    func testEncode_unsupportedType_throwsEncodingError() {
        // Date is not a natively supported AnyCodable type
        struct Unsupported {}
        let wrapped = AnyCodable(Unsupported())
        XCTAssertThrowsError(try JSONEncoder().encode(wrapped),
            "Encoding an unsupported type should throw EncodingError")
    }

    // MARK: - Round-trip fidelity

    func testRoundTrip_bool_preservesValue() throws {
        let data = try JSONEncoder().encode(AnyCodable(true))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Bool, true)
    }

    func testRoundTrip_int_preservesValue() throws {
        let data = try JSONEncoder().encode(AnyCodable(123))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? Int, 123)
    }

    func testRoundTrip_string_preservesValue() throws {
        let data = try JSONEncoder().encode(AnyCodable("test string"))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)
        XCTAssertEqual(decoded.value as? String, "test string")
    }

    func testRoundTrip_nestedDictWithArray_preservesStructure() throws {
        let original: [String: Any] = ["nums": [1, 2, 3], "label": "test"]
        let data = try JSONEncoder().encode(AnyCodable(original))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: data)

        guard let dict = decoded.value as? [String: Any],
              let nums = dict["nums"] as? [Any] else {
            return XCTFail("Expected nested dict with array")
        }
        XCTAssertEqual(nums.count, 3)
        XCTAssertEqual(dict["label"] as? String, "test")
    }

    // MARK: - Real-world payload (AssemblyAI-style)

    func testDecode_assemblyAIStylePayload_parsesCorrectly() throws {
        let json = """
        {
            "message_type": "SessionBegins",
            "session_id": "abc-123",
            "expires_at": 1234567890
        }
        """
        let result = try JSONDecoder().decode(AnyCodable.self, from: Data(json.utf8))
        guard let dict = result.value as? [String: Any] else {
            return XCTFail("Expected dictionary")
        }
        XCTAssertEqual(dict["message_type"] as? String, "SessionBegins")
        XCTAssertEqual(dict["session_id"] as? String, "abc-123")
        XCTAssertEqual(dict["expires_at"] as? Int, 1234567890)
    }
}
