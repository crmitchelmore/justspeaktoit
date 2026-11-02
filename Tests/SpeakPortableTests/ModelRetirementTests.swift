import XCTest
@testable import SpeakCore

/// Announced shutdowns stay selectable and labelled until their day, then the
/// catalogue hides them and saved selections move to a current successor.
final class ModelRetirementTests: XCTestCase {
    private let transcription = ModelRetirements.all.filter { $0.mode != .speech }
    private let beforeAll = ModelRetirement.utcDate("2026-11-01")!

    private func catalogue(for mode: ModelRetirement.Mode) -> [ModelCatalog.Option] {
        mode == .live ? ModelCatalog.liveTranscription : ModelCatalog.batchTranscription
    }

    private func normalized(_ id: String, mode: ModelRetirement.Mode, at date: Date) -> String {
        mode == .live
            ? ModelCatalog.normalizedLiveTranscriptionModel(id, at: date)
            : ModelCatalog.normalizedBatchTranscriptionModel(id, at: date)
    }

    func testScheduledModels_stayKeptAndLabelledBeforeShutdown() {
        for retirement in transcription {
            let option = catalogue(for: retirement.mode).first { $0.id == retirement.id }
            XCTAssertNotNil(option, retirement.id)
            XCTAssertTrue(option?.description?.contains(retirement.notice) == true, retirement.id)
            XCTAssertEqual(normalized(retirement.id, mode: retirement.mode, at: beforeAll), retirement.id)
            XCTAssertEqual(
                normalized(retirement.id, mode: retirement.mode, at: retirement.shutdownDate.addingTimeInterval(-1)),
                retirement.id
            )
        }
    }

    func testShutDownModels_areHiddenAndMoveToACurrentSuccessorOfTheSameMode() throws {
        for retirement in transcription {
            let day = retirement.shutdownDate
            let successor = try XCTUnwrap(retirement.successorID, retirement.id)
            let current = Set(ModelRetirements.current(catalogue(for: retirement.mode), at: day).map(\.id))

            XCTAssertFalse(current.contains(retirement.id), retirement.id)
            XCTAssertTrue(current.contains(successor), retirement.id)
            XCTAssertNil(ModelRetirements.retirement(for: successor), "successor must not chain: \(successor)")
            XCTAssertEqual(normalized(retirement.id, mode: retirement.mode, at: day), successor)
            XCTAssertEqual(normalized(" \(retirement.id) ", mode: retirement.mode, at: day), successor)
        }
    }

    func testSchedule_doesNotOverlapPermanentMigrations() {
        let ids = ModelRetirements.all.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        XCTAssertTrue(Set(ids).isDisjoint(with: ModelCatalog.batchTranscriptionSuccessors.keys))
        XCTAssertTrue(Set(ids).isDisjoint(with: ModelCatalog.liveTranscriptionSuccessors.keys))
        for retirement in ModelRetirements.all {
            XCTAssertNotEqual(retirement.shutdownDate, .distantFuture, retirement.id)
        }
    }

    func testCustomIdentifiers_areNeverMigratedBySchedule() {
        let far = ModelRetirement.utcDate("2030-01-01")!
        XCTAssertEqual(ModelCatalog.normalizedBatchTranscriptionModel("openai/custom-transcribe", at: far),
                       "openai/custom-transcribe")
        XCTAssertEqual(ModelCatalog.normalizedLiveTranscriptionModel("mistral/custom-streaming", at: far),
                       "mistral/custom-streaming")
    }

    func testDiarizeNotice_warnsThatSpeakerLabelsAreLost() throws {
        let diarize = try XCTUnwrap(ModelRetirements.retirement(for: "openai/gpt-4o-transcribe-diarize"))
        XCTAssertTrue(diarize.notice.contains("no speaker labels"))
    }

    func testOpenAISpeechModels_shareShutdownWithoutSameAPISuccessor() {
        for model in OpenAITTSModel.allCases {
            XCTAssertEqual(model.retirement?.shutdownDay, "2027-01-06", model.rawValue)
            XCTAssertNil(model.retirement?.successorID, model.rawValue)
        }
    }

    func testNotice_usesLocaleIndependentDate() throws {
        let retirement = try XCTUnwrap(ModelRetirements.retirement(for: "openai/whisper-1"))
        XCTAssertTrue(retirement.notice.hasPrefix("Retiring 26 Feb 2027:"))
    }
}
