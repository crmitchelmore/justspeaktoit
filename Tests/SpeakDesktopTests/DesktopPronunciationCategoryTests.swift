import Foundation
import XCTest
import SpeakCore
@testable import SpeakDesktop

final class DesktopPronunciationCategoryTests: XCTestCase {
    func testCanonicalOrderAndCountsComeFromEverySharedCategory() {
        let categories = PronunciationEntry.Category.allCases
        let entries = categories.reversed().flatMap { category in
            (0..<2).map { index in
                PronunciationEntry(word: "Fixture\(index)", pronunciation: "fixture", category: category.rawValue)
            }
        } + [
            PronunciationEntry(word: "Unknown", pronunciation: "unknown", category: "Imported\t%\ncategory"),
            PronunciationEntry(word: "Uncategorized", pronunciation: "uncategorized")
        ]
        let fields = DesktopPronunciationCategories.fields(for: entries)
        XCTAssertEqual(Array(fields.prefix(2)), ["pronunciationCategories.v1", String(entries.count)])
        XCTAssertEqual(Array(fields.dropFirst(2)), categories.flatMap { [$0.rawValue, "2"] })
        XCTAssertFalse(fields.contains("Imported\t%\ncategory"))
    }

    func testEmptyAndRemovedCategoriesAreOmittedWithoutLosingAllCount() {
        let category = PronunciationEntry.Category.allCases[0].rawValue
        let unknown = PronunciationEntry(word: "Unknown", pronunciation: "unknown", category: "Imported")
        XCTAssertEqual(DesktopPronunciationCategories.fields(for: []), ["pronunciationCategories.v1", "0"])
        XCTAssertEqual(
            DesktopPronunciationCategories.fields(for: [
                unknown, .init(word: "Known", pronunciation: "known", category: category)
            ]),
            ["pronunciationCategories.v1", "2", category, "1"]
        )
        XCTAssertEqual(
            DesktopPronunciationCategories.fields(for: [unknown]), ["pronunciationCategories.v1", "1"]
        )
    }

    @VocabularyActor
    func testPresentationExtendsOnlyPronunciationHeaderAndPreservesEveryRow() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let entries = [
            PronunciationEntry(
                word: "Word\t%\n", pronunciation: "Sound\r\n", replacement: "ReplacementOnly",
                category: PronunciationEntry.Category.allCases[0].rawValue
            ),
            PronunciationEntry(word: "Imported", pronunciation: "imported", category: "Unknown\t%\n"),
            PronunciationEntry(word: "Uncategorized", pronunciation: "uncategorized")
        ]
        try await PronunciationStore(directory: directory).save(entries)
        let vocabulary = DesktopVocabulary(directory: directory)
        try await vocabulary.load()
        let lines = vocabulary.presentation(kind: 1, notice: "Notice\t%\n").components(separatedBy: "\n")
        let header = try DesktopVocabularyWire.decode(try XCTUnwrap(lines.first))
        XCTAssertEqual(Array(header.prefix(4)), ["Notice\t%\n", "true", "true", ""])
        XCTAssertEqual(Array(header.dropFirst(4)), DesktopPronunciationCategories.fields(for: entries))
        XCTAssertEqual(lines.count, entries.count + 1)
        for (line, entry) in zip(lines.dropFirst(), entries) {
            XCTAssertEqual(try DesktopVocabularyWire.decode(line), [
                entry.id.uuidString, entry.word, entry.pronunciation, entry.replacement ?? "",
                entry.category ?? "", "false", "false", ""
            ])
        }
        for kind in [0, 3] {
            let first = try XCTUnwrap(vocabulary.presentation(kind: kind).components(separatedBy: "\n").first)
            XCTAssertEqual(try DesktopVocabularyWire.decode(first), ["", "true", "true", ""])
        }
        try await PronunciationStore(directory: directory).save([])
        try await vocabulary.reload()
        XCTAssertEqual(
            try DesktopVocabularyWire.decode(vocabulary.presentation(kind: 1)),
            ["", "true", "true", "", "pronunciationCategories.v1", "0"]
        )
    }
}
