import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopLegacyCapturePolicyTests: XCTestCase {
    // existing owned test covering held legacy event/silence-stop/zero-tail captured configuration; no behavior change.
    // swiftlint:disable:next function_body_length
    func testHeldLegacyEvent_ActualSilenceStopAndZeroTailUseCapturedConfiguration() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        FakeLog.shared.setKey("transcription-key", name: "assemblyai.apiKey")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-silence-\(UUID())")
        let finishing = expectation(description: "Captured silence policy stopped the real legacy recording")
        let effects = LegacyPolicyEffects { finishing.fulfill() }
        let host = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        addTeardownBlock {
            await effects.client.finishRelease.signal()
            await host.close()
            try FileManager.default.removeItem(at: directory)
        }
        await host.markReadyForSelfTest()
        let model = AssemblyAIModels.universal36ProStreamingID
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model })
        let initial = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("instant")), "postRecordingTailDuration": AnyCodable(.int(0)),
            "silenceDetectionEnabled": AnyCodable(.bool(true)), "silenceThreshold": AnyCodable(.double(0.05)),
            "silenceDuration": AnyCodable(.double(0.5))
        ])
        try await host.saveConfiguration(initial.entries)
        let initialAuthority = await host.settings.configuration
        let expectedInitial = try XCTUnwrap(initialAuthority)
        XCTAssertEqual(expectedInitial.number("postRecordingTailDuration"), 0)
        XCTAssertTrue(expectedInitial.enabled("silenceDetectionEnabled"))
        XCTAssertEqual(expectedInitial.number("silenceThreshold"), 0.05)
        XCTAssertEqual(expectedInitial.number("silenceDuration"), 0.5)
        XCTAssertNil(expectedInitial.values[AppSwitchDelivery.preferenceKey])
        let queue = DesktopSettingsQueue()
        let event = queue.read { await host.captureRecordingEvent(modelIndex: index, executablePath: nil) }
        _ = await event.value
        let native = OwnedEventGestureFixture(host: host, event: event, index: index)
        addTeardownBlock { await native.unblock() }
        native.hold()
        await native.entered.wait()
        let later = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("instant")), "postRecordingTailDuration": AnyCodable(.int(2)),
            "silenceDetectionEnabled": AnyCodable(.bool(false)), "silenceThreshold": AnyCodable(.double(0.2)),
            "silenceDuration": AnyCodable(.double(5))
        ])
        try await host.saveConfiguration(later.entries)
        await native.adopt()
        let recording = await host.recording
        let active = try XCTUnwrap(recording)
        let policy = await host.recordingCapturePolicy
        XCTAssertEqual(policy?.recordID, active.record.id)
        XCTAssertEqual(policy?.value.configuration, expectedInitial)
        let tail = await host.recordingTailSeconds(recordID: active.record.id)
        XCTAssertEqual(tail, 0)
        let staleTail = await host.recordingTailSeconds(recordID: UUID())
        XCTAssertNil(staleTail)
        let rate = DesktopLiveTranscription.route(forID: model)?.sampleRate ?? PCMRecordingFile.sampleRate
        let quiet = [Int16](repeating: 0, count: rate / 10)
        quiet.withUnsafeBufferPointer { active.context.receive($0.baseAddress!, count: $0.count) }
        let finalQuiet = [Int16](repeating: 0, count: rate)
        finalQuiet.withUnsafeBufferPointer { active.context.receive($0.baseAddress!, count: $0.count) }
        await fulfillment(of: [finishing], timeout: 3)
        let remaining = await host.recording
        XCTAssertNil(remaining, "No manual stop was sent; only the captured silence policy can finish capture.")
        let bufferStatus = await host.recordingBufferStatus
        XCTAssertFalse(FakeLog.shared.allStatuses.contains(bufferStatus))
        let cleared = await host.recordingCapturePolicy
        XCTAssertNil(cleared)
        await effects.client.finishRelease.signal()
        await host.legacyEventFixtureAwaitOperations()
        let records = try await host.store.records()
        let record = try XCTUnwrap(records.first)
        XCTAssertEqual(record.originalText, "authoritative raw")
        XCTAssertNil(record.failure)
        XCTAssertTrue(effects.base.cleanups.isEmpty)
        XCTAssertEqual(effects.base.keyReads.filter { $0 == "assemblyai.apiKey" }, ["assemblyai.apiKey"])
        XCTAssertTrue(effects.base.keyReads.filter { $0 != "assemblyai.apiKey" }.isEmpty)
    }

    func testLegacyNilConfigurationEvent_UsesDefaultTailRatherThanLaterConfiguration() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(owned: false)
        addTeardownBlock { try await fixture.cleanup() }
        let host = fixture.host!
        await host.legacyEventFixtureClearConfiguration()
        let event = await host.captureRecordingEvent(modelIndex: fixture.modelIndex, executablePath: nil)
        XCTAssertNil(event.configuration)
        let native = OwnedEventGestureFixture(host: host, event: Task { event }, index: fixture.modelIndex)
        addTeardownBlock { await native.unblock() }
        native.hold()
        await native.entered.wait()
        let later = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("instant")), "postRecordingTailDuration": AnyCodable(.int(2))
        ])
        await host.autoCleanFixtureSettings(configuration: later)
        await native.adopt()
        let recording = await host.recording
        let active = try XCTUnwrap(recording)
        let policy = await host.recordingCapturePolicy
        XCTAssertEqual(policy?.recordID, active.record.id)
        XCTAssertNotNil(policy)
        XCTAssertNil(policy?.value.configuration)
        let tail = await host.recordingTailSeconds(recordID: active.record.id)
        XCTAssertEqual(tail, SpeechDefaults.recordingTailDuration)
        await host.close()
        let retained = await host.recordingCapturePolicy
        XCTAssertNil(retained)
    }

    func testLegacyNoEventCaller_KeepsExistingStopTimeTailLookup() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(owned: false, enabled: false)
        addTeardownBlock { try await fixture.cleanup() }
        await fixture.toggle()
        let host = fixture.host!
        let recording = await host.recording
        let active = try XCTUnwrap(recording)
        let policy = await host.recordingCapturePolicy
        XCTAssertNil(policy)
        let later = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("instant")), "postRecordingTailDuration": AnyCodable(.double(0.01))
        ])
        await host.autoCleanFixtureSettings(configuration: later)
        let tail = await host.recordingTailSeconds(recordID: active.record.id)
        XCTAssertNil(tail, "Only typed events override the established stop-time lookup.")
        await fixture.toggle()
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "authoritative raw")
        let bufferStatus = await host.recordingBufferStatus
        XCTAssertTrue(FakeLog.shared.allStatuses.contains(bufferStatus))
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
        XCTAssertEqual(fixture.effects.keyReads.filter { $0 == "assemblyai.apiKey" }, ["assemblyai.apiKey"])
        XCTAssertTrue(fixture.effects.keyReads.filter { $0 != "assemblyai.apiKey" }.isEmpty)
    }

    // swiftlint:disable:next function_body_length
    func testLegacyStartupFailure_NextRecordingCannotInheritStalePolicyIdentity() async throws {
        FakeLog.shared.reset()
        DesktopHostModels.configure(streamingQualified: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-failure-\(UUID())")
        let effects = TailEffects()
        effects.failStart = true
        let host = try DesktopHostController<FakePlatform>(directory: directory, effects: effects)
        addTeardownBlock {
            await host.close()
            try FileManager.default.removeItem(at: directory)
        }
        await host.markReadyForSelfTest()
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex {
            DesktopTranscription.provider(for: $0.id) != nil
        })
        let model = DesktopHostModels.all[index]
        let provider = try XCTUnwrap(DesktopHostModels.provider(for: model.id))
        FakeLog.shared.setKey("synthetic-key", name: provider.apiKeyIdentifier)
        let initial = try DesktopConfiguration(values: ["postRecordingTailDuration": AnyCodable(.int(0))])
        try await host.saveConfiguration(initial.entries)
        let failed = await host.captureRecordingEvent(modelIndex: index, executablePath: nil)
        await host.toggleCaptured(failed, target: nil, modelIndex: index, deviceID: "synthetic")
        let first = try await host.store.records()
        let failedRecord = try XCTUnwrap(first.first)
        XCTAssertTrue(failedRecord.failure?.contains("Synthetic capture start failed") == true)
        let failedPolicy = await host.recordingCapturePolicy
        let failedCapture = await host.recording
        XCTAssertNil(failedPolicy)
        XCTAssertNil(failedCapture)
        XCTAssertEqual(effects.capture?.destroyCount, 1)
        effects.failStart = false
        let later = try DesktopConfiguration(values: ["postRecordingTailDuration": AnyCodable(.int(2))])
        try await host.saveConfiguration(later.entries)
        let laterAuthority = await host.settings.configuration
        let expectedLater = try XCTUnwrap(laterAuthority)
        XCTAssertEqual(expectedLater.number("postRecordingTailDuration"), 2)
        XCTAssertNil(expectedLater.values[AppSwitchDelivery.preferenceKey])
        XCTAssertNotEqual(expectedLater, failed.configuration)
        let next = await host.captureRecordingEvent(modelIndex: index, executablePath: nil)
        await host.toggleCaptured(next, target: nil, modelIndex: index, deviceID: "synthetic")
        let recording = await host.recording
        let active = try XCTUnwrap(recording)
        XCTAssertNotEqual(active.record.id, failedRecord.id)
        let policy = await host.recordingCapturePolicy
        XCTAssertEqual(policy?.recordID, active.record.id)
        XCTAssertEqual(policy?.value.configuration, expectedLater)
        let stale = await host.recordingTailSeconds(recordID: failedRecord.id)
        let current = await host.recordingTailSeconds(recordID: active.record.id)
        XCTAssertNil(stale)
        XCTAssertEqual(current, 2)
        await host.close()
        let cleared = await host.recordingCapturePolicy
        XCTAssertNil(cleared)
        XCTAssertEqual(effects.capture?.destroyCount, 1)
    }
}
