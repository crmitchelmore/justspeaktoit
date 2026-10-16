import Foundation
import SpeakCore
import SpeakDesktop
import XCTest
@testable import SpeakDesktopHost

final class DesktopHostCorrectionLearningTests: XCTestCase {
    func testActualOutput_RequiresLocalApprovalThenLearnsAndPromotesAtTwo() async throws {
        let fixture = try LearningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.host.learningOutputAndWait()
        XCTAssertEqual(fixture.readback.begins, 0)
        _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowLearning")
        await fixture.host.learningOutputAndWait()
        var state = try await fixture.host.learningState()
        XCTAssertEqual(state.candidates.count, 1)
        XCTAssertEqual(state.candidates.first?.sourceApps, ["Synthetic"])
        await fixture.host.learningOutputAndWait()
        state = try await fixture.host.learningState()
        XCTAssertTrue(state.candidates.isEmpty)
        XCTAssertEqual(state.rules, 1)
        await fixture.host.close()
    }

    func testImportTrueAndUnknownApprovalMirror_DoNotGrantApprovalOrReadText() async throws {
        let fixture = try LearningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let imported = fixture.root.appendingPathComponent("import.json")
        let preferences = try DesktopConfiguration(values: [
            ApplicationPreferenceKey.autoCorrectionsEnabled.rawValue: AnyCodable(.bool(true)),
            ApplicationPreferenceKey.autoCorrectionsPromotionThreshold.rawValue: AnyCodable(.int(10)),
            "correctionLearningApproved": AnyCodable(.bool(true))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: imported)
        try await fixture.host.importConfiguration(path: imported.path)
        await fixture.host.learningOutputAndWait()
        let state = try await fixture.host.learningState()
        XCTAssertFalse(state.approved)
        XCTAssertEqual(fixture.readback.begins, 0)
        let retained = try await fixture.host.configuration()
        XCTAssertEqual(retained.number(ApplicationPreferenceKey.autoCorrectionsPromotionThreshold.rawValue), 10)
        await fixture.host.close()
    }

    func testDisabledLearning_RevokesApprovalButKeepsManualCandidatePromotion() async throws {
        let fixture = try LearningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowLearning")
        await fixture.host.learningOutputAndWait()
        let before = try await fixture.host.learningState()
        let candidate = try XCTUnwrap(before.candidates.first)
        var entries = try await fixture.host.configuration().entries
        let enabled = try XCTUnwrap(DesktopConfiguration.fields.firstIndex {
            $0.key == ApplicationPreferenceKey.autoCorrectionsEnabled.rawValue
        })
        entries[enabled] = "0"
        try await fixture.host.saveConfiguration(entries)
        await fixture.host.learningOutputAndWait()
        let disabled = try await fixture.host.learningState()
        XCTAssertFalse(disabled.approved)
        XCTAssertEqual(fixture.readback.begins, 1)
        _ = try await fixture.host.vocabularyEvent(
            kind: 3, payload: DesktopVocabularyWire.encode(["promote", candidate.id.uuidString])
        )
        let after = try await fixture.host.learningState()
        XCTAssertTrue(after.candidates.isEmpty)
        XCTAssertEqual(after.rules, 1)
        await fixture.host.close()
    }

    func testUnconfirmedClipboardAndFailure_AreExplicitlySkipped() async throws {
        let fixture = try LearningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowLearning")
        for disposition in [
            DesktopTextOutputResult.Disposition.unconfirmedInsertion, .failed, .cancelled, .copied
        ] {
            await fixture.host.learningAdmission(disposition: disposition, clipboard: false)
        }
        await fixture.host.learningAdmission(disposition: .confirmedInsertion, clipboard: true)
        let state = try await fixture.host.learningState()
        XCTAssertEqual(fixture.readback.begins, 0)
        XCTAssertTrue(state.status.contains("no owned text span"))
        await fixture.host.close()
    }

    func testCancelOutput_FencesHeldObservation() async throws {
        let fixture = try LearningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowLearning")
        let entered = expectation(description: "observation waiting")
        let owned = await fixture.host.learningStartWaiting(entered)
        let pending = try XCTUnwrap(owned)
        await fulfillment(of: [entered], timeout: 3)
        await fixture.host.cancelOutput()
        await pending.value
        let state = try await fixture.host.learningState()
        XCTAssertTrue(state.candidates.isEmpty)
        XCTAssertEqual(fixture.readback.reads, 0)
        await fixture.host.close()
        XCTAssertGreaterThan(fixture.readback.cancels, 0)
    }

    func testActualClose_FencesHeldObservationBeforeReturning() async throws {
        let fixture = try LearningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.host.learningState()
        _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowLearning")
        let entered = expectation(description: "observation waiting during close")
        let owned = await fixture.host.learningStartWaiting(entered)
        let pending = try XCTUnwrap(owned)
        await fulfillment(of: [entered], timeout: 3)
        await fixture.host.close()
        await pending.value
        let state = try await fixture.host.learningState()
        XCTAssertTrue(state.candidates.isEmpty)
        XCTAssertEqual(state.rules, 0)
        XCTAssertEqual(fixture.readback.reads, 0)
        XCTAssertGreaterThan(fixture.readback.cancels, 0)
    }

    func testActualReplacementOutput_FencesHeldOldObservationAndCompletesNewOutput() async throws {
        let fixture = try LearningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowLearning")
        let entered = expectation(description: "old observation waiting during replacement")
        let owned = await fixture.host.learningStartWaiting(entered)
        let pending = try XCTUnwrap(owned)
        await fulfillment(of: [entered], timeout: 3)
        let replacement = HostLearningReadback()
        FakeLog.shared.installCorrectionReadback(replacement)
        await fixture.host.learningReplacementAndWait()
        await pending.value
        let state = try await fixture.host.learningState()
        XCTAssertTrue(state.candidates.isEmpty)
        XCTAssertEqual(state.rules, 0)
        XCTAssertEqual(fixture.readback.reads, 0)
        XCTAssertGreaterThan(fixture.readback.cancels, 0)
        XCTAssertEqual(replacement.begins, 1)
        XCTAssertEqual(replacement.reads, 1)
        await fixture.host.close()
    }

    func testNewRecordingAdmission_CancelsAnExistingObservationBeforeCapture() async throws {
        let fixture = try LearningFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        await fixture.host.markReadyForSelfTest()
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            DesktopTranscription.provider(for: $0.id) != nil
        })
        let provider = try XCTUnwrap(DesktopHostModels.provider(for: DesktopHostModels.all[index].id))
        FakeLog.shared.setKey("synthetic-key", name: provider.apiKeyIdentifier)
        _ = try await fixture.host.vocabularyEvent(kind: 3, payload: "allowLearning")
        let entered = expectation(description: "observation waiting")
        let pending = await fixture.host.learningStartWaiting(entered)
        await fulfillment(of: [entered], timeout: 3)
        await fixture.host.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        await pending?.value
        XCTAssertEqual(fixture.readback.reads, 0)
        let state = try await fixture.host.learningState()
        XCTAssertTrue(state.candidates.isEmpty)
        await fixture.host.close()
    }
}

private struct LearningFixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let readback = HostLearningReadback()
    let host: DesktopHostController<FakePlatform>
    init() throws {
        FakeLog.shared.reset()
        FakeLog.shared.installCorrectionReadback(readback)
        host = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
    }
}

private final class HostLearningReadback: DesktopCorrectionReadback, @unchecked Sendable {
    let application: String? = "Synthetic"
    private let lock = NSLock()
    private var beginCount = 0
    private var readCount = 0
    private var cancelCount = 0
    var begins: Int { lock.withLock { beginCount } }
    var reads: Int { lock.withLock { readCount } }
    var cancels: Int { lock.withLock { cancelCount } }
    func begin(original: String) throws { lock.withLock { beginCount += 1 } }
    func read() throws -> String { lock.withLock { readCount += 1 }; return "Susy" }
    func cancel() { lock.withLock { cancelCount += 1 } }
}

private struct LearningState: Sendable {
    let approved: Bool
    let status: String
    let candidates: [AutoCorrectionCandidate]
    let rules: Int
}

private extension DesktopHostController where Platform == FakePlatform {
    func learningStartWaiting(_ entered: XCTestExpectation) async -> Task<Void, Never>? {
        correctionObservationWait = { _ in
            entered.fulfill()
            try await Task.sleep(for: .seconds(60))
        }
        _ = beginOutput("Susie", output: .init(options: FakeTextOutput(), target: "synthetic"), recordID: UUID())
        await outputSlot.task?.value
        return correctionObservationTask
    }

    func learningOutputAndWait() async {
        correctionObservationWait = { _ in }
        _ = beginOutput("Susie", output: .init(options: FakeTextOutput(), target: "synthetic"), recordID: UUID())
        await outputSlot.task?.value
        await correctionObservationTask?.value
    }

    func learningAdmission(disposition: DesktopTextOutputResult.Disposition, clipboard: Bool) async {
        correctionObservationWait = { _ in }
        cancelCorrectionObservation()
        beginCorrectionObservation(
            job: FakeJob(label: "Synthetic", target: clipboard ? nil : "synthetic"),
            text: "Susie", recordID: UUID(), revision: correctionLearningRevision,
            completion: .init(disposition, status: "Synthetic output")
        )
        await correctionObservationTask?.value
    }

    func learningReplacementAndWait() async {
        correctionObservationWait = { _ in }
        _ = beginOutput("Susy", output: .init(options: FakeTextOutput(), target: "replacement"), recordID: UUID())
        await outputSlot.task?.value
        await correctionObservationTask?.value
    }

    func learningState() async throws -> LearningState {
        let vocabulary = try await vocabularyStore()
        return LearningState(
            approved: correctionLearningApproved, status: correctionLearningStatus(),
            candidates: await vocabulary.candidates.candidates, rules: await vocabulary.lexicon.rules.count
        )
    }
}
