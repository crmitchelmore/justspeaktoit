import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostVocabularyTests: XCTestCase {
    #if os(Windows) || os(Linux)
    func testVocabularyLoadCompletesWhileNativeMainThreadIsBlocked() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        let task = await MainActor.run {
            let done = DispatchSemaphore(value: 0)
            let load = Task.detached {
                defer { done.signal() }
                return try await controller.vocabularyPresentation(kind: 0)
            }
            // Native loops and their synchronous shutdown waits cannot service MainActor jobs.
            XCTAssertEqual(done.wait(timeout: .now() + 3), .success)
            return load
        }
        let presentation = try await task.value
        XCTAssertFalse(presentation.isEmpty)
        await controller.close()
    }
    #endif

    func testRecordingImportAndRetryKeepProviderTextAndCorrectionSnapshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let effects = SyntheticEffects()
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: false)
        defer { DesktopHostModels.configure(streamingQualified: true) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: effects)
        await controller.markReadyForSelfTest()
        let index = try XCTUnwrap(
            DesktopHostModels.all.firstIndex { DesktopTranscription.provider(for: $0.id) != nil }
        )
        let credential = try XCTUnwrap(
            DesktopHostModels.provider(for: DesktopHostModels.all[index].id)
        ).apiKeyIdentifier
        FakeLog.shared.setKey("fixture-key", name: credential)
        _ = try await controller.vocabularyEvent(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Synthetic", "Canonical", "Synthetic", "automatic", "", "high", ""
        ]))
        _ = try await controller.vocabularyEvent(kind: 0, payload: DesktopVocabularyWire.encode([
            "save", "", "Transcript", "result", "transcript", "manual", "", "low", ""
        ]))
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        await controller.toggle(
            target: nil, modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: FakeTextOutput()
        )
        let store = controller.store
        let records = try await store.records()
        let recording = try XCTUnwrap(records.first)
        XCTAssertEqual(recording.originalText, "Synthetic transcript")
        XCTAssertEqual(recording.correctedText, "Canonical transcript")
        XCTAssertEqual(recording.lexiconSummary?.applied.count, 1)
        XCTAssertEqual(recording.lexiconSummary?.suggestions.count, 1)
        let audio = try await store.audioURL(for: recording)
        await controller.importAudio(path: audio.path, modelIndex: index)
        let imported = try await store.records()
        XCTAssertEqual(imported.count, 2)
        XCTAssertTrue(imported.allSatisfy { $0.correctedText == "Canonical transcript" })
        await controller.retryHistory(recording.id.uuidString)
        let retried = try await store.record(id: recording.id)
        XCTAssertEqual(retried.originalText, "Synthetic transcript")
        XCTAssertEqual(retried.lexiconSummary?.applied.count, 1)
        XCTAssertEqual(
            retried.lexiconSummary?.suggestions.count, 1, "Retry must replace, not append correction records"
        )
        try await assertCorrectionPresentation(controller, recording: recording)
        await controller.close()
    }

    private func assertCorrectionPresentation(
        _ controller: DesktopHostController<FakePlatform>, recording: DesktopRecordingStore.Record
    ) async throws {
        XCTAssertTrue(recording.hasTranscriptVariants)
        XCTAssertEqual(recording.text(for: .original), "Synthetic transcript")
        XCTAssertEqual(recording.text(for: .processed), "Canonical transcript")
        let details = try await controller.vocabularyHistoryPresentation(recording.id.uuidString)
        XCTAssertTrue(details.contains("Synthetic -> Canonical"))
        XCTAssertTrue(details.contains("transcript -> result"))
        XCTAssertTrue(details.contains("Rule requires manual confirmation"))
        await controller.searchHistory("a synthetic query matching no recording")
        do {
            _ = try await controller.vocabularyHistoryPresentation(recording.id.uuidString)
            XCTFail("Hidden or stale selection must not open correction results")
        } catch {}
    }

    func testEmptyProviderResultDoesNotBecomeVocabularyText() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let controller = try DesktopHostController<FakePlatform>(directory: root, effects: SyntheticEffects())
        var record = DesktopRecordingStore.Record(id: UUID(), audioFilename: "fixture.wav", modelIdentifier: "fixture")
        record.result = TranscriptionResult(
            text: "   ", segments: [], confidence: nil, duration: 0, modelIdentifier: "fixture",
            cost: nil, rawPayload: nil, debugInfo: nil
        )
        let corrected = try await controller.applyVocabulary(record)
        XCTAssertEqual(corrected.originalText, "   ")
        XCTAssertEqual(corrected.correctedText, "")
        XCTAssertEqual(corrected.lexiconSummary?.applied.count, 0)
        await controller.close()
    }
}
