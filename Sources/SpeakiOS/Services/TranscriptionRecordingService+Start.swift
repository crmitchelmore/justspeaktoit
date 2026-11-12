#if os(iOS)
import Foundation
import SpeakCore
import UIKit

/// Startup: admits a run, publishes its preparing state, starts its session
/// and unwinds exactly what that run allocated when it is cancelled or fails
/// (issues #701, #943, #983).
@MainActor
extension TranscriptionRecordingService {

    /// Starts a headless recording session with Live Activity.
    ///
    /// A capture link's `model=`, `lang=` and `destination=` arrive as
    /// `parameters`, the same channel a Shortcut's per-run parameters use, and
    /// apply to this session only. Every value is validated against its
    /// catalogue by the caller, so an unrecognised one never reaches here — it
    /// fails the link instead.
    ///
    /// - Parameter entry: the earliest app-code entry the caller observed —
    ///   an intent's `perform()` entry, or the moment the app began handling a
    ///   keyboard request. Callers with no earlier observation pass `nil` and
    ///   the service times its own entry (issue #972).
    public func startRecording(
        retainBatchRecording: Bool = true,
        sharesLiveTranscript: Bool = true,
        requiresLiveActivity: Bool = true,
        keyboardProfile: KeyboardDictationProfileOption? = nil,
        trigger: CaptureTrigger? = nil,
        parameters: CaptureRunParameters = .none,
        endPointing: CaptureEndPointingRequest? = nil,
        entry: StartupEntry? = nil
    ) async throws {
        try await startRecording(
            retainBatchRecording: retainBatchRecording,
            sharesLiveTranscript: sharesLiveTranscript,
            requiresLiveActivity: requiresLiveActivity,
            keyboardProfile: keyboardProfile,
            trigger: trigger,
            parameters: parameters,
            endPointing: endPointing,
            destination: nil,
            entry: entry
        )
    }

    /// Internal callers can retain their destination and request ownership for an automatic stop.
    func startRecording( // swiftlint:disable:this function_body_length
        retainBatchRecording: Bool = true,
        sharesLiveTranscript: Bool = true,
        requiresLiveActivity: Bool = true,
        keyboardProfile: KeyboardDictationProfileOption? = nil,
        trigger: CaptureTrigger? = nil,
        parameters: CaptureRunParameters = .none,
        endPointing: CaptureEndPointingRequest? = nil,
        destination: HardwareTriggerDestination?,
        entry: StartupEntry? = nil,
        configurationRequest: CaptureConfigurationRequest? = nil,
        onCaptureDisruption: (() async -> Void)? = nil
    ) async throws {
        try foregroundOwnership.requireUnowned()
        guard let runID = lifecycle.beginStart() else { return }
        startupWatchdogFailure = nil
        configurationRequest?.admittedRunID = runID
        presentation.begin(run: runID)
        diagnostics.begin(run: runID, entry: entry, localOrigin: .service)
        // Armed before the first suspension point, so the start deadline covers
        // the credentials wait as well as the backend start. Every teardown
        // path below disarms it (issue #993).
        armWatchdogs(run: runID, entry: entry)
        // Claimed before the first suspension point too, so every unwind below
        // publishes an empty completion for *this* run rather than leaving a
        // waiter to read an older one.
        runLedger.begin(runID)
        health.requests.begin(runID)
        recordingWarningRunID = UUID()
        state = lifecycle.state
        defer { state = lifecycle.state }

        let settings = self.settings
        let configuration = try await admittedConfiguration(
            parameters: parameters, keyboardProfile: keyboardProfile, destination: destination,
            request: configurationRequest, run: runID
        )
        effectiveConfiguration = configuration
        health.requests.admit(
            IOSRequestDiagnosticProjection.admission(configuration, keyboardProfile: keyboardProfile != nil), run: runID
        )
        effectiveDestination = CaptureDestinationSelection(
            configuration: configuration, keyboardProfile: keyboardProfile != nil
        )
        // AppSettings.init publishes empty API keys and loads the real values
        // from the keychain asynchronously. A cold launch from the Action
        // Button could read those empty keys and silently fall back to Apple
        // Speech, so wait for the initial load before resolving the model.
        await ensureKeysLoaded()
        diagnostics.note(.stage(.credentialsReady), run: runID)
        // Revalidate at acquisition, even when an intent preflight preceded a
        // suspension: a foreground claim made during the credentials wait must
        // refuse this run before it allocates anything or publishes state.
        try requireForegroundUnownedForAcquisition(run: runID)
        // A stop/cancel during the suspension above retires the run; nothing
        // has been allocated yet, so unwinding only settles the state machine.
        try requireUncancelledStart(run: runID)

        lastSessionError = nil
        sessionErrorToken = nil
        captureStopNotice = nil
        recordingWarning = nil
        providerFallbackNotice = nil
        offlineIntendedModel = nil
        currentTrigger = keyboardProfile == nil ? trigger : .keyboard
        // A model the catalogue only lists for batch transcription cannot run in
        // streaming mode, so an explicit `model=` (from a capture link or a
        // Shortcut) decides the mode rather than being started in a mode it has
        // no client for. `modelSelection` owns that rule for every surface.
        let runParameters = adoptRunParameters(configuration.parameters, keyboardProfile: keyboardProfile)
        let usesBatchTranscription = configuration.usesBatch
        currentModel = configuration.modelID
        try validateCredentialAvailability(
            settings: settings,
            usesBatchTranscription: usesBatchTranscription,
            keyboardProfile: keyboardProfile,
            run: runID
        )
        partialText = ""
        wordCount = 0
        sharedStateWrites.reset()
        currentSessionID = runID
        startTime = Date()
        self.sharedTranscriptRequested = sharesLiveTranscript
        self.sharesLiveTranscript = sharesLiveTranscript
            && configuration.destinationID != HardwareTriggerDestination.historyOnly.rawValue
        // Explicit internal destination beats the override the run carried,
        // which beats the global setting (issue #1013).
        self.automaticStopDestination = HardwareTriggerDestination(rawValue: configuration.destinationID) ?? .clipboard
        self.onCaptureDisruption = onCaptureDisruption
        sharedState.clear()
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime

        // Before the microphone opens: a named model this device cannot run —
        // no iOS route for the mode this run will use, or no credential for it
        // — refuses the whole capture rather than recording and failing later.
        // Batch and live are both covered here; the live path additionally has
        // its own on-device-fallback check below.
        try refuseUnusableRequestedModel(
            runParameters.modelID,
            usesBatch: usesBatchTranscription,
            settings: settings,
            run: runID
        )

        let languageIdentifier = configuration.languageIdentifier
        let localeIdentifier = TranscriptionLanguageCatalog.localeIdentifier(for: languageIdentifier)
        let strictOnDeviceRecognition = try applyOfflineRouting(
            usesBatch: usesBatchTranscription,
            binding: keyboardProfile == nil
                ? (runParameters.modelID == nil ? .ordinary : .explicitModel)
                : .keyboardProfile,
            localeIdentifier: localeIdentifier,
            run: runID
        )

        if !usesBatchTranscription && keyboardProfile == nil {
            try resolveLiveModelHonouringRequest(
                settings: settings,
                // Either source counts as the caller naming a model: a
                // Shortcut parameter (#1076) or a capture link's `model=`
                // (#1070). Both arrive as `CaptureRunParameters.modelID` here,
                // and both must fail visibly rather than be substituted.
                requestedModelID: runParameters.modelID,
                run: runID
            )
        }

        // A Live Activity is required to record in the *background* via an
        // AudioRecordingIntent — without one the AppIntents system-policy check
        // asserts (EXC_BREAKPOINT). In the foreground a Live Activity is optional,
        // so only enforce this when the app isn't active. The optional
        // foreground activity honours the Live Activities setting (#1017).
        let appIsActive = dependencies.applicationState() == .active
        let activityProvider = providerFallbackNotice == OfflineCaptureRouting.fallbackNotice
            ? "\(modelDisplayName) (Offline)"
            : providerFallbackNotice == nil
                ? modelDisplayName
                : "\(modelDisplayName) (\(settings.credentialFallbackReason))"
        let wantsActivity = appIsActive ? settings.liveActivitiesEnabled : requiresLiveActivity
        let activityStarted = wantsActivity
            ? activityManager.startActivity(provider: activityProvider, initialStatus: .arming)
            : false
        if requiresLiveActivity && !activityStarted && !appIsActive {
            unwindCancelledStart(outcome: .failed, run: runID)
            throw iOSTranscriptionError.liveActivityUnavailable
        }

        #if DEBUG && targetEnvironment(simulator)
        if let transcript = sharedState.simulatorValidationTranscript {
            // A synthetic transcript is not observed microphone input, but this
            // DEBUG-only simulator stub has no input tap at all. Resolve the
            // gate explicitly so the harness never sits in preparation.
            presentation.noteBackendStarted(run: runID)
            presentation.noteInputObserved(run: runID)
            // The stub has no audio session, no engine and no tap, so there is
            // no start to bound and no microphone that could go silent.
            disarmWatchdogs()
            noteSimulatorStubStartup(runID: runID)
            handlePartialResult(text: transcript)
            _ = lifecycle.activate(runID)
            state = lifecycle.state
            isRunning = true
            return
        }
        #endif

        var startedSession: (any IOSRecordingSession)?
        do {
            let mode: IOSTranscriptionSession.Mode = usesBatchTranscription
                ? .batch(retainRecording: retainBatchRecording)
                : .streaming
            // Both seams are honoured: `makeSession` (#936) injects any
            // recording session so an interruption can finalise through its
            // owner, while `sessionFactory` remains the concrete test seam.
            let session: any IOSRecordingSession = try makeSession?()
                ?? sessionFactory?()
                ?? IOSTranscriptionSession(
                modelID: currentModel,
                mode: mode,
                language: TranscriptionLanguageCatalog.providerLanguage(for: languageIdentifier),
                audioSessionManager: audioSessionManager,
                batchAPIKey: settings.batchAPIKey(for: currentModel),
                liveAPIKey: settings.liveAPIKey(for:),
                transcriptionKeywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords),
                requiresStrictOnDeviceRecognition: strictOnDeviceRecognition
            )
            session.onPartialResult = { [weak self, weak session] text, isFinal in
                guard let self, let session,
                      self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session
                        || self.stoppingSession === session else { return }
                self.noteFirstLivePartial(text: text, isFinal: isFinal, runID: runID)
                self.handlePartialResult(text: text)
            }
            bindRecordingWarning(session, runID: runID)
            session.onError = { [weak self, weak session] error in
                guard let self, let session,
                      self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session
                        || self.stoppingSession === session else { return }
                self.handleError(error, session: session)
            }
            bindFirstInput(session: session, runID: runID)
            bindStartupDiagnostics(session: session, runID: runID)
            startedSession = session
            guard lifecycle.installStartCancellation(for: runID, cancel: { session.cancel() }) else {
                throw CancellationError()
            }
            health.requests.observe(
                session.resolution, run: runID, defaultSession: makeSession == nil && sessionFactory == nil
            )
            try await session.start()
            diagnostics.note(.stage(.sessionStarted), run: runID)
            // The session this run allocated is published only while the run
            // is still current; a stop during start() retires the run, and the
            // cleanup below tears down exactly what this run owns without
            // touching any replacement run's session (issue #701).
            guard lifecycle.activate(runID) else {
                // The catch owns cleanup, including a watchdog's real terminal cause.
                throw CancellationError()
            }
            transcriptionSession = session
            isRunning = true
            // The tap can deliver before `start()` returns, so this may be the
            // second half of the pair rather than the first.
            notePresentation(presentation.noteBackendStarted(run: runID))
            diagnostics.finish(.started, run: runID)
            // Armed only after activation, so a capture that never went live
            // leaves no monitor behind and the run identity the monitor checks
            // is the session that is actually recording (issue #1012). A `nil`
            // request arms nothing and the capture behaves exactly as it did
            // before end-pointing existed.
            armEndPointing(
                Self.endPointingRequest(
                    explicit: endPointing,
                    trigger: trigger,
                    keyboardProfile: keyboardProfile,
                    settings: settings
                ),
                for: session
            )
        } catch {
            // Unwind runs for the retired case too: a stop that cancelled this
            // startup is awaiting settlement, and this run still owns whatever
            // it allocated. `transcriptionSession` is untouched — it is only
            // ever assigned after successful activation.
            startedSession?.cancel()
            let watchdogFailure = startupWatchdogFailure.flatMap { $0.runID == runID ? $0.error : nil }
            let failure: Error = (watchdogFailure as Error?) ?? error
            let ownsCleanup = currentRunID == runID && lifecycle.state == .starting
                && (lifecycle.isCurrentStartRun(runID) || watchdogFailure != nil)
            let terminalFailure = activityStarted && ownsCleanup
                && !foregroundOwnership.isOwned && outcome(for: failure) == .failed
                ? CaptureStartFailurePresentation.make(for: failure) : nil
            unwindCancelledStart(outcome: outcome(for: failure), run: runID, activityFailure: terminalFailure)
            throw error
        }
    }

    /// Refuses headless acquisition when the foreground claimed the microphone
    /// while this run was suspended on credentials (#943).
    ///
    /// Only this run's own bookkeeping is unwound. Nothing it allocated has
    /// reached the microphone, the App Group or the Live Activity, and the
    /// activity and recording flag now belong to the foreground owner, so the
    /// general cancelled-start unwind — which ends the activity and clears the
    /// flag — must not run here.
    func requireForegroundUnownedForAcquisition(run runID: UUID) throws {
        do {
            try foregroundOwnership.requireUnowned()
        } catch {
            disarmWatchdogs()
            diagnostics.finish(.failed, run: runID)
            presentation.finish()
            // A capture that never went live completes empty for its own run.
            completeRun(with: "")
            effectiveConfiguration = nil
            effectiveDestination = nil
            lifecycle.finishStartUnwind()
            state = lifecycle.state
            throw error
        }
    }

    private func requireUncancelledStart(run runID: UUID) throws {
        guard !Task.isCancelled, lifecycle.isCurrentStartRun(runID) else {
            unwindCancelledStart(outcome: .cancelled, run: runID)
            throw CancellationError()
        }
    }

    /// Reverts everything a cancelled startup run had published: timing,
    /// shared App Group recording state and the Live Activity. The run calls
    /// this itself so ownership never crosses runs.
    func unwindCancelledStart(
        outcome: StartupOutcome,
        run: UUID,
        activityFailure: CaptureStartFailurePresentation? = nil
    ) {
        disarmWatchdogs()
        disarmEndPointing()
        // A start that stopped short still reports what it did reach; the
        // stages it never crossed stay absent rather than becoming zeroes.
        diagnostics.finish(outcome, run: run)
        startTime = nil
        sharesLiveTranscript = true
        partialText = ""
        wordCount = 0
        sharedState.clearRecordingState()
        presentation.finish()
        if let activityFailure {
            activityManager.retireFailedActivity(activityFailure)
        } else {
            activityManager.endActivity()
        }
        currentRunParameters = .none
        effectiveConfiguration = nil
        effectiveDestination = nil
        // A capture that never went live completes empty rather than leaving a
        // waiter to fall back on an older run's transcript.
        completeRun(with: "")
        lifecycle.finishStartUnwind()
        state = lifecycle.state
    }
}
#endif
