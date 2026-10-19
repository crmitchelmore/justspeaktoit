import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopLegacyEventSnapshotTests: XCTestCase {
    // existing owned test covering held legacy delivery/cleanup/model/consent/output; no behavior change.
    // swiftlint:disable:next function_body_length
    func testHeldLegacyDelivery_ExecutesCapturedCleanupModelConsentAndOutput() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(owned: false)
        addTeardownBlock { try await fixture.cleanup() }
        let host = fixture.host!
        let capturedModel = ModelCatalog.defaultFastTextModel
        let laterModel = try XCTUnwrap(DesktopPostProcessing.remoteModels.first { $0.id != capturedModel }).id
        let initial = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("livePolish")), "livePolishModel": AnyCodable(.string("")),
            "postRecordingTailDuration": AnyCodable(.int(0))
        ])
        await host.autoCleanFixtureSettings(
            configuration: initial, approved: true,
            options: .init(mode: .disabled, modelIdentifier: capturedModel)
        )
        await host.ownedEventFixtureProfile("Captured legacy profile")
        let queue = DesktopSettingsQueue()
        let index = fixture.modelIndex
        let event = queue.read { await host.captureRecordingEvent(modelIndex: index, executablePath: "event-app") }
        let captured = await event.value
        let hints = try await host.recognitionVocabulary()
        let expectedProfile = captured.profile.capturingTranscriptionOptions(
            try XCTUnwrap(captured.profile.transcriptionOptions).includingPronunciationWords(hints.pronunciationWords)
        )
        let native = OwnedEventGestureFixture(host: host, event: event, index: index)
        addTeardownBlock { await native.unblock() }
        native.hold()
        await native.entered.wait()
        let later = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("instant")), "livePolishModel": AnyCodable(.string(laterModel)),
            "postRecordingTailDuration": AnyCodable(.int(2))
        ])
        await queue.submit {
            await host.ownedEventFixtureProfile("Later legacy profile")
            await host.autoCleanFixtureSettings(
                configuration: later, approved: false,
                options: .init(mode: .disabled, modelIdentifier: laterModel)
            )
        }.value
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
        await native.adopt()
        let recording = await host.recording
        let active = try XCTUnwrap(recording)
        XCTAssertEqual(active.profile, expectedProfile)
        XCTAssertEqual(active.profile.transcriptionOptions?.pronunciationKeyterms?.modern, hints.pronunciationWords)
        XCTAssertEqual(active.live?.livePolish?.modelIdentifier, capturedModel)
        XCTAssertEqual(fixture.effects.keyReads.filter { $0 == "assemblyai.apiKey" }, ["assemblyai.apiKey"])
        XCTAssertEqual(fixture.effects.keyReads.filter { $0 != "assemblyai.apiKey" }, ["openrouter.apiKey"])
        XCTAssertEqual(fixture.effects.keyReads, ["assemblyai.apiKey", "openrouter.apiKey"])
        fixture.effects.setKey("later-cleanup-key")
        fixture.effects.client.emit("preview only")
        if let live = active.live { await host.publishLivePreview(live) }
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        await native.finish()
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "authoritative raw")
        XCTAssertEqual(record.livePolishResult?.input, "authoritative raw")
        XCTAssertEqual(record.livePolishResult?.text, "Clean: authoritative raw")
        XCTAssertEqual(record.livePolishResult?.modelIdentifier, capturedModel)
        XCTAssertEqual(record.postProcessingModelIdentifier, capturedModel)
        XCTAssertNil(record.failure)
        XCTAssertNil(record.postProcessingFailure)
        XCTAssertEqual(fixture.effects.cleanups, [.init(
            text: "authoritative raw", model: capturedModel, key: "cleanup-key-at-start"
        )])
        XCTAssertTrue(fixture.effects.postProcesses.isEmpty)
        XCTAssertEqual(fixture.effects.outputs.count, 1)
        XCTAssertEqual(fixture.effects.outputs.first?.1, "Clean: authoritative raw")
        XCTAssertEqual(fixture.effects.outputs.first?.0.target, "event-field")
        XCTAssertEqual(fixture.effects.outputs.first?.0.label, captured.textOutput.label)
        let opens = await fixture.worker.opens
        XCTAssertEqual(opens, 0)
        let policy = await host.recordingCapturePolicy
        XCTAssertNil(policy)
        let bufferStatus = await host.recordingBufferStatus
        XCTAssertFalse(FakeLog.shared.allStatuses.contains(bufferStatus))
    }

    // existing owned test covering denied legacy delivery/later-apply cleanup/preview/insertion; no behavior change.
    // swiftlint:disable:next function_body_length
    func testHeldDeniedLegacyDelivery_LaterApplyCannotAuthorizeCleanupPreviewOrInsertion() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(owned: false)
        addTeardownBlock { try await fixture.cleanup() }
        let host = fixture.host!
        let initial = try await host.configuration()
        let path = fixture.directory.appendingPathComponent("legacy-import.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: initial)).write(to: path)
        try await host.importConfiguration(path: path.path)
        let index = fixture.modelIndex
        let queue = DesktopSettingsQueue()
        let event = queue.read { await host.captureRecordingEvent(modelIndex: index, executablePath: nil) }
        let captured = await event.value
        let hints = try await host.recognitionVocabulary()
        let expectedProfile = captured.profile.capturingTranscriptionOptions(
            try XCTUnwrap(captured.profile.transcriptionOptions).includingPronunciationWords(hints.pronunciationWords)
        )
        XCTAssertEqual(captured.profile.livePolish?.approved, false)
        let native = OwnedEventGestureFixture(host: host, event: event, index: index)
        addTeardownBlock { await native.unblock() }
        native.hold()
        await native.entered.wait()
        let laterModel = try XCTUnwrap(DesktopPostProcessing.remoteModels.first {
            $0.id != ModelCatalog.defaultFastTextModel
        }).id
        let later = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("instant")), "livePolishModel": AnyCodable(.string(laterModel)),
            "postRecordingTailDuration": AnyCodable(.int(2))
        ])
        try await host.saveConfiguration(later.entries, intent: .apply)
        await host.autoCleanFixtureSettings(options: .init(mode: .disabled, modelIdentifier: laterModel))
        await host.ownedEventFixtureProfile("Later instant profile")
        let current = await host.captureProfile(modelIndex: index, executablePath: nil)
        XCTAssertEqual(current.livePolish?.approved, false, "Applying Instant does not authorize Auto-Clean.")
        XCTAssertTrue(fixture.effects.keyReads.isEmpty)
        await native.adopt()
        let recording = await host.recording
        let active = try XCTUnwrap(recording)
        XCTAssertEqual(active.profile, expectedProfile)
        XCTAssertEqual(active.profile.transcriptionOptions?.pronunciationKeyterms?.modern, hints.pronunciationWords)
        XCTAssertEqual(active.profile.livePolish?.approved, false)
        fixture.effects.client.emit("unapproved preview")
        if let live = active.live { await host.publishLivePreview(live) }
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        await native.finish()
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "authoritative raw")
        XCTAssertNil(record.livePolishResult?.text)
        XCTAssertNil(record.processedText)
        XCTAssertTrue(record.postProcessingFailure?.contains("not authorized") == true)
        XCTAssertEqual(fixture.effects.keyReads.filter { $0 == "assemblyai.apiKey" }, ["assemblyai.apiKey"])
        XCTAssertTrue(fixture.effects.keyReads.filter { $0 != "assemblyai.apiKey" }.isEmpty)
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
        XCTAssertTrue(fixture.effects.postProcesses.isEmpty)
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        let opens = await fixture.worker.opens
        XCTAssertEqual(opens, 0)
    }
}
