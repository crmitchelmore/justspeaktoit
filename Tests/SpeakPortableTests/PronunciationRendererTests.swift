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

    /// 700 expressions, past any small fixed cache: 600 case-insensitive words
    /// and 100 regular expressions, in stable dictionary order.
    private static func largeDictionary(prefix: String = "w", count: Int = 600) -> [PronunciationEntry] {
        (0..<count).map { PronunciationEntry(word: "\(prefix)\($0)", pronunciation: "x", replacement: "r\($0)") }
            + (0..<100).map {
                PronunciationEntry(
                    word: "\\bz\($0)_(\\d+)\\b", pronunciation: "x", replacement: "y\($0)-$1", isRegex: true
                )
            }
    }

    func testLargeDictionary_CompilesEachExpressionOnceAndStaysWarm() {
        let dictionary = Self.largeDictionary()
        for retention in [PronunciationRenderer.Retention.unbounded, .activeDictionary] {
            let renderer = PronunciationRenderer(retention: retention)
            let text = "w1 then w599 and z42_7, not w5990"
            let expected = "r1 then r599 and y42-7, not w5990"
            XCTAssertEqual(renderer.applyReplacements(to: text, entries: dictionary), expected)
            XCTAssertEqual(renderer.compilationCount, 700, "\(retention)")
            for _ in 0..<5 {
                XCTAssertEqual(renderer.applyReplacements(to: text, entries: dictionary), expected)
            }
            XCTAssertEqual(renderer.compilationCount, 700, "A warm pass recompiled with \(retention)")
            XCTAssertEqual(renderer.cachedExpressionCount, 700, "\(retention)")
        }
    }

    func testActiveDictionaryRetention_KeepsOnlyTheLatestDictionaryWarm() {
        let renderer = PronunciationRenderer(retention: .activeDictionary)
        let large = Self.largeDictionary(), small = Self.largeDictionary(prefix: "s", count: 50)
        _ = renderer.applyReplacements(to: "w1", entries: large)
        XCTAssertEqual(renderer.cachedExpressionCount, 700)
        _ = renderer.applyReplacements(to: "s1", entries: small)
        // The regular expressions are shared; the 600 words are dropped.
        XCTAssertEqual(renderer.cachedExpressionCount, 150)
        XCTAssertEqual(renderer.compilationCount, 750)
        for _ in 0..<3 { _ = renderer.applyReplacements(to: "s1", entries: small) }
        XCTAssertEqual(renderer.compilationCount, 750, "A warm pass recompiled")

        // The manager's lifetime retention keeps every dictionary it has seen.
        let unbounded = PronunciationRenderer(retention: .unbounded)
        for entries in [large, small, large] { _ = unbounded.applyReplacements(to: "w1", entries: entries) }
        XCTAssertEqual(unbounded.compilationCount, 750)
        XCTAssertEqual(unbounded.cachedExpressionCount, 750)
    }
}
