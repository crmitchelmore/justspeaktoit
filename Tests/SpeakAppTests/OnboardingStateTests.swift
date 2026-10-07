import Combine
import SpeakCore
import XCTest

@testable import SpeakApp

final class OnboardingStateTests: XCTestCase {
    @MainActor
    func testLocalSetup_waitsForInstallationAndConfirmationBeforeChangingSettings() async throws {
        let state = try makeState()
        state.settings.postProcessingEnabled = true
        state.settings.postProcessingModel = "openai/gpt-5-mini"
        state.settings.registerAPIKeyIdentifier("openrouter.apiKey")
        let preset = try batchPreset()
        let previousMode = state.settings.transcriptionMode

        await state.configureLocalModel(preset) {
            XCTAssertTrue(state.isConfiguringLocalModel)
            XCTAssertNil(state.configuredLocalPreset)
            XCTAssertEqual(state.settings.transcriptionMode, previousMode)
            return .installed
        }

        XCTAssertEqual(state.configuredLocalPreset, preset)
        XCTAssertEqual(state.settings.transcriptionMode, previousMode)
        XCTAssertTrue(state.settings.postProcessingEnabled)
        XCTAssertTrue(state.completeLocalModelSetup())
        XCTAssertEqual(state.settings.transcriptionMode, .localModel)
        XCTAssertEqual(state.settings.localTranscriptionMode, .batch)
        XCTAssertEqual(state.settings.localTranscriptionModel, "local/whisperkit/large-v3-turbo")
        XCTAssertEqual(state.settings.localTranscriptionSource, .downloaded)
        XCTAssertFalse(state.settings.postProcessingEnabled, "Even stored keys must not enable cloud cleanup")
        XCTAssertFalse(state.isConfiguringLocalModel)
        XCTAssertNil(state.validationError)
    }

    @MainActor
    func testLocalSetup_failedDownloadPreservesUsableSettingsAndShowsError() async throws {
        let state = try makeState()
        let previousMode = state.settings.transcriptionMode
        let previousModel = state.settings.localTranscriptionModel
        await state.configureLocalModel(try batchPreset()) { .failed("No space left") }

        XCTAssertNil(state.configuredLocalPreset)
        XCTAssertEqual(state.settings.transcriptionMode, previousMode)
        XCTAssertEqual(state.settings.localTranscriptionModel, previousModel)
        XCTAssertTrue(try XCTUnwrap(state.validationError).contains("No space left"))
        XCTAssertFalse(state.isConfiguringLocalModel)
    }

    @MainActor
    func testLocalSetup_unreadyDownloadCannotAdvance() async throws {
        let state = try makeState()
        await state.configureLocalModel(try batchPreset()) { .notInstalled }
        XCTAssertNil(state.configuredLocalPreset)
        XCTAssertNotNil(state.validationError)
    }

    @MainActor
    func testLocalSetup_preservesLocalCleanup() async throws {
        let state = try makeState()
        state.settings.postProcessingEnabled = true
        state.settings.postProcessingModel = "local/post-processing/rules"
        await state.configureLocalModel(try batchPreset()) { .installed }
        XCTAssertTrue(state.completeLocalModelSetup())
        XCTAssertTrue(state.settings.postProcessingEnabled)
    }

    @MainActor
    func testLocalDownload_thenRemoteOrSkipDoesNotChangeRecordingOrCleanup() async throws {
        let state = try makeState()
        state.settings.selectRemoteTranscriptionMode(.batch)
        state.settings.postProcessingModel = "openai/gpt-5-mini"
        state.settings.postProcessingEnabled = true
        state.settings.registerAPIKeyIdentifier("openrouter.apiKey")
        await state.configureLocalModel(try batchPreset()) { .installed }

        state.transcriptionLocation = .remote
        state.skipAPIKeySetup()

        XCTAssertEqual(state.settings.transcriptionMode, .batchRemote)
        XCTAssertTrue(state.settings.postProcessingEnabled)
        XCTAssertFalse(state.completeLocalModelSetup(), "A remote choice cannot commit a downloaded local preset")
        state.completeRemoteModelSetup()
        XCTAssertEqual(state.settings.transcriptionMode, .batchRemote)
        XCTAssertEqual(state.settings.rememberedRemoteTranscriptionMode, .batch)
    }

    @MainActor
    func testRemoteCompletion_restoresRememberedModeAfterConfirmedLocalSetup() async throws {
        let state = try makeState()
        state.settings.selectRemoteTranscriptionMode(.batch)
        await state.configureLocalModel(try batchPreset()) { .installed }
        XCTAssertTrue(state.completeLocalModelSetup())

        state.transcriptionLocation = .remote
        state.completeRemoteModelSetup()

        XCTAssertEqual(state.settings.transcriptionMode, .batchRemote)
        XCTAssertEqual(state.settings.rememberedRemoteTranscriptionMode, .batch)
    }

    @MainActor
    func testLocalSetup_leavingDuringDownloadIgnoresLateCompletion() async throws {
        let state = try makeState()
        let previousMode = state.settings.transcriptionMode
        await state.configureLocalModel(try batchPreset()) {
            state.leaveLocalModelSetup()
            XCTAssertFalse(state.isConfiguringLocalModel, "Navigation must not wait for the installer")
            return .installed
        }
        XCTAssertNil(state.configuredLocalPreset)
        XCTAssertEqual(state.settings.transcriptionMode, previousMode)
    }

    @MainActor
    func testLocalSetup_abandonedRequestDoesNotReplaceNewerChoice() async throws {
        let state = try makeState()
        let presets = LocalTranscriptionStarterPreset.recommended(
            for: .batch, availableModels: ModelCatalog.localTranscription, supportsParakeet: false
        )
        let compact = try XCTUnwrap(presets.first { $0.id == .whisperKitCompactBatch })
        await state.configureLocalModel(try batchPreset()) {
            state.leaveLocalModelSetup()
            await state.configureLocalModel(compact) { .installed }
            return .installed
        }

        XCTAssertEqual(state.configuredLocalPreset, compact)
        XCTAssertFalse(state.isConfiguringLocalModel)
        XCTAssertTrue(state.completeLocalModelSetup())
        XCTAssertEqual(state.settings.localTranscriptionModel, "local/whisperkit/base")
    }

    @MainActor
    func testLocalSetup_cancelledDownloadDoesNotActivateAfterLeaving() async throws {
        let state = try makeState()
        let preset = try batchPreset()
        let previousMode = state.settings.transcriptionMode
        let task = Task {
            await state.configureLocalModel(preset) {
                await Task.yield()
                return .installed
            }
        }
        task.cancel()
        await task.value

        XCTAssertNil(state.configuredLocalPreset)
        XCTAssertEqual(state.settings.transcriptionMode, previousMode)
        XCTAssertFalse(state.isConfiguringLocalModel)
    }

    @MainActor
    func testKeylessCompletion_disablesUnavailablePostProcessing() {
        let defaults = makeDefaults()
        let settings = AppSettings(defaults: defaults)
        settings.postProcessingEnabled = true
        settings.postProcessingModel = "openai/gpt-5-mini"

        OnboardingState.disableUnavailablePostProcessing(in: settings)

        XCTAssertFalse(settings.postProcessingEnabled)
        XCTAssertFalse(defaults.bool(forKey: "postProcessingEnabled"))
    }

    @MainActor
    func testKeylessCompletion_preservesAvailableLocalPostProcessing() {
        let settings = AppSettings(defaults: makeDefaults())
        settings.postProcessingEnabled = true
        settings.postProcessingModel = "local/post-processing/rules"

        OnboardingState.disableUnavailablePostProcessing(in: settings)

        XCTAssertTrue(settings.postProcessingEnabled)
    }

    @MainActor
    func testPermissionChanges_updateOnboardingWithoutConfirmationOrAnotherPoll() throws {
        var accessibilityStatus = PermissionStatus.denied
        let host = try makeWireUpTestHost()
        let permissions = host.makePermissions { permission in
            permission == .accessibility ? accessibilityStatus : .granted
        }
        let environment = WireUp.bootstrap(options: host.options(permissions: permissions))
        let state = OnboardingState(
            permissionsManager: permissions,
            secureStorage: environment.secureStorage,
            settings: environment.settings,
            hotKeyManager: environment.hotKeys,
            audioFileManager: environment.audio,
            transcriptionManager: environment.transcription
        )
        XCTAssertFalse(state.permissionsGranted.contains(.accessibility))
        var snapshots: [Set<PermissionType>] = []
        let observer = state.$permissionsGranted.dropFirst().sink { snapshots.append($0) }
        defer { observer.cancel() }

        accessibilityStatus = .granted
        permissions.refresh(.accessibility) // The Settings guide performs this refresh.
        XCTAssertTrue(state.permissionsGranted.contains(.accessibility))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertTrue(snapshots.allSatisfy { $0.contains(.microphone) }, "Never clear unrelated grants")

        permissions.refresh(.accessibility)
        XCTAssertEqual(snapshots.count, 1, "Repeated unchanged polls should not republish onboarding state")
        accessibilityStatus = .denied
        permissions.refresh(.accessibility)
        XCTAssertFalse(state.permissionsGranted.contains(.accessibility), "Revocation must also update immediately")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @MainActor
    private func makeState() throws -> OnboardingState {
        let host = try makeWireUpTestHost()
        let environment = WireUp.bootstrap(options: host.options())
        let state = OnboardingState(
            permissionsManager: environment.permissions,
            secureStorage: environment.secureStorage,
            settings: environment.settings,
            hotKeyManager: environment.hotKeys,
            audioFileManager: environment.audio,
            transcriptionManager: environment.transcription
        )
        state.transcriptionLocation = .local
        return state
    }

    private func batchPreset() throws -> LocalTranscriptionStarterPreset {
        try XCTUnwrap(LocalTranscriptionStarterPreset.recommended(
            for: .batch, availableModels: ModelCatalog.localTranscription, supportsParakeet: false
        ).first { $0.id == .whisperKitBatch })
    }
}

extension OnboardingStateTests {
    @MainActor
    func testRemoteSetup_changedLocationDuringValidationDoesNotSaveOrCommit() async throws {
        let state = try makeState()
        state.transcriptionLocation = .remote
        let previousMode = state.settings.transcriptionMode
        var didSave = false

        let completed = await state.completeRemoteSetup(
            validate: {
                await Task.yield()
                state.transcriptionLocation = .local
                return true
            },
            save: { didSave = true }
        )

        XCTAssertFalse(completed)
        XCTAssertFalse(didSave)
        XCTAssertFalse(state.isCompletingRemoteSetup)
        XCTAssertEqual(state.settings.transcriptionMode, previousMode)
    }

    @MainActor
    func testRemoteSetup_changedLocationDuringSaveDoesNotCommit() async throws {
        let state = try makeState()
        state.transcriptionLocation = .remote
        let previousMode = state.settings.transcriptionMode
        let previousModel = state.settings.liveTranscriptionModel

        let completed = await state.completeRemoteSetup(
            validate: { true },
            save: {
                await Task.yield()
                state.transcriptionLocation = .local
            }
        )

        XCTAssertFalse(completed)
        XCTAssertFalse(state.isCompletingRemoteSetup)
        XCTAssertEqual(state.settings.transcriptionMode, previousMode)
        XCTAssertEqual(state.settings.liveTranscriptionModel, previousModel)
    }

    @MainActor
    func testRemoteSetup_changedProviderKeyOrStepDoesNotCommit() async throws {
        for change in 0..<3 {
            let state = try makeState()
            state.transcriptionLocation = .remote
            state.currentStep = .apiKey
            let previousMode = state.settings.transcriptionMode
            let completed = await state.completeRemoteSetup(
                validate: { true },
                save: {
                    await Task.yield()
                    switch change {
                    case 0: state.selectedProvider = .openai
                    case 1: state.apiKey = "changed-test-key"
                    default: state.currentStep = .complete
                    }
                }
            )
            XCTAssertFalse(completed)
            XCTAssertEqual(state.settings.transcriptionMode, previousMode)
        }
    }

    @MainActor
    func testRemoteSetup_unchangedSubmissionCommitsOnceAndRejectsOverlap() async throws {
        let state = try makeState()
        state.transcriptionLocation = .remote
        state.settings.selectRemoteTranscriptionMode(.batch)
        state.settings.selectLocalTranscriptionSource(.apple)
        var saveCount = 0

        let completed = await state.completeRemoteSetup(
            validate: {
                XCTAssertTrue(state.isCompletingRemoteSetup)
                let overlapping = await state.completeRemoteSetup(
                    validate: {
                        XCTFail("Must reject overlapping submission")
                        return true
                    },
                    save: { XCTFail("Must not save twice") }
                )
                XCTAssertFalse(overlapping)
                return true
            },
            save: { saveCount += 1 }
        )

        XCTAssertTrue(completed)
        XCTAssertEqual(saveCount, 1)
        XCTAssertEqual(state.settings.transcriptionMode, .batchRemote)
        XCTAssertEqual(state.settings.rememberedRemoteTranscriptionMode, .batch)
        XCTAssertFalse(state.isCompletingRemoteSetup)
    }
}
