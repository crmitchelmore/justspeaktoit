import XCTest

@testable import SpeakCore

// MARK: - Helpers

private func encode(_ value: AnyCodable) throws -> String {
    let data = try JSONEncoder().encode(value)
    return String(data: data, encoding: .utf8)!
}

private func decode(_ json: String) throws -> AnyCodable {
    let data = Data(json.utf8)
    return try JSONDecoder().decode(AnyCodable.self, from: data)
}

// MARK: - AnyCodableTests

final class AnyCodableTests: XCTestCase {

    // MARK: - Decode: nil

    func testDecode_null_yieldsNSNull() throws {
        let result = try decode("null")
        XCTAssertTrue(result.value is NSNull)
    }

    // MARK: - Decode: Bool

    func testDecode_true_yieldsBool() throws {
        let result = try decode("true")
        XCTAssertEqual(result.value as? Bool, true)
    }

    func testDecode_false_yieldsBool() throws {
        let result = try decode("false")
        XCTAssertEqual(result.value as? Bool, false)
    }

    // MARK: - Decode: Int (preferred over Double when value is whole)

    func testDecode_wholeNumber_yieldsInt() throws {
        let result = try decode("42")
        XCTAssertEqual(result.value as? Int, 42)
    }

    func testDecode_negativeInt_yieldsInt() throws {
        let result = try decode("-7")
        XCTAssertEqual(result.value as? Int, -7)
    }

    // MARK: - Decode: Double

    func testDecode_fractionalNumber_yieldsDouble() throws {
        let result = try decode("3.14")
        XCTAssertEqual(result.value as? Double, 3.14, accuracy: 0.0001)
    }

    func testDecode_negativeDouble_yieldsDouble() throws {
        let result = try decode("-0.5")
        XCTAssertEqual(result.value as? Double, -0.5, accuracy: 0.0001)
    }

    // MARK: - Decode: String

    func testDecode_string_yieldsString() throws {
        let result = try decode("\"hello\"")
        XCTAssertEqual(result.value as? String, "hello")
    }

    func testDecode_emptyString_yieldsString() throws {
        let result = try decode("\"\"")
        XCTAssertEqual(result.value as? String, "")
    }

    func testDecode_stringWithSpecialChars_preserved() throws {
        let result = try decode("\"café 🎙️\"")
        XCTAssertEqual(result.value as? String, "café 🎙️")
    }

    // MARK: - Decode: Array

    func testDecode_homogeneousArray_yieldsAnyArray() throws {
        let result = try decode("[1,2,3]")
        let arr = result.value as? [Any]
        XCTAssertEqual(arr?.count, 3)
        XCTAssertEqual(arr?[0] as? Int, 1)
        XCTAssertEqual(arr?[1] as? Int, 2)
        XCTAssertEqual(arr?[2] as? Int, 3)
    }

    func testDecode_heterogeneousArray_yieldsAnyArray() throws {
        let result = try decode("[true, 1, \"x\", null]")
        let arr = result.value as? [Any]
        XCTAssertEqual(arr?.count, 4)
        XCTAssertEqual(arr?[0] as? Bool, true)
        XCTAssertEqual(arr?[1] as? Int, 1)
        XCTAssertEqual(arr?[2] as? String, "x")
        XCTAssertTrue(arr?[3] is NSNull)
    }

    func testDecode_emptyArray_yieldsEmptyArray() throws {
        let result = try decode("[]")
        let arr = result.value as? [Any]
        XCTAssertNotNil(arr)
        XCTAssertEqual(arr?.count, 0)
    }

    // MARK: - Decode: Dictionary

    func testDecode_simpleDictionary_yieldsStringAnyDict() throws {
        let result = try decode("{\"key\":\"value\"}")
        let dict = result.value as? [String: Any]
        XCTAssertEqual(dict?["key"] as? String, "value")
    }

    func testDecode_mixedDictionary_preservesTypes() throws {
        let result = try decode("{\"n\":1,\"s\":\"hi\",\"b\":true,\"nil\":null}")
        let dict = result.value as? [String: Any]
        XCTAssertEqual(dict?["n"] as? Int, 1)
        XCTAssertEqual(dict?["s"] as? String, "hi")
        XCTAssertEqual(dict?["b"] as? Bool, true)
        XCTAssertTrue(dict?["nil"] is NSNull)
    }

    func testDecode_emptyDictionary_yieldsEmptyDict() throws {
        let result = try decode("{}")
        let dict = result.value as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?.count, 0)
    }

    // MARK: - Decode: Nested structures

    func testDecode_nestedDictionary_decodesRecursively() throws {
        let result = try decode("{\"outer\":{\"inner\":99}}")
        let dict = result.value as? [String: Any]
        let outer = dict?["outer"] as? [String: Any]
        XCTAssertEqual(outer?["inner"] as? Int, 99)
    }

    func testDecode_arrayOfDicts_decodesRecursively() throws {
        let result = try decode("[{\"id\":1},{\"id\":2}]")
        let arr = result.value as? [Any]
        XCTAssertEqual(arr?.count, 2)
        let first = arr?[0] as? [String: Any]
        let second = arr?[1] as? [String: Any]
        XCTAssertEqual(first?["id"] as? Int, 1)
        XCTAssertEqual(second?["id"] as? Int, 2)
    }

    // MARK: - Encode: nil

    func testEncode_NSNull_encodesNull() throws {
        let encoded = try encode(AnyCodable(NSNull()))
        XCTAssertEqual(encoded, "null")
    }

    // MARK: - Encode: Bool

    func testEncode_true_encodesBoolTrue() throws {
        let encoded = try encode(AnyCodable(true))
        XCTAssertEqual(encoded, "true")
    }

    func testEncode_false_encodesBoolFalse() throws {
        let encoded = try encode(AnyCodable(false))
        XCTAssertEqual(encoded, "false")
    }

    // MARK: - Encode: Int

    func testEncode_int_encodesNumber() throws {
        let encoded = try encode(AnyCodable(42))
        XCTAssertEqual(encoded, "42")
    }

    // MARK: - Encode: Double

    func testEncode_double_encodesDecimal() throws {
        let encoded = try encode(AnyCodable(3.14))
        XCTAssertEqual(Double(encoded)!, 3.14, accuracy: 0.0001)
    }

    // MARK: - Encode: String

    func testEncode_string_encodesQuotedString() throws {
        let encoded = try encode(AnyCodable("hello"))
        XCTAssertEqual(encoded, "\"hello\"")
    }

    // MARK: - Encode: Array

    func testEncode_intArray_encodesJSONArray() throws {
        let encoded = try encode(AnyCodable([1, 2, 3]))
        XCTAssertEqual(encoded, "[1,2,3]")
    }

    func testEncode_mixedArray_encodesCorrectly() throws {
        let encoded = try encode(AnyCodable([true, 1, "x"] as [Any]))
        XCTAssertEqual(encoded, "[true,1,\"x\"]")
    }

    func testEncode_emptyArray_encodesEmptyJSONArray() throws {
        let encoded = try encode(AnyCodable([Any]()))
        XCTAssertEqual(encoded, "[]")
    }

    // MARK: - Encode: Dictionary

    func testEncode_stringDict_encodesJSONObject() throws {
        let encoded = try encode(AnyCodable(["key": "value"]))
        XCTAssertEqual(encoded, "{\"key\":\"value\"}")
    }

    func testEncode_emptyDict_encodesEmptyJSONObject() throws {
        let encoded = try encode(AnyCodable([String: Any]()))
        XCTAssertEqual(encoded, "{}")
    }

    // MARK: - Encode: Unsupported type throws

    func testEncode_unsupportedType_throwsEncodingError() {
        struct Unknown {}
        XCTAssertThrowsError(try encode(AnyCodable(Unknown()))) { error in
            XCTAssertTrue(error is EncodingError, "Expected EncodingError, got \(error)")
        }
    }

    // MARK: - Round-trip

    func testRoundTrip_null() throws {
        let original = AnyCodable(NSNull())
        let encoded = try encode(original)
        let decoded = try decode(encoded)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testRoundTrip_bool() throws {
        for value in [true, false] {
            let original = AnyCodable(value)
            let encoded = try encode(original)
            let decoded = try decode(encoded)
            XCTAssertEqual(decoded.value as? Bool, value)
        }
    }

    func testRoundTrip_int() throws {
        let original = AnyCodable(123)
        let encoded = try encode(original)
        let decoded = try decode(encoded)
        XCTAssertEqual(decoded.value as? Int, 123)
    }

    func testRoundTrip_string() throws {
        let original = AnyCodable("round-trip")
        let encoded = try encode(original)
        let decoded = try decode(encoded)
        XCTAssertEqual(decoded.value as? String, "round-trip")
    }

    func testRoundTrip_nestedDictionary() throws {
        let json = "{\"a\":{\"b\":[1,2,3]},\"c\":true}"
        let decoded = try decode(json)
        let reencoded = try encode(decoded)
        // Re-decode and verify structure preserved
        let final_ = try decode(reencoded)
        let dict = final_.value as? [String: Any]
        XCTAssertEqual(dict?["c"] as? Bool, true)
        let a = dict?["a"] as? [String: Any]
        let b = a?["b"] as? [Any]
        XCTAssertEqual(b?.count, 3)
    }
}
