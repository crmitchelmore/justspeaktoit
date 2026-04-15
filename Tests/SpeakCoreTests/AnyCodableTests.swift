import XCTest

@testable import SpeakCore

final class AnyCodableTests: XCTestCase {

    private func roundTrip<T: Equatable>(_ value: Any, as type: T.Type) throws -> T {
        let encoded = try JSONEncoder().encode(AnyCodable(value))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        guard let result = decoded.value as? T else {
            XCTFail("Expected \(T.self), got \(Swift.type(of: decoded.value))")
            throw XCTSkip("Type mismatch")
        }
        return result
    }

    // MARK: - Decode primitives

    func testDecode_string_returnsString() throws {
        let json = #""hello""#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(decoded.value as? String, "hello")
    }

    func testDecode_integer_returnsInt() throws {
        let json = "42".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(decoded.value as? Int, 42)
    }

    func testDecode_double_returnsDouble() throws {
        let json = "3.14".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(decoded.value as? Double, 3.14, accuracy: 0.001)
    }

    func testDecode_bool_returnsBool() throws {
        let jsonTrue = "true".data(using: .utf8)!
        let jsonFalse = "false".data(using: .utf8)!
        XCTAssertEqual((try JSONDecoder().decode(AnyCodable.self, from: jsonTrue)).value as? Bool, true)
        XCTAssertEqual((try JSONDecoder().decode(AnyCodable.self, from: jsonFalse)).value as? Bool, false)
    }

    func testDecode_null_returnsNSNull() throws {
        let json = "null".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testDecode_array_returnsArray() throws {
        let json = #"[1, "two", true]"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let array = decoded.value as? [Any]
        XCTAssertNotNil(array)
        XCTAssertEqual(array?.count, 3)
        XCTAssertEqual(array?[0] as? Int, 1)
        XCTAssertEqual(array?[1] as? String, "two")
        XCTAssertEqual(array?[2] as? Bool, true)
    }

    func testDecode_dict_returnsDictionary() throws {
        let json = #"{"key": "value", "num": 10}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let dict = decoded.value as? [String: Any]
        XCTAssertNotNil(dict)
        XCTAssertEqual(dict?["key"] as? String, "value")
        XCTAssertEqual(dict?["num"] as? Int, 10)
    }

    // MARK: - Encode and roundtrip

    func testEncode_string_roundTrips() throws {
        let result = try roundTrip("hello", as: String.self)
        XCTAssertEqual(result, "hello")
    }

    func testEncode_integer_roundTrips() throws {
        let result = try roundTrip(99, as: Int.self)
        XCTAssertEqual(result, 99)
    }

    func testEncode_bool_roundTrips() throws {
        XCTAssertEqual(try roundTrip(true, as: Bool.self), true)
        XCTAssertEqual(try roundTrip(false, as: Bool.self), false)
    }

    func testEncode_null_roundTrips() throws {
        let encoded = try JSONEncoder().encode(AnyCodable(NSNull()))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testEncode_array_roundTrips() throws {
        let arr: [Any] = [1, "two", false]
        let encoded = try JSONEncoder().encode(AnyCodable(arr))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        let result = decoded.value as? [Any]
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?[1] as? String, "two")
    }

    func testEncode_dict_roundTrips() throws {
        let dict: [String: Any] = ["a": 1, "b": "bee"]
        let encoded = try JSONEncoder().encode(AnyCodable(dict))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        let result = decoded.value as? [String: Any]
        XCTAssertEqual(result?["b"] as? String, "bee")
    }

    func testEncode_unsupportedType_throws() {
        struct Unsupported {}
        let codable = AnyCodable(Unsupported())
        XCTAssertThrowsError(try JSONEncoder().encode(codable), "Encoding unsupported type should throw")
    }

    // MARK: - Nested structures

    func testDecode_nestedDict_isAccessible() throws {
        let json = #"{"outer": {"inner": 42}}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let outer = (decoded.value as? [String: Any])?["outer"] as? [String: Any]
        XCTAssertEqual(outer?["inner"] as? Int, 42)
    }

    func testDecode_arrayOfDicts_isAccessible() throws {
        let json = #"[{"id": 1}, {"id": 2}]"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let arr = decoded.value as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
        XCTAssertEqual(arr?.first?["id"] as? Int, 1)
    }
}
