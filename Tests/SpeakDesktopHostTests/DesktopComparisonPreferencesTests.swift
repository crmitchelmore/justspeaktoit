import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopComparisonPreferencesTests: XCTestCase {
    func testSelectionPersistsPerModeWithoutChangingRoundsOrExports() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopComparisonStore(directory: root)
        try await store.selectModels(["synthetic/file"], replacing: ["synthetic/file", "synthetic/other"])
        try await store.selectModels(["synthetic/live"], replacing: ["synthetic/live"])
        try await store.selectModels([], replacing: ["synthetic/file", "synthetic/other"])
        let relaunched = try DesktopComparisonStore(directory: root)
        let selected = await relaunched.selectedModelIDs()
        XCTAssertEqual(selected, ["synthetic/live"])
        let rounds = await relaunched.rounds()
        XCTAssertTrue(rounds.isEmpty)
        let pending = await relaunched.pendingRevisions()
        XCTAssertTrue(pending.isEmpty)
        do {
            try await relaunched.selectModels(["unavailable"], replacing: ["synthetic/live"])
            XCTFail("Unavailable selection must be rejected.")
        } catch { XCTAssertTrue(error.localizedDescription.contains("not available")) }
        let retained = await relaunched.selectedModelIDs()
        XCTAssertEqual(retained, selected)
    }

    func testFailedSelectionWritePreservesMemoryAndDisk() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DesktopComparisonStore(directory: root) { _, _ in
            throw CocoaError(.fileWriteNoPermission)
        }
        do {
            try await store.selectModels(["synthetic/file"], replacing: ["synthetic/file"])
            XCTFail("Persistence failure must be visible.")
        } catch {}
        let selected = await store.selectedModelIDs()
        XCTAssertTrue(selected.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("rounds.json").path))
    }

    func testWordDiffUsesCanonicalAlignmentAndUpdatesWhenReferenceChanges() async {
        let presentation = DesktopComparisonWordPresentation()
        let id = UUID()
        let first = await presentation.diff(reference: "Hello, bright world.", candidate: "hello world", id: id)
        XCTAssertEqual(first, "hello [-bright] world")
        let changed = await presentation.diff(reference: "hello", candidate: "hello world", id: id)
        XCTAssertEqual(changed, "hello [+world]")
        let empty = await presentation.diff(reference: "", candidate: "", id: id)
        XCTAssertEqual(empty, "")
    }

    func testNativeReferenceEventValidatesRoundMembershipAndDoesNotJudge() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        await controller.openComparison()
        let store = try await controller.loadComparisonStore()
        let entries = [
            ModelComparisonEntry(modelID: "synthetic/a", modelDisplayName: "A", providerDisplayName: "Synthetic"),
            ModelComparisonEntry(modelID: "synthetic/b", modelDisplayName: "B", providerDisplayName: "Synthetic")
        ]
        let round = ModelComparisonRound(
            inputMode: .file, sample: .init(name: "synthetic.wav", contentHash: nil, durationSeconds: 1),
            language: nil, originPlatform: "synthetic", entries: entries, blindOrder: entries.map(\.id)
        )
        try await store.upsert(round)
        let candidate = try XCTUnwrap(DesktopHostModels.visible.first {
            !DesktopHostModels.isLive($0.id) && !DesktopHostModels.isLocal($0.id)
        })
        FakeLog.shared.setKey("synthetic-key", name: try await controller.credentialIdentifier(for: candidate.id))
        await controller.comparisonEvent(125, text: candidate.id, index: 0)
        let selected = await store.selectedModelIDs()
        XCTAssertEqual(selected, [candidate.id])
        await controller.comparisonEvent(125, text: "", index: 0)
        let cleared = await store.selectedModelIDs()
        XCTAssertTrue(cleared.isEmpty)
        await controller.selectComparison(round.id.uuidString)
        await controller.comparisonEvent(124, text: entries[1].id.uuidString, index: 0)
        let reference = await controller.comparisonReference
        XCTAssertEqual(reference, entries[1].id)
        await controller.comparisonEvent(124, text: UUID().uuidString, index: 0)
        let retained = await controller.comparisonReference
        XCTAssertEqual(retained, reference)
        let rounds = await store.rounds()
        XCTAssertNil(rounds.first?.rankings)
        await controller.close()
    }
}
