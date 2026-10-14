import Foundation
import SpeakCore
import XCTest
@testable import SpeakDesktop

@VocabularyActor
final class DesktopVocabularyCandidateTests: XCTestCase {
    func testStoredCandidateActionsPersistWithoutObservingOrFabricatingEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let stored = [
            AutoCorrectionCandidate(original: "Susie", corrected: "Susy", seenCount: 2, sourceApps: ["Synthetic"]),
            AutoCorrectionCandidate(original: "Alfa", corrected: "Alpha", seenCount: 4),
            AutoCorrectionCandidate(original: "Jonn", corrected: "John", seenCount: 2)
        ]
        try await AutoCorrectionStore(appDirectory: root).save(stored)
        let vocabulary = DesktopVocabulary(directory: root)
        try await vocabulary.load()
        XCTAssertTrue(vocabulary.presentation(kind: 3).contains("Synthetic"))
        _ = try await vocabulary.perform(
            kind: 3, payload: DesktopVocabularyWire.encode(["promote", stored[0].id.uuidString])
        )
        XCTAssertEqual(vocabulary.lexicon.rules.first?.canonical, "Susy")
        XCTAssertEqual(vocabulary.candidates.candidates.count, 2)
        _ = try await vocabulary.perform(
            kind: 3, payload: DesktopVocabularyWire.encode(["dismiss", stored[1].id.uuidString])
        )
        XCTAssertTrue(vocabulary.candidates.candidates.first?.dismissed == true)
        _ = try await vocabulary.perform(
            kind: 3, payload: DesktopVocabularyWire.encode(["remove", stored[2].id.uuidString])
        )
        let reloaded = DesktopVocabulary(directory: root)
        try await reloaded.load()
        XCTAssertTrue(reloaded.candidates.candidates.isEmpty)
        XCTAssertEqual(reloaded.lexicon.rules.first?.canonical, "Susy")
        do {
            _ = try await vocabulary.perform(
                kind: 3, payload: DesktopVocabularyWire.encode(["promote", UUID().uuidString])
            )
            XCTFail("A stale native candidate selection must fail explicitly")
        } catch {
            XCTAssertEqual(error as? DesktopVocabularyError, .unknownEntry)
        }
        _ = try await vocabulary.perform(kind: 3, payload: "clear")
        XCTAssertTrue(vocabulary.candidates.candidates.isEmpty)
        XCTAssertEqual(vocabulary.lexicon.rules.first?.canonical, "Susy")
    }

    func testNativeClearFailureRetainsCandidatesAndCanRetryAfterStorageRepair() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let candidate = AutoCorrectionCandidate(original: "Susie", corrected: "Susy", seenCount: 2)
        try await AutoCorrectionStore(appDirectory: root).save([candidate])
        let vocabulary = DesktopVocabulary(directory: root)
        try await vocabulary.load()
        let folder = root.appendingPathComponent("AutoCorrections")
        let backup = root.appendingPathComponent("Synthetic-backup")
        try FileManager.default.moveItem(at: folder, to: backup)
        try Data("synthetic obstruction".utf8).write(to: folder)
        do {
            _ = try await vocabulary.perform(kind: 3, payload: "clear")
            XCTFail("Native clear must surface persistence failure")
        } catch {
            XCTAssertFalse(error is DesktopVocabularyError)
        }
        XCTAssertEqual(vocabulary.candidates.candidates.map(\.id), [candidate.id])
        XCTAssertTrue(vocabulary.lexicon.rules.isEmpty)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: backup, to: folder)
        _ = try await vocabulary.perform(kind: 3, payload: "clear")
        XCTAssertTrue(vocabulary.candidates.candidates.isEmpty)
        let persisted = try await AutoCorrectionStore(appDirectory: root).load()
        XCTAssertTrue(persisted.isEmpty)
    }
}
