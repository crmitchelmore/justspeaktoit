import Foundation
@testable import SpeakCore
import XCTest

final class AnalyticsPropertyValueTests: XCTestCase {
    func testJSONRoundTripPreservesNativeScalarTypes() throws {
        let values: [String: AnalyticsPropertyValue] = [
            "string": .string("nova-3"),
            "boolean": .boolean(true),
            "integer": .integer(42),
            "double": .double(1.25)
        ]

        let data = try JSONEncoder().encode(values)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["string"] as? String, "nova-3")
        XCTAssertEqual(json["boolean"] as? Bool, true)
        XCTAssertEqual(json["integer"] as? Int, 42)
        XCTAssertEqual(json["double"] as? Double, 1.25)
        XCTAssertEqual(try JSONDecoder().decode([String: AnalyticsPropertyValue].self, from: data), values)
    }
}
