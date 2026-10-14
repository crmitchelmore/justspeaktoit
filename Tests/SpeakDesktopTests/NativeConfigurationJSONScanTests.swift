import Foundation
@testable import SpeakCore
import XCTest

final class NativeConfigurationJSONScanTests: XCTestCase {
    private let diagnostic = "Malformed or unbounded native configuration JSON."

    private enum Outcome: Equatable {
        case accepted
        case guardFailure(String)
        case foundationFailure
    }

    private func reference(_ data: Data, checkCancellation: () throws -> Void = {}) throws {
        try JSONMemberPreflight.validate(
            data, limits: .init(
                maximumBytes: DataMigrationArchivePolicy.maximumJSONBytes, maximumDepth: 8, maximumTokens: 4096,
                maximumRootRecords: DesktopNativeConfigurationField.allCases.count
                    * DesktopNativeConfigurationCapture.Platform.allCases.count,
                maximumObjectKeys: 32, maximumEncodedKeySpan: 512, cancellationStride: 4096
            ), checkCancellation: checkCancellation, invalid: { DataMigrationError.invalid(self.diagnostic) }
        )
    }

    private func outcome(_ operation: () throws -> Void) throws -> Outcome {
        do {
            try operation()
            return .accepted
        } catch DataMigrationError.invalid(let message) {
            return .guardFailure(message)
        } catch is DecodingError {
            return .foundationFailure
        }
    }

    private func verify(_ raw: String, expected: Outcome) throws {
        let bytes = Data(raw.utf8)
        XCTAssertEqual(try outcome { try NativeConfigurationJSONScan.validate(bytes, checkCancellation: {}) }, expected)
        XCTAssertEqual(try outcome { try reference(bytes) }, expected)
    }

    func testOriginalAcceptanceAndErrorCorpus_MatchesSelectedHelperWithoutInventingGrammar() throws {
        for raw in ["[]", "null", "[0,]", "[] trailing", #"{"a":[{"b":"escaped \" value"}]}"#] {
            try verify(raw, expected: .accepted)
        }
        for raw in ["{", "[}", #""unterminated"#, #"{"id":1,"id":2}"#, #"{"id":1,"\u0069d":2}"#,
                    #"{"value":{"isPresent":true,"\u0069sPresent":false}}"#] {
            try verify(raw, expected: .guardFailure(diagnostic))
        }
        try verify(#"{"\q":0}"#, expected: .foundationFailure)
        XCTAssertThrowsError(try DesktopNativeConfigurationArchiveCodec.decode(Data("null".utf8)))
        XCTAssertThrowsError(try DesktopNativeConfigurationArchiveCodec.decode(Data("[] trailing".utf8)))
    }

    func testCanonicalRecordDepthTokenKeyAndEncodedSpanLimits_RetainExactEdges() throws {
        let count = DesktopNativeConfigurationField.allCases.count
            * DesktopNativeConfigurationCapture.Platform.allCases.count
        try verify("[" + Array(repeating: "{}", count: count).joined(separator: ",") + "]", expected: .accepted)
        try verify("[" + Array(repeating: "{}", count: count + 1).joined(separator: ",") + "]",
                   expected: .guardFailure(diagnostic))
        try verify(String(repeating: "[", count: 8) + "0" + String(repeating: "]", count: 8), expected: .accepted)
        try verify(String(repeating: "[", count: 9) + "0" + String(repeating: "]", count: 9),
                   expected: .guardFailure(diagnostic))
        for (values, expected) in [(4094, Outcome.accepted), (4095, .guardFailure(diagnostic))] {
            try verify("{\"key\":[" + Array(repeating: "0", count: values).joined(separator: ",") + "]}",
                       expected: expected)
        }
        let keys = (0..<32).map { "\"key\($0)\":null" }.joined(separator: ",")
        try verify("{\(keys)}", expected: .accepted)
        try verify("{\(keys),\"extra\":null}", expected: .guardFailure(diagnostic))
        try verify("{\"\(String(repeating: "k", count: 511))\":null}", expected: .accepted)
        try verify("{\"\(String(repeating: "k", count: 512))\":null}", expected: .guardFailure(diagnostic))
        XCTAssertEqual(DesktopNativeConfigurationArchiveCodec.maximumEncodedBytes,
                       DataMigrationArchivePolicy.maximumJSONBytes)
    }

    func testCancellationBeforeAllocationLongTokensLookaheadAndCompletion_RetainsCadenceAndCause() throws {
        for raw in [#"{"payload":""# + String(repeating: "A", count: 100_000) + #""}"#,
                    "{\"key\"" + String(repeating: " ", count: 100_000) + ":0}"] {
            for cancelAt in [1, 8] {
                var adapterChecks = 0
                XCTAssertThrowsError(try NativeConfigurationJSONScan.validate(Data(raw.utf8), checkCancellation: {
                    adapterChecks += 1
                    if adapterChecks == cancelAt { throw CancellationError() }
                })) { XCTAssertTrue($0 is CancellationError) }
                var referenceChecks = 0
                XCTAssertThrowsError(try reference(Data(raw.utf8), checkCancellation: {
                    referenceChecks += 1
                    if referenceChecks == cancelAt { throw CancellationError() }
                })) { XCTAssertTrue($0 is CancellationError) }
                XCTAssertEqual(adapterChecks, cancelAt)
                XCTAssertEqual(referenceChecks, adapterChecks)
            }
        }
        var adapterChecks = 0
        try NativeConfigurationJSONScan.validate(Data("[]".utf8), checkCancellation: { adapterChecks += 1 })
        var referenceChecks = 0
        try reference(Data("[]".utf8), checkCancellation: { referenceChecks += 1 })
        XCTAssertEqual(adapterChecks, 3)
        XCTAssertEqual(referenceChecks, adapterChecks)
    }
}
