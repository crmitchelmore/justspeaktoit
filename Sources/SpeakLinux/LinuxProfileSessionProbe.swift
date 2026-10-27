import Foundation
import Glibc
import SpeakCore
import SpeakDesktop
import SpeakDesktopHost
import SpeakLinuxPlatform
import CLinuxSupport

/// Recorded-audio integration mode, never part of normal app startup.
enum LinuxProfileSessionProbe {
    struct Target: Decodable, Sendable {
        let window: UInt64
        let processID: Int32
        let executable: String
    }

    struct Fixture: Decodable, Sendable {
        let version: Int
        let ownerPID: Int32
        let display: String
        let dataDirectory: String
        let signalDirectory: String
        let deviceID: String
        let modelRoot: String
        let targets: [Target]
    }

    static let modelID = "local/whisperkit/tiny"
    static let profileName = "Owned recorded local profile"
    static let clipboard = LinuxTextOutputOptions(method: .clipboardOnly, restoreClipboard: false)

    static func fixture() throws -> Fixture {
        let file = URL(fileURLWithPath: try LinuxIntegrationChecks.environment("JSTI_PROFILE_SESSION_FIXTURE"))
        let root = file.deletingLastPathComponent().standardizedFileURL
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: file))
        try require(fixture.version == 1 && fixture.ownerPID == getppid()
            && fixture.display == ProcessInfo.processInfo.environment["DISPLAY"]
            && fixture.targets.count == 2, "fixture identity does not match its owning parent/display")
        for (name, path) in [("data", fixture.dataDirectory), ("signals", fixture.signalDirectory)] {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            try require(url == root.appendingPathComponent(name)
                && attributes[.type] as? FileAttributeType == .typeDirectory
                && (attributes[.ownerAccountID] as? NSNumber)?.intValue == Int(getuid())
                && ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0,
                "fixture folders must be private owned siblings, not symlinks or ambient data")
        }
        try require(fixture.targets[0].processID != fixture.targets[1].processID
            && fixture.targets[0].executable != fixture.targets[1].executable
            && fixture.deviceID.hasSuffix(".monitor"), "fixture needs distinct owned apps and its recorded monitor")
        return fixture
    }

    static func directory() throws -> URL {
        let fixture = try fixture()
        let directory = URL(fileURLWithPath: fixture.dataDirectory, isDirectory: true)
        try require(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
                    "the probe refuses to adopt any existing app data")
        return directory
    }

    static func prepare(directory: URL) throws {
        let fixture = try fixture()
        guard let route = DesktopHostModels.live.first(where: {
            DesktopLiveTranscription.route(forID: $0.id)?.sampleRate == 24_000
        }) else { throw DesktopHostError(message: "The profile probe needs a canonical 24 kHz route.") }
        let profiles = [
            DictationProfile(
                name: profileName, matchers: [.init(kind: .linuxExecutablePath, value: fixture.targets[0].executable)],
                transcriptionModelID: modelID, polishEnabled: true,
                polishModelID: LocalPostProcessingModel.builtInRulesModelID, languageIdentifier: "en",
                transcriptionRouting: .localBatch
            ),
            DictationProfile(
                name: "Owned incompatible rate", matchers: [
                    .init(kind: .linuxExecutablePath, value: fixture.targets[1].executable)
                ], transcriptionModelID: route.id, polishEnabled: false, transcriptionRouting: .remoteStreaming
            )
        ]
        try DesktopDictationProfileStore(directory: directory).save(profiles)
        var settings = LinuxAppController.Settings()
        settings.localUseGPU = false
        settings.microphoneDeviceID = fixture.deviceID
        settings.textOutput = clipboard
        settings.postProcessing = .init(mode: .disabled)
        settings.configuration = try DesktopConfiguration(values: [
            "handsFreeDictationEnabled": AnyCodable(.bool(true)),
            "silenceDetectionEnabled": AnyCodable(.bool(false)),
            "silenceThreshold": AnyCodable(.double(0.01)),
            "silenceDuration": AnyCodable(.double(1.5)),
            "postRecordingTailDuration": AnyCodable(.double(0.1)),
            "recordingSoundsEnabled": AnyCodable(.bool(false)),
            "showHUD": AnyCodable(.bool(false)),
            "voiceCommandsEnabled": AnyCodable(.bool(false))
        ])
        try JSONEncoder().encode(settings).write(to: directory.appendingPathComponent("settings.json"))
        // A valid fresh empty discovery cache prevents ready() from contacting
        // OpenRouter. No catalogue entries or provider behavior are fabricated.
        let cache: [String: Any] = ["version": 1, "updatedAt": Date().timeIntervalSinceReferenceDate, "models": []]
        try JSONSerialization.data(withJSONObject: cache)
            .write(to: directory.appendingPathComponent("OpenRouterAudioCatalog.json"))
    }

    static func run(controller: LinuxAppController, effects: LinuxProfileProbeEffects) async throws {
        do {
            try await checks(controller: controller, effects: effects)
            let closed = await controller.close()
            try require(closed.isComplete, "the actual controller did not close all owned resources")
        } catch {
            _ = await controller.close()
            throw error
        }
    }

    private static func checks(controller: LinuxAppController, effects: LinuxProfileProbeEffects) async throws {
        let fixture = try fixture()
        let signals = URL(fileURLWithPath: fixture.signalDirectory, isDirectory: true)
        try require(jsti_window_hands_free_guard_ready() != 0, "normal native session guard is not ready")
        try await copyModel(controller: controller, fixture: fixture)
        let catalogue = await controller.modelCatalog
        try require(!catalogue.isStale, "discovery cache admission failed; refusing ready() network work")
        await controller.ready()
        let index = await controller.selectedIndex()
        try require(DesktopHostModels.all[index].id != modelID, "profile override must differ from the app default")
        try require(await controller.selectModel(index), "default model could not be persisted")
        let baseline = await controller.settings
        let before = effects.snapshot()
        try signal("ready", in: signals)
        try await manualAndAutomatic(controller, effects: effects, fixture: fixture, index: index, signals: signals)
        try await rateRefusal(controller, effects: effects, fixture: fixture, index: index, signals: signals)
        try await ownerLoss(controller, fixture: fixture, index: index, signals: signals)
        let after = effects.snapshot()
        try require(after.transcriptions.count - before.transcriptions.count == 2
            && after.credentialReads == before.credentialReads && after.remoteLiveAttempts == 0,
            "unexpected provider boundary or transcription count")
        let settings = await controller.settings
        try require(settings.model == baseline.model && settings.configuration == baseline.configuration
            && settings.postProcessing == baseline.postProcessing, "profile mutated global transcription policy")
        let evidence = try JSONEncoder().encode(after)
        guard let text = String(data: evidence, encoding: .utf8) else {
            throw DesktopHostError(message: "The recorded probe evidence was not UTF-8.")
        }
        print("Recorded Linux profiles: manual/local result, automatic/local result and copied rearm, "
            + "24k/16k refusal before attempt, native guard owner-loss and unchanged defaults passed.")
        print("Recorded Linux profile effects: " + text)
        try signal("complete", in: signals)
    }

    private static func manualAndAutomatic(
        _ controller: LinuxAppController, effects: LinuxProfileProbeEffects, fixture: Fixture, index: Int, signals: URL
    ) async throws {
        try await waitFor("manual", in: signals)
        print("Recorded Linux profile stage: manual begin.")
        let target = try capture(fixture.targets[0])
        let profile = await controller.captureProfile(modelIndex: index, executablePath: target.executablePath)
        try require(profile.canRecord && profile.profileName == profileName && profile.modelIdentifier == modelID
            && profile.language == "en" && profile.postProcessing.mode == .local, "manual profile did not resolve")
        await controller.toggleCaptured(
            target: target, modelIndex: index, deviceID: fixture.deviceID, textOutput: clipboard, profile: profile
        )
        let active = await controller.recording
        try require(active?.profile == profile, "manual recording did not retain the captured profile")
        try signal("manual-capture-ready", in: signals)
        try await waitFor("manual-audio-done", in: signals)
        await controller.toggleCaptured(
            target: target, modelIndex: index, deviceID: fixture.deviceID, textOutput: clipboard, profile: profile
        )
        try await verifyRecords(controller: controller, count: 1)
        try await wait("manual clipboard acknowledgment") { effects.snapshot().copiedOutputs == 1 }
        print("Recorded Linux profile stage: manual acknowledged.")
        try signal("manual-complete", in: signals)

        try await waitFor("automatic", in: signals)
        print("Recorded Linux profile stage: automatic begin.")
        let automaticTarget = try capture(fixture.targets[0])
        await arm(controller, index: index, fixture: fixture, target: automaticTarget)
        try await wait("armed native detector") { await controller.handsFreeState() == .armed }
        try signal("automatic-capture-ready", in: signals)
        try await wait("automatic result and acknowledged rearm") {
            let records = try await controller.store.records()
            let state = await controller.handsFreeState()
            return records.count == 2 && effects.snapshot().copiedOutputs == 2
                && state == .armed
        }
        try await verifyRecords(controller: controller, count: 2)
        print("Recorded Linux profile stage: automatic acknowledged.")
        try signal("automatic-complete", in: signals)
    }

    private static func rateRefusal(
        _ controller: LinuxAppController, effects: LinuxProfileProbeEffects, fixture: Fixture, index: Int, signals: URL
    ) async throws {
        try await waitFor("rate", in: signals)
        print("Recorded Linux profile stage: rate refusal begin.")
        let different = try capture(fixture.targets[1])
        let incompatible = await controller.captureProfile(modelIndex: index, executablePath: different.executablePath)
        try require(incompatible.canRecord && DesktopLiveTranscription.route(
            forID: incompatible.modelIdentifier
        )?.sampleRate == 24_000, "negative profile must be a valid canonical 24 kHz route")
        let prior = effects.snapshot()
        try signal("rate-capture-ready", in: signals)
        try await wait("incompatible rate disarm") { await controller.handsFreeState() == .off }
        let rejected = effects.snapshot()
        let state = String(describing: await controller.handsFreeState())
        let guardReady = jsti_window_hands_free_guard_ready() != 0
        try rateDiagnostic(prior: prior, rejected: rejected, expected: fixture.targets[1], profile: incompatible,
                           nativeState: (guardReady, state))
        try require(guardReady
            && rejected.contexts.last == fixture.targets[1].executable
            && rejected.captureRates == prior.captureRates
            && rejected.credentialReads == prior.credentialReads
            && rejected.remoteLiveAttempts == prior.remoteLiveAttempts
            && rejected.transcriptions == prior.transcriptions && rejected.copiedOutputs == prior.copiedOutputs,
            "rate refusal reached credentials, capture, provider or output")
        try await verifyRecords(controller: controller, count: 2)
        print("Recorded Linux profile stage: rate refusal acknowledged.")
        try signal("rate-complete", in: signals)
    }

    private static func ownerLoss(
        _ controller: LinuxAppController, fixture: Fixture, index: Int, signals: URL
    ) async throws {
        try await waitFor("owner-loss", in: signals)
        print("Recorded Linux profile stage: owner loss begin.")
        await arm(controller, index: index, fixture: fixture, target: try capture(fixture.targets[0]))
        try await wait("rearmed before owned service loss") { await controller.handsFreeState() == .armed }
        try signal("owner-loss-ready", in: signals)
        try await wait("real native guard owner-loss refusal") {
            let state = await controller.handsFreeState()
            return jsti_window_hands_free_guard_ready() == 0 && state == .off
        }
        try await verifyRecords(controller: controller, count: 2)
        print("Recorded Linux profile stage: owner loss acknowledged.")
    }
}

private extension LinuxProfileSessionProbe {
    static func rateDiagnostic(
        prior: LinuxProfileProbeEffects.Evidence, rejected: LinuxProfileProbeEffects.Evidence,
        expected: Target, profile: DesktopProfileSession, nativeState: (ready: Bool, state: String)
    ) throws {
        let predicates = [
            "guardReady": nativeState.ready, "lastContextIsOwnedB": rejected.contexts.last == expected.executable,
            "captureRatesUnchanged": rejected.captureRates == prior.captureRates,
            "credentialReadsUnchanged": rejected.credentialReads == prior.credentialReads,
            "remoteLiveAttemptsUnchanged": rejected.remoteLiveAttempts == prior.remoteLiveAttempts,
            "transcriptionsUnchanged": rejected.transcriptions == prior.transcriptions,
            "copiedOutputsUnchanged": rejected.copiedOutputs == prior.copiedOutputs
        ]
        let observation: [String: Any] = [
            "version": 1, "stage": "rate-refusal", "predicates": predicates, "actualState": nativeState.state,
            "capturedProfileIsOwnedB": profile.profileName == "Owned incompatible rate",
            "capturedProfileCanRecord": profile.canRecord,
            "capturedProfileRate": DesktopLiveTranscription.route(forID: profile.modelIdentifier)?.sampleRate ?? 0,
            "expectedDetectorRate": 16_000, "desiredRate": 24_000,
            "lastObservedCaptureRateBefore": prior.captureRates.last ?? 0,
            "contextCountBefore": prior.contexts.count, "contextCountAfter": rejected.contexts.count,
            "lastContextWasOwnedBBefore": prior.contexts.last == expected.executable,
            "captureRateCountBefore": prior.captureRates.count, "captureRateCountAfter": rejected.captureRates.count,
            "captureRatesBefore": Array(prior.captureRates.prefix(8)),
            "captureRatesAfter": Array(rejected.captureRates.prefix(8)),
            "credentialReadsBefore": prior.credentialReads, "credentialReadsAfter": rejected.credentialReads,
            "remoteLiveAttemptsBefore": prior.remoteLiveAttempts,
            "remoteLiveAttemptsAfter": rejected.remoteLiveAttempts,
            "transcriptionCountBefore": prior.transcriptions.count,
            "transcriptionCountAfter": rejected.transcriptions.count,
            "copiedOutputsBefore": prior.copiedOutputs, "copiedOutputsAfter": rejected.copiedOutputs,
            "nativeContextErrorsObservable": false
        ]
        let data = try JSONSerialization.data(withJSONObject: observation, options: .sortedKeys)
        guard let text = String(data: data, encoding: .utf8) else {
            throw DesktopHostError(message: "The recorded rate observation was not UTF-8.")
        }
        print("Recorded Linux profile rate observation: " + text)
    }
}
