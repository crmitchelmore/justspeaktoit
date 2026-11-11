import XCTest
@testable import SpeakCore

/// Announced shutdowns stay selectable and labelled until their day, then the
/// catalogue hides them. Saved selections move only to a verified equivalent;
/// otherwise requests fail with an actionable error until the user chooses.
final class ModelRetirementTests: XCTestCase {
    private let transcription = ModelRetirements.all.filter { $0.mode == .batch || $0.mode == .live }
    private let cleanup = ModelRetirements.all.filter { $0.mode == .postProcessing }
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

    func testShutDownModels_areHiddenAndMoveOnlyToAVerifiedEquivalent() {
        for retirement in transcription {
            let day = retirement.shutdownDate
            let current = Set(ModelRetirements.current(catalogue(for: retirement.mode), at: day).map(\.id))
            XCTAssertFalse(current.contains(retirement.id), retirement.id)
            guard let successor = retirement.successorID else { continue }
            XCTAssertTrue(current.contains(successor), retirement.id)
            XCTAssertNil(ModelRetirements.retirement(for: successor), "successor must not chain: \(successor)")
            XCTAssertEqual(normalized(retirement.id, mode: retirement.mode, at: day), successor)
            XCTAssertEqual(normalized(" \(retirement.id) ", mode: retirement.mode, at: day), successor)
            XCTAssertNoThrow(try ModelRetirements.ensureAvailable(successor, at: day))
        }
    }

    func testAutomaticMigrations_areExactlyTheVerifiedEquivalents() {
        let automatic = Dictionary(uniqueKeysWithValues: transcription.compactMap { retirement in
            retirement.successorID.map { (retirement.id, $0) }
        })
        XCTAssertEqual(automatic, [
            "openai/gpt-4o-transcribe": "openai/gpt-transcribe",
            "openai/gpt-4o-mini-transcribe": "openai/gpt-transcribe",
            "openai/gpt-4o-transcribe-streaming": "openai/gpt-live-transcribe-streaming",
            "openai/gpt-4o-mini-transcribe-streaming": "openai/gpt-live-transcribe-streaming"
        ])
    }

    /// Speaker labels, segment timestamps and Stable guarantees are kept as
    /// the user's saved intent: the selection survives, requests fail with an
    /// actionable error, and nothing silently switches model.
    func testLossyRetirements_keepSelectionAndFailWithActionableError() throws {
        for id in [
            "openai/whisper-1", "openai/gpt-4o-transcribe-diarize", "openai/gpt-audio",
            "mistral/voxtral-mini-latest", MistralVoxtralRealtime.liveCatalogID
        ] {
            let retirement = try XCTUnwrap(ModelRetirements.retirement(for: id))
            let day = retirement.shutdownDate
            XCTAssertNil(retirement.successorID, id)
            if let recommended = retirement.recommendedID {
                XCTAssertTrue(catalogue(for: retirement.mode).contains { $0.id == recommended },
                              "recommendation must be a real catalogue entry: \(id)")
            }
            XCTAssertEqual(normalized(id, mode: retirement.mode, at: day), id)
            XCTAssertNoThrow(try ModelRetirements.ensureAvailable(id, at: day.addingTimeInterval(-1)))
            XCTAssertThrowsError(try ModelRetirements.ensureAvailable(id, at: day)) { error in
                XCTAssertEqual(error as? ModelRetiredError, ModelRetiredError(retirement: retirement))
                XCTAssertTrue(error.localizedDescription.contains("Choose another model in Settings"), id)
            }
        }
    }

    func testCleanupRetirements_moveSavedAndInFlightSelectionsOnTheirDay() throws {
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: cleanup.map { ($0.id, $0.successorID) }), [
            "openai/gpt-5-mini": "openai/gpt-5.6-luna",
            "openai/gpt-5.4-nano": "openai/gpt-6-luna"
        ])
        for retirement in cleanup {
            let day = retirement.shutdownDate
            let successor = try XCTUnwrap(retirement.successorID)
            let before = ModelRetirements.current(ModelCatalog.postProcessing, at: beforeAll)
            XCTAssertTrue(before.first { $0.id == retirement.id }?.description?.contains(retirement.notice) == true)
            XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(retirement.id, at: beforeAll), retirement.id)
            let after = Set(ModelRetirements.current(ModelCatalog.postProcessing, at: day).map(\.id))
            XCTAssertFalse(after.contains(retirement.id), retirement.id)
            XCTAssertTrue(after.contains(successor), retirement.id)
            XCTAssertNil(ModelRetirements.retirement(for: successor), "successor must not chain: \(successor)")
            XCTAssertEqual(ModelCatalog.normalizedPostProcessingModel(retirement.id, at: day), successor)
            XCTAssertNil(ModelRetirements.successor(for: retirement.id, mode: .batch, at: day))
        }
        XCTAssertNil(ModelRetirements.retirement(for: ModelCatalog.defaultPostProcessingModel))
    }

    func testDiarizeRetirement_pointsAtSpeakerLabellingModels() throws {
        let diarize = try XCTUnwrap(ModelRetirements.retirement(for: "openai/gpt-4o-transcribe-diarize"))
        XCTAssertTrue(diarize.notice.contains("Choose Scribe v2, Soniox or Gemini 3.5 Transcribe"))
        XCTAssertNil(diarize.recommendedID, "No single replacement keeps OpenAI speaker labels")
    }

    func testBatchClients_refuseRetiredModelWithoutCallingTheProvider() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("retired-\(UUID()).wav")
        try Data([0]).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let after = ModelRetirement.utcDate("2027-05-01")!
        let openAI = OpenAIBatchClient(session: .shared, keywords: [], now: { after })
        do {
            _ = try await openAI.transcribeFile(at: audio, apiKey: "k", model: "openai/whisper-1", language: nil)
            XCTFail("Expected ModelRetiredError")
        } catch { XCTAssertTrue(error is ModelRetiredError, "\(error)") }
        let neverStaged = SharedMultipartUploadStaging(
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            securityPolicy: .init(
                prepareDirectory: { _, _ in XCTFail("Retired model reached upload staging") },
                createFile: { _, _ in XCTFail("Retired model reached upload staging"); return false }
            ))
        let mistral = MistralBatchClient(multipartStaging: neverStaged, keywords: [], now: { after })
        do {
            _ = try await mistral.transcribeFile(
                at: audio, apiKey: "k", model: "mistral/voxtral-mini-latest", language: nil)
            XCTFail("Expected ModelRetiredError")
        } catch { XCTAssertTrue(error is ModelRetiredError, "\(error)") }
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

    func testOpenAISpeechModels_shareShutdownWithoutSameAPISuccessor() {
        for model in OpenAITTSModel.allCases {
            XCTAssertEqual(model.retirement?.shutdownDay, "2027-01-06", model.rawValue)
            XCTAssertNil(model.retirement?.successorID, model.rawValue)
            XCTAssertEqual(model.retirement?.recommendedID, OpenAIRealtimeSpeech.catalogID, model.rawValue)
        }
    }

    func testSpeechRequests_refuseShutDownModelBeforeBuildingARequest() throws {
        let before = ModelRetirement.utcDate("2027-01-05")!, after = ModelRetirement.utcDate("2027-01-06")!
        for model in OpenAITTSModel.allCases {
            let request = OpenAITTSRequest(model: model, voiceID: "openai/alloy", speed: 1, format: .wav)
            XCTAssertNoThrow(try OpenAITTSAPI.validate(text: "Hi", request: request, at: before))
            XCTAssertThrowsError(try OpenAITTSAPI.validate(text: "Hi", request: request, at: after)) {
                XCTAssertTrue($0 is ModelRetiredError, "\($0)")
            }
        }
    }

    func testNotice_usesLocaleIndependentDate() throws {
        let retirement = try XCTUnwrap(ModelRetirements.retirement(for: "openai/whisper-1"))
        XCTAssertTrue(retirement.notice.hasPrefix("Retiring 26 Feb 2027:"))
    }
}
