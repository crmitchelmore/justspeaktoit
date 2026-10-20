import Foundation
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost
import XCTest

@MainActor
final class DesktopOwnedShortcutAdmissionTests: XCTestCase {
    private func activate(_ id: UUID, in fixture: OwnedDictationHostFixture) async throws {
        let wire = try await fixture.host.profileEditorEvent("refresh")
        let header = try XCTUnwrap(wire.components(separatedBy: "\n").first)
        let fields = try DesktopLinuxProfileEditor.fields(header)
        let event = [fields[1], "activate", id.uuidString]
        _ = try await fixture.host.profileEditorEvent(
            event.map(DesktopLinuxProfileEditor.escape).joined(separator: "\t")
        )
    }

    private func keywords(_ value: String, in fixture: OwnedDictationHostFixture) async throws {
        var entries = try await fixture.host.configuration().entries
        let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == "transcriptionKeywords" })
        entries[index] = value
        try await fixture.host.saveConfiguration(entries)
    }

    func testOwnedShortcutRetainsEventProfileAndOptionsAfterManualSelectionChanges() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        let first = DictationProfile(name: "Event profile")
        let second = DictationProfile(name: "Later profile")
        try FileManager.default.createDirectory(at: fixture.directory, withIntermediateDirectories: true)
        try DesktopDictationProfileStore(directory: fixture.directory).save([first, second])
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        try await activate(first.id, in: fixture)
        try await keywords("CapturedTerm", in: fixture)
        let captured = await fixture.host.captureProfile(modelIndex: fixture.batchIndex, executablePath: nil)
        try await activate(second.id, in: fixture)
        try await keywords("ChangedTerm", in: fixture)
        let later = await fixture.host.captureProfile(modelIndex: fixture.batchIndex, executablePath: nil)
        XCTAssertEqual(captured.profileName, first.name)
        XCTAssertNotEqual(captured.transcriptionOptions, later.transcriptionOptions)
        let output = Task { FakeTextOutput(label: "event-output") }
        await fixture.host.admitShortcut(.init(
            input: .gesture(.holdStart), style: .holdToRecord,
            recognisedAt: ProcessInfo.processInfo.systemUptime, target: "event-field",
            textOutput: output, modelIndex: fixture.batchIndex, deviceID: "event-device", profile: captured
        ))
        try await waitForDictation { await fixture.worker.opens == 1 }
        let active = try await fixture.active()
        XCTAssertEqual(active.request.profile, captured)
        XCTAssertNotEqual(active.request.profile.profileName, second.name)
        await fixture.host.admitShortcut(.init(
            input: .gesture(.holdEnd), style: .holdToRecord,
            recognisedAt: ProcessInfo.processInfo.systemUptime, target: "event-field",
            textOutput: output, modelIndex: fixture.batchIndex, deviceID: "event-device"
        ))
        try await waitForDictation { await active.owner.phase == .stopping }
        await opening.release()
        try await waitForDictation { await fixture.host.ownedDictation == nil }
    }

    func testSerializedCapturedCommandCanStopBeforeOwnedMicrophoneReadiness() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let captured = await fixture.host.captureProfile(modelIndex: fixture.batchIndex, executablePath: nil)
        let deliveries = DictationGestureDeliveries()
        let start = Task {
            await fixture.host.admitCaptured(
                target: "event-field", modelIndex: fixture.batchIndex, deviceID: "event-device",
                textOutput: FakeTextOutput(label: "event-output"), profile: captured, trigger: .press
            )
            deliveries.append(.gesture(.holdStart))
        }
        try await waitForDictation { deliveries.inputs.count == 1 }
        try await waitForDictation { await fixture.worker.opens == 1 }
        let active = try await fixture.active()
        XCTAssertEqual(active.request.profile, captured)
        let stop = Task {
            await start.value
            await fixture.host.admitCaptured(
                target: "later-field", modelIndex: fixture.batchIndex, deviceID: "later-device",
                textOutput: FakeTextOutput(label: "later-output"), profile: captured, trigger: .press
            )
            deliveries.append(.gesture(.holdEnd))
        }
        try await waitForDictation { deliveries.inputs.count == 2 }
        try await waitForDictation { await active.owner.phase == .stopping }
        let events = await fixture.worker.events
        XCTAssertFalse(events.contains("ready"))
        await opening.release()
        await stop.value
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        try await assertFailedGestureRecording(
            fixture, owner: active.owner, samples: Array(Int16(1)...Int16(73))
        )
    }

    func testSerializedHoldEndDuringOpen_StopsBeforeReadinessAndRetiresOneRecoveryWAV() async throws {
        let opening = DictationFixtureGate(open: false)
        let retiring = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening, retiring: retiring))
        await fixture.worker.configure(initial: dictationPCM([101, 102]))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let native = OwnedDictationGestureFixture(fixture)
        let index = try XCTUnwrap(DesktopHostModels.all.firstIndex { DesktopHostModels.isLive($0.id) })
        native.hold(index: index)
        try await waitForDictation { await fixture.worker.opens == 1 }
        let active = try await fixture.active()
        let ready = await fixture.host.dictationSessionReady()
        let sessionID = await fixture.host.dictationSessionID
        let canStop = await fixture.host.canStopDictationSession
        let busy = await fixture.host.busy
        XCTAssertFalse(ready)
        XCTAssertTrue(busy)
        XCTAssertTrue(canStop, "Automation uses correlated ownership rather than the legacy !busy stop guard.")
        XCTAssertEqual(sessionID, active.id)
        XCTAssertEqual(fixture.effects.live.frameCount, 0)
        XCTAssertNil(fixture.effects.capture)
        native.release()
        try await waitForDictation { native.deliveries.inputs.count == 2 }
        try await waitForDictation { await active.owner.phase == .stopping }
        XCTAssertEqual(native.deliveries.inputs, [.gesture(.holdStart), .gesture(.holdEnd)])
        let eventsBeforeOpenRelease = await fixture.worker.events
        let finishesBeforeOpenRelease = await active.owner.finishCount
        XCTAssertFalse(eventsBeforeOpenRelease.contains("ready"), "Stop was admitted while native open was held.")
        XCTAssertEqual(finishesBeforeOpenRelease, 0)
        XCTAssertEqual(fixture.effects.live.frameCount, 0)
        await opening.release()
        try await waitForDictation { await fixture.worker.retirements == 1 }
        let prematureFinishes = await active.owner.finishCount
        XCTAssertEqual(prematureFinishes, 0)
        await retiring.release()
        await native.gestures.drain()
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        try await assertFailedGestureRecording(
            fixture, owner: active.owner, samples: [101, 102] + Array(Int16(1)...Int16(73))
        )
    }

    func testSerializedReadyHold_UsesAdmissionSnapshotDespiteLaterSettingsAndCredentials() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let native = OwnedDictationGestureFixture(fixture)
        native.hold()
        try await waitForDictation { await fixture.worker.opens == 1 }
        let active = try await fixture.active()
        try await fixture.host.replaceOwnedFixtureSettings()
        for model in DesktopHostModels.all {
            if let provider = DesktopHostModels.provider(for: model.id) {
                FakeLog.shared.setKey("later-key", name: provider.apiKeyIdentifier)
            }
        }
        await opening.release()
        try await waitForDictation { await fixture.host.dictationSessionReady() }
        native.release()
        await native.gestures.drain()
        try await waitForDictation { fixture.effects.outputCount == 1 }
        let request = try XCTUnwrap(fixture.effects.transcriptions.first)
        XCTAssertEqual(request.key, "at-start-key")
        XCTAssertEqual(request.model, active.request.profile.modelIdentifier)
        XCTAssertEqual(request.language, active.request.profile.language)
        XCTAssertEqual(active.request.identity.deviceID, "event-device")
        XCTAssertEqual(fixture.effects.outputJobs.first?.target, "event-field")
        XCTAssertEqual(fixture.effects.outputJobs.first?.label, "event-output")
        let records = try await fixture.records()
        XCTAssertEqual(records.count, 1)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
    }

    func testSerializedDoubleTapThenSingleTap_StopsOpeningBeforeNativeReady() async throws {
        let opening = DictationFixtureGate(open: false)
        let fixture = OwnedDictationHostFixture(worker: .init(opening: opening))
        try await fixture.prepare()
        addTeardownBlock { try await fixture.cleanup() }
        let native = OwnedDictationGestureFixture(fixture, style: .doubleTapToggle)
        native.tap()
        native.clock.advance(0.1)
        native.tap()
        try await waitForDictation { await fixture.worker.opens == 1 }
        let active = try await fixture.active()
        native.clock.advance(1)
        native.tap()
        native.clock.advance(1)
        native.gestures.deadlineReached()
        try await waitForDictation { native.deliveries.inputs.count == 2 }
        try await waitForDictation { await active.owner.phase == .stopping }
        XCTAssertEqual(native.deliveries.inputs, [.gesture(.doubleTap), .gesture(.singleTap)])
        let ready = await fixture.host.dictationSessionReady()
        XCTAssertFalse(ready)
        await opening.release()
        try await waitForDictation { await fixture.host.ownedDictation == nil }
        let records = try await fixture.records()
        XCTAssertNil(records[0].result)
        XCTAssertTrue(records[0].failure?.contains("before capture was ready") == true)
        let audio = try await fixture.audio(records[0])
        try assertDictationWAV(audio, samples: Array(Int16(1)...Int16(73)))
        XCTAssertEqual(fixture.effects.outputCount, 0)
    }
}
