import Foundation
import XCTest
import SpeakCore
import SpeakDesktop
@testable import SpeakDesktopHost

final class DesktopHostConnectionPreWarmingTests: XCTestCase {
    private var directory: URL!
    private var effects: ConnectionWarmEffects!
    private var controller: DesktopHostController<FakePlatform>!

    override func setUp() async throws {
        FakeLog.shared.reset()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        effects = ConnectionWarmEffects()
        controller = try DesktopHostController(
            directory: directory, effects: effects, shutdownGrace: .milliseconds(10)
        )
        await controller.markReadyForSelfTest()
    }

    override func tearDown() async throws {
        for id in 1...3 { await effects.probe.release(id, success: false) }
        await controller.close()
        try FileManager.default.removeItem(at: directory)
    }

    private func entries(approved: Bool, enabled: Bool = true) async throws -> [String] {
        var entries = try await controller.configurationForNativeEditor().entries
        for (key, value) in [
            DesktopConnectionPreWarming.preferenceKey: enabled,
            DesktopConnectionPreWarming.approvalProjectionKey: approved
        ] {
            let index = try XCTUnwrap(DesktopConfiguration.fields.firstIndex { $0.key == key })
            entries[index] = value ? "1" : "0"
        }
        return entries
    }

    private func admit() async throws -> Task<Void, Never> {
        let started = expectation(description: "Synthetic probe admitted")
        await effects.probe.notifyNextStart { started.fulfill() }
        await controller.reconcileConnectionPreWarming()
        await fulfillment(of: [started], timeout: 2)
        let task = await controller.warmTaskForTest()
        return try XCTUnwrap(task)
    }

    func testApply_ExplicitApprovalIsTransientAndNeverStoredInIntent() async throws {
        let unapproved = try await controller.configurationForNativeEditor()
        XCTAssertFalse(unapproved.enabled(DesktopConnectionPreWarming.approvalProjectionKey))
        let approvedEntries = try await entries(approved: true)
        try await controller.saveConfiguration(approvedEntries, intent: .persistOnly)
        let preview = await controller.warmStateForTest()
        XCTAssertFalse(preview.approved)
        try await controller.saveConfiguration(approvedEntries, intent: .apply)
        let applied = await controller.warmStateForTest()
        XCTAssertTrue(applied.approved)
        XCTAssertFalse(applied.witness)
        XCTAssertFalse(applied.owned)
        let editor = try await controller.configurationForNativeEditor()
        let runtime = try await controller.configuration()
        XCTAssertTrue(editor.enabled(DesktopConnectionPreWarming.approvalProjectionKey))
        XCTAssertNil(runtime.values[DesktopConnectionPreWarming.approvalProjectionKey])
        let disk = try JSONDecoder().decode(
            [String: AnyCodable].self, from: Data(contentsOf: directory.appendingPathComponent("settings.json"))
        )
        guard case .object(let stored)? = disk["configuration"]?.storage else {
            return XCTFail("Canonical intent must be persisted.")
        }
        XCTAssertEqual(stored[DesktopConnectionPreWarming.preferenceKey], .bool(true))
        XCTAssertNil(stored[DesktopConnectionPreWarming.approvalProjectionKey])
        XCTAssertNil(disk[DesktopConnectionPreWarming.approvalProjectionKey])
    }

    func testRestart_KeepsIntentButRequiresNewApprovalAndCapture() async throws {
        let edited = try await entries(approved: true)
        try await controller.saveConfiguration(edited)
        await controller.close()
        controller = try DesktopHostController(directory: directory, effects: effects)
        await controller.markReadyForSelfTest()
        let editor = try await controller.configurationForNativeEditor()
        XCTAssertTrue(editor.enabled(DesktopConnectionPreWarming.preferenceKey))
        XCTAssertFalse(editor.enabled(DesktopConnectionPreWarming.approvalProjectionKey))
        let state = await controller.warmStateForTest()
        XCTAssertFalse(state.approved)
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.owned)
    }

    func testImport_RevokesApprovalAndStripsForgedProjectionWhileExportKeepsIntent() async throws {
        try await controller.installWarmContextForTest()
        let file = directory.appendingPathComponent("import.json")
        let preferences = try DesktopConfiguration(values: [
            DesktopConnectionPreWarming.preferenceKey: AnyCodable(.bool(true)),
            DesktopConnectionPreWarming.approvalProjectionKey: AnyCodable(.bool(true)),
            "future": AnyCodable(.string(" retained "))
        ])
        try JSONEncoder().encode(DesktopConfigurationDocument(preferences: preferences)).write(to: file)
        try await controller.importConfiguration(path: file.path)
        let state = await controller.warmStateForTest()
        XCTAssertFalse(state.approved)
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.owned)
        let exported = directory.appendingPathComponent("export.json")
        try await controller.exportConfiguration(path: exported.path)
        let document = try JSONDecoder().decode(
            DesktopConfigurationDocument.self, from: Data(contentsOf: exported)
        )
        XCTAssertEqual(document.preferences.values[DesktopConnectionPreWarming.preferenceKey], AnyCodable(.bool(true)))
        XCTAssertNil(document.preferences.values[DesktopConnectionPreWarming.approvalProjectionKey])
        XCTAssertEqual(document.preferences.values["future"], preferences.values["future"])
    }

    func testFailedAtomicApply_CannotGrantSessionApproval() async throws {
        let before = try await controller.configuration()
        effects.refuseSettings()
        let edited = try await entries(approved: true)
        do {
            try await controller.saveConfiguration(edited)
            XCTFail("Refused write must not grant permission.")
        } catch { XCTAssertEqual((error as NSError).code, CocoaError.fileWriteOutOfSpace.rawValue) }
        let after = try await controller.configuration()
        XCTAssertEqual(after, before)
        let state = await controller.warmStateForTest()
        XCTAssertFalse(state.approved)
        XCTAssertFalse(state.owned)
    }

    func testLegacyRootIntent_IsMigratedButNeverGrantsApproval() throws {
        let key = DesktopConnectionPreWarming.preferenceKey
        let stored: [String: AnyCodable] = [
            "model": AnyCodable(.string(ModelCatalog.defaultBatchTranscriptionModel)),
            key: AnyCodable(.bool(true)),
            DesktopConnectionPreWarming.approvalProjectionKey: AnyCodable(.bool(true))
        ]
        let settings = try JSONDecoder().decode(
            DesktopHostController<FakePlatform>.Settings.self,
            from: JSONEncoder().encode(stored)
        )
        XCTAssertEqual(settings.configuration?.values[key], AnyCodable(.bool(true)))
        let encoded = try JSONDecoder().decode(
            [String: AnyCodable].self, from: JSONEncoder().encode(settings)
        )
        XCTAssertNil(encoded[key])
        XCTAssertNil(encoded[DesktopConnectionPreWarming.approvalProjectionKey])
        XCTAssertNil(settings.configuration?.values[DesktopConnectionPreWarming.approvalProjectionKey])
    }

    func testEnumerationAndReady_AreNotCaptureEvidence() async throws {
        let edited = try await entries(approved: true)
        try await controller.saveConfiguration(edited)
        await controller.setMicrophoneWarning(nil)
        await controller.reconcileConnectionPreWarming()
        let state = await controller.warmStateForTest()
        XCTAssertTrue(state.approved)
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.owned)
        let count = await effects.probe.calls
        XCTAssertEqual(count, 0)
    }

    func testEligibility_RejectsDisabledLocalStreamingAndLiveWithPositiveControl() async throws {
        try await controller.installWarmContextForTest()
        let positive = await controller.warmStateForTest()
        XCTAssertTrue(positive.eligible)
        var streamed = DesktopPostProcessing.Options(mode: .remote)
        streamed.streamingEnabled = true
        for options in [
            DesktopPostProcessing.Options(mode: .disabled),
            .init(mode: .local, modelIdentifier: LocalPostProcessingModel.builtInRulesModelID),
            .init(mode: .localLLM, modelIdentifier: "local/llm/fixture"), streamed
        ] {
            try await controller.installWarmContextForTest(options: options)
            await controller.reconcileConnectionPreWarming()
            let state = await controller.warmStateForTest()
            XCTAssertFalse(state.eligible)
            XCTAssertFalse(state.owned)
        }
        let live = try XCTUnwrap(DesktopHostModels.all.first {
            DesktopLiveTranscription.route(forID: $0.id) != nil
        })
        try await controller.installWarmContextForTest(model: live.id)
        await controller.reconcileConnectionPreWarming()
        let liveState = await controller.warmStateForTest()
        XCTAssertFalse(liveState.eligible)
        XCTAssertFalse(liveState.owned)
    }

    func testEligibility_RejectsDisabledIntentUnapprovedBusyUnreadyAndWarnings() async throws {
        try await controller.installWarmContextForTest(enabled: false)
        await controller.reconcileConnectionPreWarming()
        var state = await controller.warmStateForTest()
        XCTAssertFalse(state.owned)
        try await controller.installWarmContextForTest(approved: false)
        await controller.reconcileConnectionPreWarming()
        state = await controller.warmStateForTest()
        XCTAssertFalse(state.owned)
        try await controller.installWarmContextForTest()
        await controller.warmOperationalBlockForTest(true)
        await controller.reconcileConnectionPreWarming()
        state = await controller.warmStateForTest()
        XCTAssertFalse(state.owned)
        await controller.warmOperationalBlockForTest(false)
        await controller.warmReadinessForTest(false)
        await controller.reconcileConnectionPreWarming()
        state = await controller.warmStateForTest()
        XCTAssertFalse(state.owned)
        await controller.warmReadinessForTest(true)
        await controller.setMicrophoneWarning("Microphone unavailable")
        await controller.reconcileConnectionPreWarming()
        state = await controller.warmStateForTest()
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.owned)
    }

    func testCompletedProbe_FreshnessSurvivesOrdinaryOperationAndCannotDoubleAdmit() async throws {
        try await controller.installWarmContextForTest()
        let task = try await admit()
        await controller.reconcileConnectionPreWarming()
        var count = await effects.probe.calls
        XCTAssertEqual(count, 1)
        await effects.probe.release(1, success: true)
        await task.value
        await controller.warmOperationCycleForTest()
        let state = await controller.warmStateForTest()
        count = await effects.probe.calls
        XCTAssertTrue(state.warm)
        XCTAssertFalse(state.owned)
        XCTAssertEqual(count, 1)
    }

    func testFailure_ClearsWitnessAndDoesNotRetryOnIdle() async throws {
        try await controller.installWarmContextForTest()
        let task = try await admit()
        await effects.probe.release(1, success: false)
        await task.value
        await controller.reconcileConnectionPreWarming()
        let state = await controller.warmStateForTest()
        let count = await effects.probe.calls
        XCTAssertFalse(state.warm)
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.owned)
        XCTAssertEqual(count, 1)
        XCTAssertTrue(FakeLog.shared.allStatuses.contains { $0.contains("no idle retry") })
    }

    func testSameHostABA_RetainsCancelledOwnerUntilRetirementAndRejectsStaleSuccess() async throws {
        try await controller.installWarmContextForTest()
        let old = try await admit()
        await controller.renewWarmWitnessForTest()
        await controller.reconcileConnectionPreWarming()
        var count = await effects.probe.calls
        XCTAssertEqual(count, 1)
        let replacementStarted = expectation(description: "Replacement admitted only after retirement")
        await effects.probe.notifyNextStart { replacementStarted.fulfill() }
        await effects.probe.release(1, success: true)
        await old.value
        await fulfillment(of: [replacementStarted], timeout: 2)
        let replacing = await controller.warmStateForTest()
        count = await effects.probe.calls
        XCTAssertFalse(replacing.warm)
        XCTAssertTrue(replacing.owned)
        XCTAssertEqual(count, 2)
        let replacingTask = await controller.warmTaskForTest()
        let replacement = try XCTUnwrap(replacingTask)
        await effects.probe.release(2, success: true)
        await replacement.value
        let completed = await controller.warmStateForTest()
        XCTAssertTrue(completed.warm)
    }

    func testClose_IsBoundedAndLateProbeCannotMarkWarmOrUpdateUI() async throws {
        try await controller.installWarmContextForTest()
        let task = try await admit()
        let report = await controller.close()
        XCTAssertEqual(report.unfinishedOperations, 1)
        let statuses = FakeLog.shared.allStatuses
        await effects.probe.release(1, success: true)
        await task.value
        let state = await controller.warmStateForTest()
        XCTAssertFalse(state.approved)
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.warm)
        XCTAssertFalse(state.owned)
        XCTAssertEqual(FakeLog.shared.allStatuses, statuses)
    }

    func testDeviceAndConfigurationChanges_ClearAcknowledgedWitness() async throws {
        try await controller.installWarmContextForTest()
        await controller.selectMicrophone("different-device")
        var state = await controller.warmStateForTest()
        XCTAssertFalse(state.witness)
        try await controller.installWarmContextForTest()
        let edited = try await entries(approved: true)
        try await controller.saveConfiguration(edited)
        state = await controller.warmStateForTest()
        XCTAssertTrue(state.approved)
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.owned)
    }

    private func prepareRecording() async throws -> Int {
        let model = ModelCatalog.defaultBatchTranscriptionModel
        let provider = try XCTUnwrap(DesktopHostModels.provider(for: model))
        FakeLog.shared.setKey("synthetic-recording-key", name: provider.apiKeyIdentifier)
        FakeLog.shared.setKey("synthetic-cleanup-key", name: "openrouter.apiKey")
        await controller.savePostProcessing(
            enabled: true, modelIdentifier: ModelCatalog.defaultPostProcessingModel, prompt: "", key: ""
        )
        let edited = try await entries(approved: true)
        try await controller.saveConfiguration(edited)
        return try XCTUnwrap(DesktopHostModels.all.firstIndex { $0.id == model })
    }

    private func toggle(_ index: Int) async {
        await controller.toggle(
            target: "original", modelIndex: index, deviceID: "", targetExecutablePath: nil, textOutput: .init()
        )
    }

    func testActualAcknowledgedCapture_WarmsOnlyAfterCompletedWorkflowReturnsIdle() async throws {
        let index = try await prepareRecording()
        await toggle(index)
        let recording = await controller.warmStateForTest()
        XCTAssertEqual(effects.captureStarts, 1)
        XCTAssertTrue(recording.witness)
        XCTAssertFalse(recording.eligible)
        XCTAssertFalse(recording.owned)
        let started = expectation(description: "Probe after actual synthetic capture workflow")
        await effects.probe.notifyNextStart { started.fulfill() }
        await toggle(index)
        await fulfillment(of: [started], timeout: 2)
        let owned = await controller.warmTaskForTest()
        let task = try XCTUnwrap(owned)
        await effects.probe.release(1, success: true)
        await task.value
        let idle = await controller.warmStateForTest()
        XCTAssertTrue(idle.warm)
    }

    func testFailedCaptureStart_CannotSupplyWitnessOrProbe() async throws {
        let index = try await prepareRecording()
        effects.refuseCapture()
        await toggle(index)
        let state = await controller.warmStateForTest()
        XCTAssertEqual(effects.captureStarts, 1)
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.eligible)
        XCTAssertFalse(state.owned)
    }

    func testBusyAdmission_CancelsButRetainsProbeOwnerWithoutWarming() async throws {
        try await controller.installWarmContextForTest()
        let task = try await admit()
        await controller.warmBeginOperationForTest()
        let retained = await controller.warmStateForTest()
        XCTAssertTrue(retained.owned)
        XCTAssertFalse(retained.eligible)
        await effects.probe.release(1, success: true)
        await task.value
        let retired = await controller.warmStateForTest()
        XCTAssertFalse(retired.warm)
        XCTAssertFalse(retired.owned)
        await controller.invalidateConnectionPreWarming(resetCapture: true)
        await controller.finishBusyOperation()
    }

    func testStaleCaptureAcknowledgement_CannotRestoreInvalidatedWitness() async throws {
        try await controller.installWarmContextForTest()
        await controller.warmStaleAcknowledgementForTest()
        let state = await controller.warmStateForTest()
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.owned)
    }

    func testCleanupCredentialAcknowledgement_RequiresMatchingRecordAndModel() async throws {
        for match in [(false, true), (true, false), (false, false)] {
            try await controller.installWarmContextForTest()
            await controller.warmCredentialAcknowledgementForTest(
                matchesRecord: match.0, matchesModel: match.1, available: true
            )
            await controller.reconcileConnectionPreWarming()
            let state = await controller.warmStateForTest()
            XCTAssertFalse(state.eligible)
            XCTAssertFalse(state.owned)
        }
        try await controller.installWarmContextForTest()
        await controller.warmCredentialAcknowledgementForTest(
            matchesRecord: true, matchesModel: true, available: false
        )
        let empty = await controller.warmStateForTest()
        XCTAssertFalse(empty.eligible)
        await controller.warmCredentialAcknowledgementForTest(
            matchesRecord: true, matchesModel: true, available: true
        )
        let ready = await controller.warmStateForTest()
        XCTAssertTrue(ready.eligible)
    }

    func testCredentialSyncWork_BlocksEvenNewCaptureWitnessUntilRetirement() async throws {
        try await controller.installWarmContextForTest()
        await controller.beginConnectionWarmCredentialWork()
        try await controller.installWarmContextForTest()
        let syncing = await controller.warmStateForTest()
        XCTAssertFalse(syncing.eligible)
        await controller.endConnectionWarmCredentialWork()
        let retired = await controller.warmStateForTest()
        XCTAssertFalse(retired.witness)
        XCTAssertFalse(retired.owned)
    }

    func testUserAbsence_RevokesApprovalWithoutAnArmedHandsFreeSession() async throws {
        try await controller.installWarmContextForTest()
        await controller.handsFreeUserAbsent("synthetic suspend")
        let state = await controller.warmStateForTest()
        XCTAssertFalse(state.approved)
        XCTAssertFalse(state.witness)
        XCTAssertFalse(state.owned)
    }
}
