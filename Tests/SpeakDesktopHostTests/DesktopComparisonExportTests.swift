import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopComparisonExportTests: XCTestCase {
    func testCopyAndSaveSelectedOrAllUseCanonicalDocumentsWithoutMutatingHistoryOrRounds() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.openComparison()
        let store = try await controller.loadComparisonStore()
        try await store.upsert(round("First raw transcript"))
        try await store.upsert(round("Second raw transcript\nUnicode: café"))
        let before = await store.rounds()
        let selected = try XCTUnwrap(before.first)
        let other = try XCTUnwrap(before.last)
        await controller.selectComparison(other.id.uuidString)
        for index: Int32 in [0, 1] {
            for scope in ["", selected.id.uuidString] {
                let rounds = scope.isEmpty ? before : [selected]
                await controller.comparisonEvent(126, text: scope, index: index)
                try assertCanonicalExport(try XCTUnwrap(FakeLog.shared.copies.last), rounds: rounds, index: index)
                let destination = root.appendingPathComponent("export-\(index)-\(scope).txt")
                let event: Int32 = scope.isEmpty ? 107 : 127
                let payload = scope.isEmpty ? destination.path : scope + "\n" + destination.path
                await controller.comparisonEvent(event, text: payload, index: index)
                try assertCanonicalExport(
                    String(contentsOf: destination, encoding: .utf8), rounds: rounds, index: index
                )
            }
        }
        let after = await store.rounds()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(
            try ModelComparisonExport.json(rounds: after, exportedAt: timestamp),
            try ModelComparisonExport.json(rounds: before, exportedAt: timestamp)
        )
        let history = try await controller.store.recoverInterruptedRecordings()
        XCTAssertTrue(history.records.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("settings.json").path))
        await controller.close()
    }

    func testInvalidOrDeletedSelectedExportNeverFallsBackToAllRounds() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.openComparison()
        let store = try await controller.loadComparisonStore()
        try await store.upsert(round("Must not leak through a missing selection"))
        let deleted = round("Deleted selected export")
        try await store.upsert(deleted)
        try await store.remove(id: deleted.id)
        let destination = root.appendingPathComponent("not-written.json")
        for id in ["not-a-uuid", deleted.id.uuidString, ""] {
            await controller.comparisonEvent(127, text: id + "\n" + destination.path, index: 0)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            XCTAssertTrue(FakeLog.shared.allStatuses.last?.hasPrefix("Comparison export failed:") == true)
        }
        await controller.comparisonEvent(126, text: deleted.id.uuidString, index: 1)
        await controller.comparisonEvent(126, text: "", index: 9)
        await controller.comparisonEvent(127, text: "malformed payload", index: 0)
        XCTAssertTrue(FakeLog.shared.copies.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        await controller.close()
    }

    func testEmptyBusyClosedAndFailedWriteExportsReportErrorsWithoutOutput() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.openComparison()
        await controller.comparisonEvent(126, text: "", index: 0)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("no saved comparisons") == true)
        let store = try await controller.loadComparisonStore()
        try await store.upsert(round("Synthetic raw transcript"))
        await controller.testBusyComparisonExport()
        XCTAssertTrue(FakeLog.shared.copies.isEmpty)
        let destination = root.appendingPathComponent("missing-directory/export.json")
        await controller.comparisonEvent(107, text: destination.path, index: 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.hasPrefix("Comparison export failed:") == true)
        await controller.close()
        await controller.comparisonEvent(126, text: "", index: 0)
        XCTAssertTrue(FakeLog.shared.copies.isEmpty)
    }

    func testNullCharacterMarkdownRefusesClipboardTruncationButRemainsSaveable() async throws {
        FakeLog.shared.reset()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.openComparison()
        let store = try await controller.loadComparisonStore()
        let value = round("Raw\0transcript")
        try await store.upsert(value)
        await controller.comparisonEvent(126, text: value.id.uuidString, index: 1)
        XCTAssertTrue(FakeLog.shared.copies.isEmpty)
        XCTAssertTrue(FakeLog.shared.allStatuses.last?.contains("Save it to a file instead") == true)
        await controller.comparisonEvent(126, text: value.id.uuidString, index: 0)
        try assertCanonicalExport(try XCTUnwrap(FakeLog.shared.copies.last), rounds: [value], index: 0)
        let destination = root.appendingPathComponent("retained.md")
        await controller.comparisonEvent(127, text: value.id.uuidString + "\n" + destination.path, index: 1)
        try assertCanonicalExport(String(contentsOf: destination, encoding: .utf8), rounds: [value], index: 1)
        await controller.close()
    }

    private func assertCanonicalExport(_ content: String, rounds: [ModelComparisonRound], index: Int32) throws {
        if index == 0 {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let document = try decoder.decode(ModelComparisonExport.Document.self, from: Data(content.utf8))
            XCTAssertEqual(document.schemaVersion, 1)
            XCTAssertEqual(document.rounds.map(\.id), rounds.map(\.id))
            XCTAssertEqual(
                Data(content.utf8), try ModelComparisonExport.json(rounds: rounds, exportedAt: document.exportedAt)
            )
        } else {
            let line = try XCTUnwrap(content.split(separator: "\n").first { $0.hasPrefix("Exported ") })
            let timestamp = try XCTUnwrap(line.split(separator: " ").dropFirst().first)
            let date = try XCTUnwrap(ISO8601DateFormatter().date(from: String(timestamp.dropLast())))
            XCTAssertEqual(content, ModelComparisonExport.markdown(rounds: rounds, exportedAt: date))
        }
    }

    private func round(_ transcript: String) -> ModelComparisonRound {
        var entry = ModelComparisonEntry(
            modelID: "synthetic/model", modelDisplayName: "Synthetic model", providerDisplayName: "Synthetic"
        )
        entry.transcript = transcript
        return ModelComparisonRound(
            inputMode: .file, sample: .init(name: "synthetic.wav", contentHash: nil, durationSeconds: 1),
            language: nil, originPlatform: "synthetic", entries: [entry], blindOrder: [entry.id]
        )
    }
}

private extension DesktopHostController where Platform == FakePlatform {
    func testBusyComparisonExport() async {
        busy = true
        await comparisonEvent(126, text: "", index: 0)
        busy = false
    }
}
