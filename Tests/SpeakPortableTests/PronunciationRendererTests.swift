import Foundation
import SpeakTestSupport
import XCTest
@testable import SpeakCore

/// The portable renderer must reproduce the Apple dictionary manager's outputs
/// on every platform: the same shared corpus is asserted by the Apple suite.
final class PronunciationRendererTests: XCTestCase {
    private let entries = PronunciationParityFixture.rules.map {
        PronunciationEntry(
            word: $0.word, pronunciation: $0.pronunciation, replacement: $0.replacement,
            isRegex: $0.isRegex, caseSensitive: $0.caseSensitive
        )
    }

    func testSharedCorpus_MatchesTheAppleManagerOutputs() {
        let renderer = PronunciationRenderer()
        // The second pass is served from the expression cache and must agree.
        for pass in 1...2 {
            for sample in PronunciationParityFixture.samples {
                XCTAssertEqual(
                    renderer.applyReplacements(to: sample.input, entries: entries), sample.replaced,
                    "pass \(pass): \(sample.input)"
                )
            }
        }
        XCTAssertGreaterThan(renderer.cachedExpressionCount, 0)
    }

    func testConcurrentRendering_SharesOneCacheWithoutChangingOutput() async {
        let renderer = PronunciationRenderer()
        let entries = entries
        let outputs = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    PronunciationParityFixture.samples.map {
                        renderer.applyReplacements(to: $0.input, entries: entries)
                    }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(outputs.count, 8)
        for output in outputs {
            XCTAssertEqual(output, PronunciationParityFixture.samples.map(\.replaced))
        }
    }

    func testExpressionCache_StaysBoundedAcrossManyDictionaries() {
        let renderer = PronunciationRenderer()
        let entries = (0..<(PronunciationRenderer.maximumCachedExpressions + 88)).map {
            PronunciationEntry(word: "w\($0)", pronunciation: "x", replacement: "r\($0)")
        }
        for _ in 1...2 {
            XCTAssertEqual(renderer.applyReplacements(to: "w1 w599 w5990", entries: entries), "r1 r599 w5990")
            XCTAssertLessThanOrEqual(renderer.cachedExpressionCount, PronunciationRenderer.maximumCachedExpressions)
        }
    }
}
