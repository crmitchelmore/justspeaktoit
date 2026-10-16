import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopOwnedEventSnapshotTests: XCTestCase {
    func testHeldNativeDelivery_ExecutesCapturedProfileEffectiveCleanupConsentAndConfiguration() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(owned: true)
        addTeardownBlock { try await fixture.cleanup() }
        let capturedModel = ModelCatalog.defaultFastTextModel
        let laterModel = try XCTUnwrap(DesktopPostProcessing.remoteModels.first { $0.id != capturedModel }).id
        let initial = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("livePolish")), "livePolishModel": AnyCodable(.string("")),
            "postRecordingTailDuration": AnyCodable(.int(0))
        ])
        await fixture.host.autoCleanFixtureSettings(
            configuration: initial, approved: true,
            options: .init(mode: .disabled, modelIdentifier: capturedModel)
        )
        await fixture.host.ownedEventFixtureProfile("Event profile")
        let queue = DesktopSettingsQueue()
        let host = fixture.host!
        let index = fixture.modelIndex
        let event = queue.read { await host.captureRecordingEvent(modelIndex: index, executablePath: "event-app") }
        let captured = await event.value
        let native = OwnedEventGestureFixture(host: host, event: event, index: index)
        addTeardownBlock { await native.unblock() }
        native.hold()
        await native.entered.wait()
        let later = try DesktopConfiguration(values: [
            "speedMode": AnyCodable(.string("instant")), "livePolishModel": AnyCodable(.string(laterModel)),
            "postRecordingTailDuration": AnyCodable(.int(2))
        ])
        await queue.submit {
            await host.ownedEventFixtureProfile("Later profile")
            await host.autoCleanFixtureSettings(
                configuration: later, approved: false,
                options: .init(mode: .disabled, modelIdentifier: laterModel)
            )
        }.value
        XCTAssertTrue(fixture.effects.keyReads.isEmpty, "Capturing an event must not grant or resolve cleanup.")
        await native.adopt()
        let admitted = await host.ownedDictation
        let active = try XCTUnwrap(admitted)
        XCTAssertEqual(active.request.profile, captured.profile)
        XCTAssertEqual(active.request.profile.profileName, "Event profile")
        XCTAssertEqual(active.request.configuration, initial)
        XCTAssertEqual(active.request.tailSeconds, 0)
        XCTAssertEqual(active.request.identity.deviceID, "event-device")
        XCTAssertEqual(active.request.target, "event-field")
        XCTAssertEqual(active.request.live?.livePolish?.modelIdentifier, capturedModel)
        XCTAssertEqual(fixture.effects.keyReads.filter { $0 == "assemblyai.apiKey" }, ["assemblyai.apiKey"])
        XCTAssertEqual(fixture.effects.keyReads.filter { $0 != "assemblyai.apiKey" }, ["openrouter.apiKey"])
        XCTAssertEqual(fixture.effects.keyReads, ["assemblyai.apiKey", "openrouter.apiKey"])
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        await native.finish()
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "authoritative raw")
        XCTAssertEqual(record.livePolishResult?.input, "authoritative raw")
        XCTAssertEqual(record.livePolishResult?.text, "Clean: authoritative raw")
        XCTAssertEqual(record.livePolishResult?.modelIdentifier, capturedModel)
        XCTAssertEqual(fixture.effects.cleanups, [.init(
            text: "authoritative raw", model: capturedModel, key: "cleanup-key-at-start"
        )])
        let terminal = try await host.completedDictationRecord(record.id)
        XCTAssertEqual(terminal.id, record.id)
        let finishes = await active.owner.finishCount
        XCTAssertEqual(finishes, 1)
    }

    func testHeldUnapprovedEvent_LaterApplyCannotAuthorizeRecoveryPreviewOrInsertion() async throws {
        let fixture = AutoCleanHostFixture()
        try await fixture.prepare(owned: true)
        addTeardownBlock { try await fixture.cleanup() }
        let configuration = try await fixture.host.configuration()
        let url = fixture.directory.appendingPathComponent("unapproved-event.json")
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: configuration)).write(to: url)
        try await fixture.host.importConfiguration(path: url.path)
        let host = fixture.host!
        let index = fixture.modelIndex
        let queue = DesktopSettingsQueue()
        let event = queue.read { await host.captureRecordingEvent(modelIndex: index, executablePath: nil) }
        let captured = await event.value
        XCTAssertEqual(captured.profile.livePolish?.approved, false)
        let native = OwnedEventGestureFixture(host: host, event: event, index: index)
        addTeardownBlock { await native.unblock() }
        native.hold()
        await native.entered.wait()
        let entries = try await host.configurationForNativeEditor().entries
        try await host.saveConfiguration(entries, intent: .apply)
        let later = await host.captureProfile(modelIndex: index, executablePath: nil)
        XCTAssertEqual(later.livePolish?.approved, true)
        await native.adopt()
        let admitted = await host.ownedDictation
        let active = try XCTUnwrap(admitted)
        XCTAssertEqual(active.request.profile.livePolish?.approved, false)
        fixture.effects.client.emit("preview recovery")
        if let live = active.request.live { await host.publishLivePreview(live) }
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        await native.finish()
        let record = try await fixture.record()
        XCTAssertEqual(record.originalText, "authoritative raw")
        XCTAssertNil(record.livePolishResult?.text)
        XCTAssertTrue(record.postProcessingFailure?.contains("not authorized") == true)
        XCTAssertEqual(fixture.effects.keyReads.filter { $0 == "assemblyai.apiKey" }, ["assemblyai.apiKey"])
        XCTAssertTrue(fixture.effects.keyReads.filter { $0 != "assemblyai.apiKey" }.isEmpty)
        XCTAssertTrue(fixture.effects.cleanups.isEmpty)
        XCTAssertTrue(fixture.effects.outputs.isEmpty)
        do {
            _ = try await host.completedDictationRecord(record.id)
            XCTFail("Unapproved cleanup must not become an automation success with retained raw text.")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("not authorized"))
        }
    }

    func testRepeatedKeyDown_CannotRetagRecognizedHoldWithLaterEvent() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let host = fixture.host!
        let captured = await host.captureRecordingEvent(modelIndex: fixture.batchIndex, executablePath: nil)
        let native = OwnedEventGestureFixture(
            host: host, event: Task { captured }, index: fixture.batchIndex
        )
        addTeardownBlock { await native.unblock() }
        native.gestures.keyDown(
            target: "original-field", textOutput: Task { FakeTextOutput(label: "original-output") },
            modelIndex: fixture.batchIndex, deviceID: "original-device", event: Task { captured }
        )
        await host.ownedEventFixtureProfile("Repeated key profile")
        let repeated = await host.captureRecordingEvent(modelIndex: fixture.batchIndex, executablePath: nil)
        native.gestures.keyDown(
            target: "repeated-field", textOutput: Task { FakeTextOutput(label: "repeated-output") },
            modelIndex: fixture.batchIndex, deviceID: "repeated-device", event: Task { repeated }
        )
        native.clock.advance(1)
        native.gestures.deadlineReached()
        await native.entered.wait()
        await native.adopt()
        let active = try await fixture.active()
        XCTAssertEqual(active.request.profile, captured.profile)
        XCTAssertEqual(active.request.identity.deviceID, "original-device")
        XCTAssertEqual(active.request.target, "original-field")
        await native.finish()
        XCTAssertEqual(fixture.effects.outputJobs.first?.target, "original-field")
        XCTAssertEqual(fixture.effects.outputJobs.first?.label, captured.textOutput.label)
    }

    func testLegacyEventPath_PreservesAwaitedCaptureWithoutOpeningOwnedWorker() async throws {
        let fixture = OwnedDictationHostFixture()
        try await fixture.prepare(owned: false)
        addTeardownBlock { try await fixture.cleanup() }
        let host = fixture.host!
        let captured = await host.captureRecordingEvent(modelIndex: fixture.batchIndex, executablePath: nil)
        let native = OwnedEventGestureFixture(
            host: host, event: Task { captured }, index: fixture.batchIndex
        )
        addTeardownBlock { await native.unblock() }
        native.hold()
        await native.entered.wait()
        await host.ownedEventFixtureProfile("Later legacy profile")
        await native.adopt()
        let owned = await host.ownedDictation
        let legacy = await host.recording
        XCTAssertNil(owned)
        XCTAssertEqual(legacy?.profile, captured.profile)
        XCTAssertNotNil(fixture.effects.capture)
        await native.finish()
        XCTAssertEqual(fixture.effects.capture?.stopCount, 1)
        XCTAssertEqual(fixture.effects.capture?.destroyCount, 1)
        XCTAssertEqual(fixture.effects.transcriptions.count, 1)
        XCTAssertEqual(fixture.effects.outputJobs.first?.target, "event-field")
        let opens = await fixture.worker.opens
        XCTAssertEqual(opens, 0)
    }
}
