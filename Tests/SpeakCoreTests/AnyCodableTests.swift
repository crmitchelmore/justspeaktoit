import XCTest

@testable import SpeakCore

final class AnyCodableTests: XCTestCase {

    private func roundTrip<T: Equatable>(_ value: Any, as type: T.Type) throws -> T {
        let encoded = try JSONEncoder().encode(try AnyCodable(value))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        guard let result = decoded.value as? T else {
            XCTFail("Expected \(T.self), got \(Swift.type(of: decoded.value))")
            throw XCTSkip("Type mismatch")
        }
        return result
    }

    // MARK: - Decode primitives

    func testDecode_string_returnsString() throws {
        let json = Data(#""hello""#.utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(decoded.value as? String, "hello")
    }

    func testDecode_integer_returnsInt() throws {
        let json = Data("42".utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertEqual(decoded.value as? Int, 42)
    }

    func testDecode_double_returnsDouble() throws {
        let json = Data("3.14".utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        guard let value = decoded.value as? Double else {
            XCTFail("Expected Double, got \(Swift.type(of: decoded.value))")
            return
        }
        XCTAssertEqual(value, 3.14, accuracy: 0.001)
    }

    func testDecode_bool_returnsBool() throws {
        let jsonTrue = Data("true".utf8)
        let jsonFalse = Data("false".utf8)
        XCTAssertEqual((try JSONDecoder().decode(AnyCodable.self, from: jsonTrue)).value as? Bool, true)
        XCTAssertEqual((try JSONDecoder().decode(AnyCodable.self, from: jsonFalse)).value as? Bool, false)
    }

    func testDecode_null_returnsNSNull() throws {
        let json = Data("null".utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testDecode_array_returnsArray() throws {
        let json = Data(#"[1, "two", true]"#.utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let array = decoded.value as? [Any]
        XCTAssertNotNil(array)
        XCTAssertEqual(array?.count, 3)
        XCTAssertEqual(array?[0] as? Int, 1)
        XCTAssertEqual(array?[1] as? String, "two")
        XCTAssertEqual(array?[2] as? Bool, true)
    }

    func testDecode_dict_returnsDictionary() throws {
        let json = Data(#"{"key": "value", "num": 10}"#.utf8)
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
        let encoded = try JSONEncoder().encode(try AnyCodable(NSNull()))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        XCTAssertTrue(decoded.value is NSNull)
    }

    func testEncode_array_roundTrips() throws {
        let arr: [Any] = [1, "two", false]
        let encoded = try JSONEncoder().encode(try AnyCodable(arr))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        let result = decoded.value as? [Any]
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.count, 3)
        XCTAssertEqual(result?[1] as? String, "two")
    }

    func testEncode_dict_roundTrips() throws {
        let dict: [String: Any] = ["a": 1, "b": "bee"]
        let encoded = try JSONEncoder().encode(try AnyCodable(dict))
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: encoded)
        let result = decoded.value as? [String: Any]
        XCTAssertEqual(result?["b"] as? String, "bee")
    }

    // MARK: - Nested structures

    func testDecode_nestedDict_isAccessible() throws {
        let json = Data(#"{"outer": {"inner": 42}}"#.utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let outer = (decoded.value as? [String: Any])?["outer"] as? [String: Any]
        XCTAssertEqual(outer?["inner"] as? Int, 42)
    }

    func testDecode_arrayOfDicts_isAccessible() throws {
        let json = Data(#"[{"id": 1}, {"id": 2}]"#.utf8)
        let decoded = try JSONDecoder().decode(AnyCodable.self, from: json)
        let arr = decoded.value as? [[String: Any]]
        XCTAssertEqual(arr?.count, 2)
        XCTAssertEqual(arr?.first?["id"] as? Int, 1)
    }

    // MARK: - Construction validation (Sendable invariants)

    func testInit_unsupportedType_throwsAtConstruction() {
        struct Unsupported {}
        XCTAssertThrowsError(try AnyCodable(Unsupported())) { error in
            guard case .unsupportedValue(let typeName)? = error as? AnyCodableError else {
                XCTFail("Expected AnyCodableError.unsupportedValue, got \(error)")
                return
            }
            XCTAssertTrue(typeName.contains("Unsupported"))
        }
    }

    func testInit_unsupportedNestedType_throwsAtConstruction() {
        let dict: [String: Any] = ["ok": 1, "bad": Date()]
        XCTAssertThrowsError(try AnyCodable(dict)) { error in
            XCTAssertTrue(error is AnyCodableError)
        }
    }

    func testInit_nilOptional_becomesNull() throws {
        let value: String? = nil
        let wrapped = try AnyCodable(value as Any)
        XCTAssertEqual(wrapped.storage, .null)
    }

    func testInit_preservesBoolVersusIntDistinction() throws {
        XCTAssertEqual(try AnyCodable(true).storage, .bool(true))
        XCTAssertEqual(try AnyCodable(1).storage, .int(1))
        XCTAssertEqual(try AnyCodable(NSNumber(value: true)).storage, .bool(true))
        XCTAssertEqual(try AnyCodable(NSNumber(value: 1)).storage, .int(1))
    }

    func testInit_jsonSerializationOutput_isAccepted() throws {
        let json = Data(#"{"a": [1, 2.5, true, null, "s"]}"#.utf8)
        let object = try JSONSerialization.jsonObject(with: json, options: [.mutableContainers])
        let wrapped = try AnyCodable(object)
        XCTAssertEqual(
            wrapped.storage,
            .object(["a": .array([.int(1), .double(2.5), .bool(true), .null, .string("s")])])
        )
    }

    func testEncodedShape_isStableForPrimitives() throws {
        XCTAssertEqual(try JSONEncoder().encode(try AnyCodable(42)), Data("42".utf8))
        XCTAssertEqual(try JSONEncoder().encode(try AnyCodable(true)), Data("true".utf8))
        XCTAssertEqual(try JSONEncoder().encode(try AnyCodable("x")), Data(#""x""#.utf8))
    }

    // MARK: - Defensive copying of mutable Foundation containers

    func testInit_mutableDictionary_isDeepCopied() throws {
        let inner = NSMutableArray(array: [1, 2])
        let original = NSMutableDictionary(dictionary: ["items": inner, "name": "before"])

        let wrapped = try AnyCodable(original)

        original["name"] = "after"
        inner.add(3)

        XCTAssertEqual(
            wrapped.storage,
            .object(["items": .array([.int(1), .int(2)]), "name": .string("before")])
        )
    }

    func testInit_mutableArray_isDeepCopied() throws {
        let original = NSMutableArray(array: ["a"])
        let wrapped = try AnyCodable(original)

        original.add("b")

        XCTAssertEqual(wrapped.storage, .array([.string("a")]))
    }

    func testInit_mutableString_isCopied() throws {
        let original = NSMutableString(string: "hello")
        let wrapped = try AnyCodable(original)

        original.append(" world")

        XCTAssertEqual(wrapped.storage, .string("hello"))
    }

    // MARK: - Concurrency

    func testActorTransfer_encodingIsDeterministicWhileOriginalMutates() async throws {
        let original = NSMutableDictionary(dictionary: ["count": 0])
        let wrapped = try AnyCodable(original)
        let expected = try JSONEncoder().encode(wrapped)

        let mutator = Task.detached {
            for index in 1...500 {
                original["count"] = index
            }
        }

        let encodings = await Task.detached { () -> [Data] in
            (0..<100).compactMap { _ in try? JSONEncoder().encode(wrapped) }
        }.value

        await mutator.value

        XCTAssertEqual(encodings.count, 100)
        for encoded in encodings {
            XCTAssertEqual(encoded, expected)
        }
    }
}
