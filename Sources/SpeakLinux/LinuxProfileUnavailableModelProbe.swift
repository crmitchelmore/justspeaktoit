import Foundation
import Glibc
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

extension LinuxProfileSessionProbe {
    static func unavailableModel() throws -> WhisperCppModel {
        guard let model = DesktopLocalTranscription.models(host: .linux).first(where: { model in
            model.catalogueID != modelID && DesktopHostModels.local.contains { $0.id == model.catalogueID }
        }) else { throw DesktopHostError(message: "The probe needs a second canonical Linux local model.") }
        return model
    }

    static func unavailableProfile(fixture: Fixture) throws -> DictationProfile {
        DictationProfile(
            name: "Owned unavailable local model", matchers: [
                .init(kind: .linuxExecutablePath, value: fixture.targets[2].executable)
            ], transcriptionModelID: try unavailableModel().catalogueID, polishEnabled: false,
            transcriptionRouting: .localBatch
        )
    }

    static func unavailableRefusal(
        _ controller: LinuxAppController, effects: LinuxProfileProbeEffects, fixture: Fixture, index: Int, signals: URL
    ) async throws {
        try await waitFor("unavailable-manual", in: signals)
        print("Recorded Linux profile stage: unavailable manual begin.")
        let target = try capture(fixture.targets[2])
        let profile = try await unavailableSelection(controller, target: target, index: index)
        let manualBefore = effects.snapshot()
        let recordIDs = try await controller.store.records().map(\.id)
        try require(await controller.handsFreeState() == .off, "manual unavailable case must start disarmed")
        try await wait("idle before manual unavailable attempt") { !(await controller.busy) }
        try require(!(await controller.closed), "manual unavailable case cannot use a closed controller")
        await controller.toggleCaptured(
            target: target, modelIndex: index, deviceID: fixture.deviceID, textOutput: clipboard, profile: profile
        )
        try await verifyUnavailableRefusal(
            controller, effects: effects, prior: manualBefore, recordIDs: recordIDs,
            context: (fixture.targets[2], false)
        )
        try await verifyRecords(controller: controller, count: 2)
        print("Recorded Linux profile stage: unavailable manual acknowledged.")
        try signal("unavailable-manual-complete", in: signals)

        try await waitFor("unavailable-arm", in: signals)
        let beforeArm = effects.snapshot()
        await arm(controller, index: index, fixture: fixture, target: try capture(fixture.targets[0]))
        try await wait("armed before unavailable-model switch") { await controller.handsFreeState() == .armed }
        let armed = effects.snapshot()
        try require(armed.captureRates == beforeArm.captureRates + [16_000],
                    "unavailable-case arming must create exactly one owned 16 kHz detector")
        try signal("unavailable-armed", in: signals)
        try await waitFor("unavailable-automatic", in: signals)
        print("Recorded Linux profile stage: unavailable automatic begin.")
        _ = try await unavailableSelection(controller, target: capture(fixture.targets[2]), index: index)
        // Arming legitimately added its detector. Only the subsequent refused
        // utterance is required to leave this baseline unchanged.
        let automaticBefore = effects.snapshot()
        try signal("unavailable-capture-ready", in: signals)
        try await wait("unavailable-model disarm") { await controller.handsFreeState() == .off }
        try await verifyUnavailableRefusal(
            controller, effects: effects, prior: automaticBefore, recordIDs: recordIDs,
            context: (fixture.targets[2], true)
        )
        try await verifyRecords(controller: controller, count: 2)
        print("Recorded Linux profile stage: unavailable automatic acknowledged.")
        try signal("unavailable-automatic-complete", in: signals)
    }
}

private extension LinuxProfileSessionProbe {
    static func unavailableSelection(
        _ controller: LinuxAppController, target: LinuxInsertionTarget, index: Int
    ) async throws -> DesktopProfileSession {
        let spec = try unavailableModel()
        let installer = await controller.localInstaller
        let item = LocalModelInstaller.Item(spec)
        let path = installer.directory(for: item).appendingPathComponent(item.artifact.filename).path
        let descriptor = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        let openError = errno
        if descriptor >= 0 { _ = close(descriptor) }
        try require(descriptor == -1 && openError == ENOENT && installer.state(of: item) == .notInstalled,
                    "the canonical negative model payload must be absent from the private installer")
        let profile = await controller.captureProfile(modelIndex: index, executablePath: target.executablePath)
        try require(profile.canRecord && profile.profileName == "Owned unavailable local model"
            && profile.modelIdentifier == spec.catalogueID && DesktopHostModels.isLocal(profile.modelIdentifier),
            "the negative profile must select its actual canonical local model, not a fallback")
        let tinyReadiness = await controller.localReadiness(modelID)
        let missingReadiness = await controller.localReadiness(spec.catalogueID)
        try require(tinyReadiness == nil && missingReadiness != nil,
                    "only the uninstalled model, not the working runtime, must be unavailable")
        return profile
    }

    static func verifyUnavailableRefusal(
        _ controller: LinuxAppController, effects: LinuxProfileProbeEffects,
        prior: LinuxProfileProbeEffects.Evidence, recordIDs: [UUID], context: (target: Target, automatic: Bool)
    ) async throws {
        let (expected, automatic) = context
        try await wait("idle after unavailable-model refusal") { !(await controller.busy) }
        let afterIDs = try await controller.store.records().map(\.id)
        let state = await controller.handsFreeState()
        let recording = await controller.recording
        let busy = await controller.busy
        let closed = await controller.closed
        let rejected = effects.snapshot()
        let guardReady = jsti_window_hands_free_guard_ready() != 0
        let contextCurrent = automatic
            ? rejected.contexts.count == prior.contexts.count + 1 && rejected.contexts.last == expected.executable
            : rejected.contexts == prior.contexts
        let predicates = [
            "guardReady": guardReady, "disarmed": state == .off,
            "noRecording": recording == nil, "controllerIdleAndOpen": !busy && !closed,
            "freshAutomaticContextOrUnchangedManualContext": contextCurrent,
            "captureRatesUnchanged": rejected.captureRates == prior.captureRates,
            "credentialReadsUnchanged": rejected.credentialReads == prior.credentialReads,
            "remoteLiveAttemptsUnchanged": rejected.remoteLiveAttempts == prior.remoteLiveAttempts,
            "transcriptionsUnchanged": rejected.transcriptions == prior.transcriptions,
            "copiedOutputsUnchanged": rejected.copiedOutputs == prior.copiedOutputs,
            "historyIDsUnchanged": Set(afterIDs) == Set(recordIDs) && afterIDs.count == recordIDs.count
        ]
        let observation: [String: Any] = [
            "version": 1, "stage": automatic ? "unavailable-automatic" : "unavailable-manual",
            "predicates": predicates, "actualState": String(describing: state),
            "captureRateCountBefore": prior.captureRates.count, "captureRateCountAfter": rejected.captureRates.count,
            "contextCountBefore": prior.contexts.count, "contextCountAfter": rejected.contexts.count,
            "credentialReadsBefore": prior.credentialReads, "credentialReadsAfter": rejected.credentialReads,
            "remoteLiveAttemptsBefore": prior.remoteLiveAttempts,
            "remoteLiveAttemptsAfter": rejected.remoteLiveAttempts,
            "transcriptionCountBefore": prior.transcriptions.count,
            "transcriptionCountAfter": rejected.transcriptions.count,
            "copiedOutputsBefore": prior.copiedOutputs, "copiedOutputsAfter": rejected.copiedOutputs,
            "historyCountBefore": recordIDs.count, "historyCountAfter": afterIDs.count
        ]
        let data = try JSONSerialization.data(withJSONObject: observation, options: .sortedKeys)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DesktopHostError(message: "The unavailable-model observation was not UTF-8.")
        }
        print("Recorded Linux profile unavailable observation: " + text)
        try require(predicates.values.allSatisfy { $0 }, "unavailable model crossed an attempt or ownership boundary")
    }
}
