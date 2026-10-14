import Foundation
import XCTest
@testable import SpeakCore

final class JSONMemberPreflightTests: XCTestCase {
    private func limits(
        bytes: UInt64 = 128_000_000, depth: Int = 8, tokens: Int = 4096,
        records: Int = 20, keys: Int = 32, span: Int = 512, stride: Int = 4096
    ) -> JSONMemberPreflight.Limits {
        .init(maximumBytes: bytes, maximumDepth: depth, maximumTokens: tokens,
              maximumRootRecords: records, maximumObjectKeys: keys, maximumEncodedKeySpan: span,
              cancellationStride: stride)
    }

    private func scan(_ text: String, limits: JSONMemberPreflight.Limits? = nil) throws {
        try JSONMemberPreflight.validate(Data(text.utf8), limits: limits ?? self.limits(),
                                        checkCancellation: {}, invalid: { ProbeError.invalid })
    }

    func testOriginal86aRegressionCorpus_RetainsAcceptedStructuresEscapesAndLargeValues() throws {
        let body = #"{"schemaVersion":1,"sourcePlatform":"windows","sourcePath":"postProcessing.customPrompt","# +
            #""provenance":"nativeSettings","isPresent":true,"value":"{escaped \"value\":[]}"}"#
        let record = #"{"id":"native/windows/postProcessing.customPrompt","kind":"nativeConfiguration","value":"# +
            body + "}"
        for raw in ["[]", "[\(record)]", "[\(Array(repeating: record, count: 20).joined(separator: ","))]",
                    #"{"empty":null,"bool":true,"number":-1.5e2,"nested":[{"different":"keys"}]}"#,
                    #"{"value":""# + String(repeating: "p", count: 1_048_577) + #""}"#] {
            try scan(raw)
            _ = try JSONDecoder().decode(AnyCodable.self, from: Data(raw.utf8))
        }
    }

    func testDecodedDuplicateKeys_RejectPlainEscapedAndNestedDuplicates() throws {
        for raw in [#"{"id":1,"id":2}"#, #"{"id":1,"\u0069d":2}"#,
                    #"{"value":{"isPresent":true,"\u0069sPresent":false}}"#,
                    #"{"a\/b":1,"a/b":2}"#] {
            XCTAssertThrowsError(try scan(raw))
        }
        try scan(#"[{"id":1},{"id":2}]"#)
    }

    func testEveryOriginalBound_HasExactAcceptanceAndRejectionEdges() throws {
        try scan("[]", limits: limits(bytes: 2))
        XCTAssertThrowsError(try scan("[]", limits: limits(bytes: 1)))
        try scan(String(repeating: "[", count: 8) + "0" + String(repeating: "]", count: 8))
        XCTAssertThrowsError(try scan(String(repeating: "[", count: 9) + "0" + String(repeating: "]", count: 9)))
        try scan("[0,0]", limits: limits(tokens: 2))
        XCTAssertThrowsError(try scan("[0,0]", limits: limits(tokens: 1)))
        try scan("[0,0]", limits: limits(records: 2))
        XCTAssertThrowsError(try scan("[0,0]", limits: limits(records: 1)))
        XCTAssertThrowsError(try scan("[]", limits: limits(records: 0)))
        let keys = (0..<32).map { "\"key\($0)\":null" }.joined(separator: ",")
        try scan("{\(keys)}")
        XCTAssertThrowsError(try scan("{\(keys),\"extra\":null}"))
        try scan("{\"\(String(repeating: "k", count: 511))\":null}")
        XCTAssertThrowsError(try scan("{\"\(String(repeating: "k", count: 512))\":null}"))
        try scan(#"{"\u0061":0}"#, limits: limits(span: 7))
        XCTAssertThrowsError(try scan(#"{"\u0061":0}"#, limits: limits(span: 6)))
    }

    func testMalformedAndTrailingInputs_AreRejectedByPreflightOrSubsequentFoundationGrammar() {
        for raw in ["{", "[}", #""unterminated"#, #"{ "bad\q":0 }"#,
                    "[] trailing", "true false", "", #"{ "a": }"#] {
            XCTAssertThrowsError(try {
                try self.scan(raw)
                _ = try JSONDecoder().decode(AnyCodable.self, from: Data(raw.utf8))
            }())
        }
    }

    func testGrammarAndRootShape_AreNotInventedByMemberPreflight() throws {
        try scan("[] trailing")
        try scan("null")
        try scan("[0,]")
        XCTAssertEqual(try JSONDecoder().decode([Int].self, from: Data("[0,]".utf8)), [0])
        XCTAssertThrowsError(try JSONDecoder().decode(AnyCodable.self, from: Data("[] trailing".utf8)))
    }

    func testCancellation_CadenceIncludesLongValuesKeyLookaheadAndCompletion() throws {
        for raw in [#"{"payload":""# + String(repeating: "A", count: 100_000) + #""}"#,
                    "{\"key\"" + String(repeating: " ", count: 100_000) + ":0}"] {
            var checks = 0
            XCTAssertThrowsError(try JSONMemberPreflight.validate(
                Data(raw.utf8), limits: limits(), checkCancellation: {
                    checks += 1
                    if checks == 8 { throw CancellationError() }
                }, invalid: { ProbeError.invalid }
            )) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, 8)
        }
        var checks = 0
        try JSONMemberPreflight.validate(Data("[]".utf8), limits: limits(), checkCancellation: {
            checks += 1
        }, invalid: { ProbeError.invalid })
        XCTAssertEqual(checks, 3)
    }

    func testInjectedGuardDiagnosticAndFoundationKeyErrors_ArePreserved() {
        XCTAssertThrowsError(try scan("[}")) {
            XCTAssertTrue($0 is ProbeError)
        }
        XCTAssertThrowsError(try scan(#"{"\q":0}"#)) {
            XCTAssertTrue($0 is DecodingError)
        }
        XCTAssertThrowsError(try scan("[]", limits: limits(stride: 0)))
    }

    private enum ProbeError: Error { case invalid }
}
