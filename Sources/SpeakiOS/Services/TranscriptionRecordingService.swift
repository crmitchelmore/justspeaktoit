#if os(iOS)
import Foundation
import UIKit
import SpeakCore

// swiftlint:disable file_length

/// Headless recording coordinator for Action Button / Shortcuts / Siri.
/// Manages the full lifecycle: start recording → live transcription → stop → clipboard → Live Activity.
@MainActor
// swiftlint:disable:next type_body_length
public final class TranscriptionRecordingService: ObservableObject {
    public static let shared = TranscriptionRecordingService()

    /// The service's lifecycle state, mirrored from the run-identity
    /// coordinator after every transition. `isRunning` remains as the
    /// published `recording`-only view for existing observers.
    @Published public private(set) var state: RecordingServiceState = .idle

    /// Whether a stop/toggle has an operation to act on: a live recording or
    /// a startup still in flight (which stop will cancel).
    public var isActive: Bool { lifecycle.isActive }

    @Published public private(set) var isRunning = false
    @Published public private(set) var partialText = ""
    @Published public private(set) var wordCount = 0
    /// Error that ended the most recent session mid-recording. Published so the
    /// app can surface it on next foreground instead of silently losing audio.
    @Published public internal(set) var lastSessionError: Error? {
        didSet {
            // One funnel for every capture failure, so the health screen can
            // report how the last real run ended rather than only what is
            // true this second (issue #997). The journal keeps a closed-set
            // label and a date — never the error's text.
            guard let lastSessionError else { return }
            CaptureOutcomeJournal.record(CaptureOutcomeJournal.outcome(for: lastSessionError))
        }
    }
    /// Non-nil when the session silently fell back to on-device transcription
    /// because the selected cloud model had no API key available.
    @Published public private(set) var providerFallbackNotice: String?

    /// Whether the background polish started by the most recent stop is still
    /// running, and what it produced (issue #1015).
    ///
    /// Published so a returning intent can opt in to waiting for the polished
    /// text instead of handing a Shortcut the raw transcript while the
    /// clipboard is about to hold a different one. `lastPolishedTranscript`
    /// stays `nil` when the polish failed or was never started, which is what
    /// keeps the wait honest: the caller falls back to the raw transcript
    /// rather than being told nothing came back.
    @Published public private(set) var isPostProcessing = false
    @Published public private(set) var lastPolishedTranscript: String?

    private let audioSessionManager = AudioSessionManager()
    private let activityManager = TranscriptionActivityManager.shared
    private let sharedState: SharedTranscriptionState
    private let historyManager: iOSHistoryManager

    private(set) var transcriptionSession: IOSTranscriptionSession?
    private var stoppingSession: IOSTranscriptionSession?
    private var startTime: Date?
    private var currentModel: String = ""
    private var sharesLiveTranscript = true
    private(set) var automaticStopDestination: HardwareTriggerDestination = .clipboard
    private var onCaptureDisruption: (() async -> Void)?
    /// Which trigger started the session in flight, so onboarding can only
    /// mark a trigger proven when a transcript really arrived through it.
    /// `nil` means the caller did not identify itself, and nothing is claimed.
    private var currentTrigger: CaptureTrigger?
    /// Per-run parameter overrides supplied by the surface that started the
    /// session (issue #1013). They travel with the run so every stop path —
    /// the Live Activity button, a Siri stop, a quick action, an interruption
    /// — finishes where the caller asked, not where the global setting says.
    /// `.none` is the pre-parameter behaviour in every respect.
    private var currentRunParameters: CaptureRunParameters = .none
    /// Run-identity state machine for cancellable startup (issue #701); the
    /// pure mechanics live in SpeakCore so they are testable on every
    /// platform. `state` mirrors it for observers.
    private let lifecycle = RecordingLifecycleCoordinator()
    /// Truthful capture presentation (issue #983): startup stays visibly
    /// "preparing" until this run has both started its backend and observed a
    /// buffer from its own live input tap.
    private var presentation = CapturePresentationGate()
    /// Local run-scoped startup timing (issue #972). Measurement only: it adds
    /// no network call, no vendor reporting and no behaviour change.
    private var diagnostics = StartupDiagnostics()
    /// The bounds this run is held to (issue #993). Every rule lives in
    /// SpeakCore's `CaptureWatchdogMonitor`; see
    /// `TranscriptionRecordingService+Watchdogs.swift` for the wiring.
    var watchdog = CaptureWatchdogMonitor()
    var watchdogTask: Task<Void, Never>?
    var watchdogRunID: UUID?
    var watchdogStartedAt: Date?
    /// The armed silence end-pointing monitor's poll loop (issue #1012), or
    /// `nil` when this capture runs until somebody stops it. See
    /// `TranscriptionRecordingService+EndPointing.swift`.
    var endPointingTask: Task<Void, Never>?
    /// Last time the App Group shared state was written for a partial result.
    private var lastSharedStateWriteAt: Date = .distantPast
    private static let sharedStateWriteInterval: TimeInterval = 1.0

    private let polishClipboard: PolishClipboard
    private let hasPolishingKey: @MainActor () -> Bool
    private let polish: @MainActor (String, String, String) async throws -> String
    private var latestCompletionID: UUID?

    private convenience init() {
        self.init(
            sharedState: .shared,
            historyManager: .shared,
            polishClipboard: PolishClipboard(),
            hasPolishingKey: { AppSettings.shared.hasOpenRouterKey },
            polish: { text, model, apiKey in
                try await iOSPostProcessingManager.shared.polish(text: text, model: model, apiKey: apiKey)
            }
        )
    }

    /// Keeps recording lifecycle tests isolated from the real clipboard, History and provider.
    init(
        sharedState: SharedTranscriptionState,
        historyManager: iOSHistoryManager,
        polishClipboard: PolishClipboard,
        hasPolishingKey: @escaping @MainActor () -> Bool,
        polish: @escaping @MainActor (String, String, String) async throws -> String
    ) {
        self.sharedState = sharedState
        self.historyManager = historyManager
        self.polishClipboard = polishClipboard
        self.hasPolishingKey = hasPolishingKey
        self.polish = polish
    }

    /// Picks the first non-blank candidate, else the fallback. Extracted as a
    /// pure function so the stop-time text-selection priority
    /// (result → interim → last-completed) is unit-testable.
    static func bestTranscript(candidates: [String], fallback: String) -> String {
        for candidate in candidates
        where !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return candidate
        }
        return fallback
    }

    private var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    private var modelDisplayName: String {
        ModelCatalog.transcriptionDisplayName(
            for: currentModel,
            isBatch: transcriptionSession?.isBatch
                ?? (AppSettings.shared.transcriptionMode == .batch)
        )
    }

    // MARK: - Public API

    /// Surfaces a refused capture link on the same alert path a failed session
    /// uses, so a link that does nothing says why. The caller is told through
    /// its `x-error` callback; this is the half the user can see.
    public func reportCaptureFailure(_ failure: Error) {
        lastSessionError = failure
    }

    /// Starts a headless recording session with Live Activity.
    ///
    /// `modelOverride` and `languageOverride` are the `model=` and `lang=`
    /// parameters of a capture link, and apply to this session only. Both are
    /// already validated against the catalogues by the caller, so an
    /// unrecognised value never reaches here — it fails the link instead.
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
        onCaptureDisruption: (() async -> Void)? = nil
    ) async throws {
        guard let runID = lifecycle.beginStart() else { return }
        presentation.begin(run: runID)
        diagnostics.begin(run: runID, entry: entry, localOrigin: .service)
        // Armed before the first suspension point, so the start deadline covers
        // the credentials wait as well as the backend start. Every teardown
        // path below disarms it (issue #993).
        armWatchdogs(run: runID, entry: entry)
        state = lifecycle.state
        defer { state = lifecycle.state }

        let settings = AppSettings.shared
        // AppSettings.init publishes empty API keys and loads the real values
        // from the keychain asynchronously. A cold launch from the Action
        // Button could read those empty keys and silently fall back to Apple
        // Speech, so wait for the initial load before resolving the model.
        await settings.ensureKeysLoaded()
        diagnostics.note(.stage(.credentialsReady), run: runID)
        // A stop/cancel during the suspension above retires the run; nothing
        // has been allocated yet, so unwinding only settles the state machine.
        guard lifecycle.isCurrentStartRun(runID) else {
            unwindCancelledStart(outcome: .cancelled, run: runID)
            throw CancellationError()
        }

        lastSessionError = nil
        providerFallbackNotice = nil
        currentTrigger = keyboardProfile == nil ? trigger : .keyboard
        // A model the catalogue only lists for batch transcription cannot run in
        // streaming mode, so an explicit `model=` (from a capture link or a
        // Shortcut) decides the mode rather than being started in a mode it has
        // no client for. `modelSelection` owns that rule for every surface.
        let runParameters = adoptRunParameters(parameters, keyboardProfile: keyboardProfile)
        let selection = Self.modelSelection(
            keyboardProfile: keyboardProfile,
            parameters: runParameters,
            settings: settings
        )
        let usesBatchTranscription = selection.usesBatch
        currentModel = selection.modelID
        partialText = ""
        wordCount = 0
        lastSharedStateWriteAt = .distantPast
        startTime = Date()
        self.sharesLiveTranscript = sharesLiveTranscript
        // Explicit internal destination beats the override the run carried,
        // which beats the global setting (issue #1013).
        self.automaticStopDestination = destination
            ?? runDestinationOverride
            ?? settings.hardwareTriggerDestination
        self.onCaptureDisruption = onCaptureDisruption
        sharedState.clear()
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime

        if !usesBatchTranscription && keyboardProfile == nil {
            try resolveLiveModelHonouringRequest(
                settings: settings,
                requestedModelID: runParameters.modelID,
                run: runID
            )
        }

        // A Live Activity is required to record in the *background* via an
        // AudioRecordingIntent — without one the AppIntents system-policy check
        // asserts (EXC_BREAKPOINT). In the foreground a Live Activity is optional,
        // so only enforce this when the app isn't active.
        let appIsActive = UIApplication.shared.applicationState == .active
        let activityProvider = providerFallbackNotice == nil
            ? modelDisplayName
            : "\(modelDisplayName) (no API key)"
        let activityStarted = (requiresLiveActivity || appIsActive)
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

        var startedSession: IOSTranscriptionSession?
        do {
            let mode: IOSTranscriptionSession.Mode = usesBatchTranscription
                ? .batch(retainRecording: retainBatchRecording)
                : .streaming
            let languageIdentifier = keyboardProfile?.languageIdentifier
                ?? runParameters.languageIdentifier
                ?? settings.preferredLocaleIdentifier
            let session = try IOSTranscriptionSession(
                modelID: currentModel,
                mode: mode,
                language: TranscriptionLanguageCatalog.providerLanguage(for: languageIdentifier),
                audioSessionManager: audioSessionManager,
                batchAPIKey: settings.batchAPIKey(for: currentModel),
                liveAPIKey: settings.liveAPIKey(for:),
                transcriptionKeywords: MetaMuseVoiceTranscribe.keywords(from: settings.transcriptionKeywords)
            )
            session.onPartialResult = { [weak self, weak session] text, isFinal in
                guard let self, let session,
                      self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session
                        || self.stoppingSession === session else { return }
                self.noteFirstLivePartial(text: text, isFinal: isFinal, runID: runID)
                self.handlePartialResult(text: text)
            }
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
            try await session.start()
            diagnostics.note(.stage(.sessionStarted), run: runID)
            // The session this run allocated is published only while the run
            // is still current; a stop during start() retires the run, and the
            // cleanup below tears down exactly what this run owns without
            // touching any replacement run's session (issue #701).
            guard lifecycle.activate(runID) else {
                session.cancel()
                unwindCancelledStart(outcome: .cancelled, run: runID)
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
            unwindCancelledStart(outcome: outcome(for: error), run: runID)
            throw error
        }
    }

    /// Stores the overrides this run will carry, and logs them so a capture's
    /// parameters are recoverable after the fact.
    ///
    /// The keyboard carries its own profile and never takes intent parameters,
    /// so a keyboard run stores none.
    @discardableResult
    private func adoptRunParameters(
        _ parameters: CaptureRunParameters,
        keyboardProfile: KeyboardDictationProfileOption?
    ) -> CaptureRunParameters {
        let adopted = keyboardProfile == nil ? parameters : .none
        currentRunParameters = adopted
        if !adopted.isEmpty {
            SpeakLogger.transcription.info(
                "Capture parameters: \(adopted.logDescription, privacy: .public)"
            )
        }
        return adopted
    }

    /// Which model this run uses and whether it has to run in batch mode.
    ///
    /// Precedence: the keyboard's own profile, then the caller's per-run
    /// parameters, then the configured settings. A batch-only model forces
    /// batch mode; a live-capable one leaves the configured mode alone.
    private static func modelSelection(
        keyboardProfile: KeyboardDictationProfileOption?,
        parameters: CaptureRunParameters,
        settings: AppSettings
    ) -> (modelID: String, usesBatch: Bool) {
        let usesBatch = keyboardProfile?.transcriptionMode == .batch
            || (keyboardProfile == nil
                && (parameters.requiresBatchMode || settings.transcriptionMode == .batch))
        let modelID = keyboardProfile?.transcriptionModelIdentifier
            ?? parameters.modelID
            ?? (usesBatch ? settings.batchTranscriptionModel : settings.selectedModel)
        return (modelID, usesBatch)
    }

    /// Resolves the live model, refusing a silent substitution when the caller
    /// asked for a specific one.
    ///
    /// The configured model may fall back to on-device when its key is
    /// missing. That is acceptable for the global setting — it is the app's
    /// own choice and `providerFallbackNotice` publishes it — but a caller
    /// that *named* a model has to be told, not handed a different one it
    /// cannot see.
    private func resolveLiveModelHonouringRequest(
        settings: AppSettings,
        requestedModelID: String?,
        run: UUID
    ) throws {
        let substituted = resolveLiveModel(settings: settings)
        guard substituted, requestedModelID != nil else { return }
        unwindCancelledStart(outcome: .failed, run: run)
        throw CaptureParameterFailure.modelUnavailable
    }

    /// - Returns: whether the resolved model differs from the requested one,
    ///   i.e. whether a silent substitution happened.
    @discardableResult
    private func resolveLiveModel(settings: AppSettings) -> Bool {
        let requestedModel = currentModel
        let route = LiveTranscriptionRouting.route(for: currentModel)
        currentModel = LiveTranscriptionRouting.resolvedModelID(
            for: currentModel,
            apiKey: route.map { settings.liveAPIKey(for: $0) }
        )
        if currentModel != requestedModel {
            // Make the silent on-device fallback visible: publish it for
            // the UI and log it so a "worse than usual" session is
            // diagnosable.
            providerFallbackNotice = "Using \(modelDisplayName) (no API key)"
            SpeakLogger.transcription.warning(
                """
                No API key for \(requestedModel, privacy: .public); \
                falling back to \(self.currentModel, privacy: .public)
                """
            )
            return true
        }
        return false
    }

    /// The destination a stop should use.
    ///
    /// Explicit beats remembered beats global (issue #1013): a Stop that names
    /// a destination wins, otherwise the override the *start* carried travels
    /// with the run, and only then does the one global setting apply. Every
    /// stop path goes through this, so an interruption, a Live Activity button
    /// and the in-app stop all agree.
    public func resolvedStopDestination(
        explicit: HardwareTriggerDestination? = nil
    ) -> HardwareTriggerDestination {
        let identifier = CaptureParameterResolution.stopDestinationID(
            explicit: explicit?.rawValue,
            runOverride: currentRunParameters.destinationID,
            global: AppSettings.shared.hardwareTriggerDestination.rawValue
        )
        return HardwareTriggerDestination(rawValue: identifier)
            ?? AppSettings.shared.hardwareTriggerDestination
    }

    /// The destination the running capture was started with, or `nil` when the
    /// caller did not override it. Callers that must preserve the legacy
    /// "no destination given" default pass this straight through.
    public var runDestinationOverride: HardwareTriggerDestination? {
        currentRunParameters.destinationID.flatMap(HardwareTriggerDestination.init(rawValue:))
    }

    /// Reverts everything a cancelled startup run had published: timing,
    /// shared App Group recording state and the Live Activity. The run calls
    /// this itself so ownership never crosses runs.
    private func unwindCancelledStart(outcome: StartupOutcome, run: UUID) {
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
        activityManager.endActivity()
        currentRunParameters = .none
        lifecycle.finishStartUnwind()
        state = lifecycle.state
    }

    /// Stops recording, applies the requested result destination, and returns the result.
    ///
    /// - Parameter destination: Where the transcript should go. When `nil`, defaults
    ///   to `.clipboardAndPostProcess` if the user has post-processing turned on,
    ///   else `.clipboard` — i.e., the original behaviour before destinations
    ///   were configurable. Hardware-trigger callers (Action Button, Siri,
    ///   Shortcuts) pass `AppSettings.shared.hardwareTriggerDestination`.
    @discardableResult
    // swiftlint:disable:next function_body_length
    public func stopRecording(
        destination: HardwareTriggerDestination? = nil,
        saveToHistory: Bool = true,
        primedActivityMessage: String = "Ready for the Action Button"
    ) async -> TranscriptionResult {
        // Disarmed first, before anything can suspend: a monitor that is still
        // polling while this stop runs would find the session gone and do
        // nothing, but cancelling here means it cannot even observe the
        // teardown. The auto-stop path re-enters this method, and the
        // reentrancy guard below is what makes that safe either way.
        disarmEndPointing()

        // A stop during startup cancels the pending run and waits for it to
        // unwind (issue #701): retiring `activeStartRunID` makes the suspended
        // start release everything it allocated instead of activating the
        // microphone after the user asked to stop.
        if lifecycle.state == .starting {
            lifecycle.retireStartRun()
            await lifecycle.awaitStartSettled()
            state = lifecycle.state
            return TranscriptionResult(
                text: "",
                segments: [],
                confidence: nil,
                duration: 0,
                modelIdentifier: currentModel,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }

        // Reentrancy guard: a rapid double-stop (e.g. double Action Button
        // press) must not produce a second history entry or clobber the
        // clipboard with stale text. Return an empty no-op result instead.
        guard lifecycle.beginStopping() else {
            return TranscriptionResult(
                text: "",
                segments: [],
                confidence: nil,
                duration: 0,
                modelIdentifier: currentModel,
                cost: nil,
                rawPayload: nil,
                debugInfo: nil
            )
        }
        state = lifecycle.state
        isRunning = false
        presentation.finish()
        diagnostics.retire()
        disarmWatchdogs()
        let duration = elapsedSeconds
        let completionID = UUID()
        latestCompletionID = completionID

        // Keep the (often headless / backgrounded) process alive long enough for
        // the clipboard write — and any post-processing — to actually commit.
        // Short recordings were being suspended before the pasteboard flush
        // landed, so "Copied N words" was reported but nothing arrived.
        let assertion = beginBackgroundAssertion("Finalise transcription")

        if transcriptionSession?.isBatch == true {
            activityManager.updateActivity(
                status: .processing,
                lastSnippet: "Transcribing recording…",
                wordCount: 0,
                duration: duration
            )
        }

        let drained = await drainActiveTranscriber(duration: duration)
        startTime = nil

        // Use the best available text and make the returned result, the history
        // entry, the clipboard, and the spoken dialog all agree on it.
        let text = bestAvailableText(from: drained)
        let result = drained.replacingText(text)
        // Onboarding progress is earned by evidence only: an unidentified
        // caller, or a run that produced no text, proves nothing.
        if let currentTrigger {
            CaptureOnboardingStore.shared.recordDictation(trigger: currentTrigger, transcript: text)
        }
        currentTrigger = nil
        // The overrides belong to the run that just ended; the next capture
        // starts from the global settings again unless it brings its own.
        currentRunParameters = .none
        partialText = text
        wordCount = text.split(whereSeparator: \.isWhitespace).count

        // Specialized callers may opt out when their result is intentionally transient.
        let historyItem = saveToHistory
            ? historyManager.recordTranscription(
                text: text,
                model: currentModel,
                duration: result.duration
            )
            : nil

        // Resolve the destination. When nil (legacy callers), preserve the
        // pre-destination behaviour: clipboard + post-process if user opted in.
        let resolvedDestination: HardwareTriggerDestination = destination ?? .clipboard
        let receipt = applyDestinationSideEffects(text: text, destination: resolvedDestination)

        // The transcript has landed, so this capture's safety audio no longer
        // needs recovering (issue #992). Marking it here rather than at stop is
        // deliberate: a kill anywhere above this line leaves the claim
        // un-delivered and the recording offered back on the next launch.
        CaptureSafetyClaimStore.shared.markDeliveredForThisProcess()
        if lastSessionError == nil {
            CaptureOutcomeJournal.record(text.isEmpty ? .cancelled : .delivered)
        }

        // Update shared state. Live writes are throttled, so commit the
        // complete transcript exactly once at stop.
        if sharesLiveTranscript {
            sharedState.updateTranscript(text)
        }
        sharedState.clearRecordingState()
        sharesLiveTranscript = true

        // Complete Live Activity with clipboard confirmation
        completeRecordingActivity(
            duration: duration,
            primedMessage: lastSessionError?.localizedDescription ?? primedActivityMessage
        )

        // Kick off background post-processing if the chosen destination + user
        // settings call for it. The polished clipboard write must also survive
        // process suspension, so the background assertion is released only once
        // post-processing has finished.
        // A new stop supersedes whatever the previous one polished, so an
        // intent that waits can never be handed the run before last's text.
        lastPolishedTranscript = nil
        if shouldPostProcess(destination: resolvedDestination, isLegacyCaller: destination == nil)
            && !text.isEmpty {
            if let historyItem {
                historyManager.beginPostProcessing(for: historyItem.id)
            }
            // Published so a returning intent can wait for the polished text
            // instead of being handed the raw transcript (issue #1015).
            isPostProcessing = true
            startPostProcessing(
                text: text,
                historyItemID: historyItem?.id,
                completionID: completionID,
                receipt: receipt,
                assertion: assertion
            )
        } else {
            isPostProcessing = false
            assertion.end()
        }

        // Clear per-session live state so a duplicate stop or a later fallback
        // path can never resurface this session's text.
        partialText = ""
        wordCount = 0

        lifecycle.finishStopping()
        state = lifecycle.state
        return result
    }

    private func completeRecordingActivity(duration: Int, primedMessage: String) {
        activityManager.completeActivity(
            finalWordCount: wordCount,
            duration: duration,
            keepPrimed: true,
            primedMessage: primedMessage
        )
    }

    /// Cancels recording without saving. During startup this retires the
    /// pending run and cancels its allocated provider immediately. The owned
    /// startup task unwinds before another run can begin (issues #701, #786).
    public func cancelRecording() {
        // A completed recording's polish has its own lifetime. Cancelling a
        // subsequent capture must not cancel that work or invalidate its result.
        if lifecycle.state == .stopping {
            latestCompletionID = nil
            // The current finalisation keeps ownership until its drain ends.
            // A replacement must not start while it can still publish output.
            return
        }
        currentTrigger = nil
        disarmEndPointing()
        if lifecycle.state == .starting {
            lifecycle.retireStartRun()
            return
        }
        transcriptionSession?.cancel()
        transcriptionSession = nil
        sharesLiveTranscript = true
        isRunning = false
        presentation.finish()
        diagnostics.retire()
        disarmWatchdogs()
        startTime = nil
        partialText = ""
        wordCount = 0
        sharedState.clearRecordingState()
        activityManager.endActivity()
        lifecycle.finishStopping()
        state = lifecycle.state
    }

    // MARK: - Private

    private func handlePartialResult(text: String) {
        partialText = text

        // App Group writes (plist + cfprefsd IPC) and word counting are O(n)
        // per partial; throttle them to ~1/s, mirroring the Live Activity
        // manager's own update throttle. The full transcript is committed
        // once more at stop.
        let now = Date()
        if now.timeIntervalSince(lastSharedStateWriteAt) >= Self.sharedStateWriteInterval {
            lastSharedStateWriteAt = now
            wordCount = text.split(separator: " ").count
            if sharesLiveTranscript {
                sharedState.updateTranscript(text)
            }
        }

        // Presentation only: the transcript above is delivered either way. A
        // partial can arrive from pre-roll before this run has seen its own
        // input, and it must not announce active capture (issue #983).
        guard presentation.isPresentingCapture else {
            publishPreparingActivity()
            return
        }
        activityManager.updateActivity(
            status: .listening,
            lastSnippet: text,
            wordCount: wordCount,
            duration: elapsedSeconds
        )
    }

    /// Wires this run to the session's existing observation boundary, and
    /// labels the backend when routing already settled it (issue #972).
    private func bindStartupDiagnostics(session: IOSTranscriptionSession, runID: UUID) {
        session.onStartupObservation = { [weak self] observation in
            self?.diagnostics.note(observation, run: runID)
            // Same seam, not a second one: the watchdogs' start deadline and
            // no-audio detector are driven by the boundaries issue #972
            // already reports (issue #993).
            if case .stage(let stage) = observation {
                self?.noteWatchdogStage(stage, run: runID)
            }
        }
        if let backend = session.resolution.resolvedStartupBackend {
            diagnostics.note(.backend(backend), run: runID)
        }
    }

    /// The measured boundary is the first *live* partial: a final result is a
    /// delivery, not evidence that streaming began.
    private func noteFirstLivePartial(text: String, isFinal: Bool, runID: UUID) {
        guard !isFinal, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        diagnostics.noteFirstPartial(run: runID)
    }

    /// Explicitly synthetic: the DEBUG simulator stub has no audio session, no
    /// engine and no measured engine start.
    private func noteSimulatorStubStartup(runID: UUID) {
        diagnostics.note(.backend(.simulatorStub), run: runID)
        diagnostics.finish(.started, run: runID)
    }

    private func outcome(for error: Error) -> StartupOutcome {
        (error is CancellationError || Task.isCancelled) ? .cancelled : .failed
    }

    /// Routes this run's own first live buffer into the presentation gate.
    private func bindFirstInput(session: IOSTranscriptionSession, runID: UUID) {
        session.onFirstInputBuffer = { [weak self, weak session] in
            guard let self, let session,
                  self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session
            else { return }
            self.notePresentation(self.presentation.noteInputObserved(run: runID))
            // The no-audio detector consumes issue #983's first-input signal
            // rather than installing a tap of its own (issue #993).
            self.noteWatchdogInputObserved(run: runID)
        }
    }

    /// Publishes the one arming → recording transition, and only that one.
    private func notePresentation(_ promoted: Bool) {
        guard promoted else { return }
        activityManager.updateActivity(
            status: .recording,
            lastSnippet: partialText,
            wordCount: wordCount,
            duration: elapsedSeconds
        )
    }

    /// Keeps preparation truthful: no snippet, no elapsed time, no recording
    /// indicator until this run's own tap has delivered.
    private func publishPreparingActivity() {
        activityManager.updateActivity(
            status: .arming,
            lastSnippet: CapturePresentationGate.preparingMessage,
            wordCount: 0,
            duration: 0
        )
    }

    private func handleError(_ error: Error, session: IOSTranscriptionSession) {
        activityManager.reportError(error.localizedDescription)

        // A mid-session failure previously only updated the Live Activity —
        // the mic stayed hot while the user dictated into a dead session.
        // Tear the session down, preserving the accumulated transcript, and
        // publish the error so the app can surface it on next foreground.
        guard lifecycle.state == .recording || stoppingSession === session else { return }
        lastSessionError = error
        guard lifecycle.state == .recording else { return }
        Task { [weak self] in
            guard let self, self.isRunning, self.transcriptionSession === session else { return }
            // `automaticStopDestination` already folds in the run's override,
            // so a parameterised capture still finishes where it was told to.
            await self.finishCaptureAfterDisruption()
        }
    }

    /// Finishes through the originating owner, which may own a keyboard nonce
    /// rather than a clipboard destination. Stop's lifecycle guard claims once.
    func finishCaptureAfterDisruption(stoppedMessage: String = "Recording stopped") async {
        guard lifecycle.state == .recording else { return }
        if let finishOwnedCapture = onCaptureDisruption {
            await finishOwnedCapture()
            return
        }
        await stopRecording(
            destination: automaticStopDestination,
            primedActivityMessage: lastSessionError?.localizedDescription ?? stoppedMessage
        )
    }

    private func startPostProcessing(
        text: String,
        historyItemID: UUID?,
        completionID: UUID,
        receipt: PolishClipboard.Receipt?,
        assertion: BackgroundTaskAssertion
    ) {
        let settings = AppSettings.shared
        let model = settings.postProcessingModel
        let apiKey = settings.openRouterAPIKey
        let historyManager = self.historyManager
        let polish = self.polish
        let operation = AutomaticPolishOperation(
            clipboard: polishClipboard,
            receipt: receipt,
            isCurrent: { [weak self] in self?.latestCompletionID == completionID },
            success: { [weak self] polished, current in
                if current {
                    self?.sharedState.lastCompletedTranscript = polished
                    // Only the current run's polish may be waited on; an
                    // superseded one must not hand back the run before last.
                    self?.lastPolishedTranscript = polished
                }
                if let historyItemID {
                    historyManager.setPostProcessed(polished, for: historyItemID)
                }
            },
            failure: { error in
                if let historyItemID {
                    historyManager.setError(error.localizedDescription, for: historyItemID)
                }
            },
            completion: { [weak self] in
                if let historyItemID {
                    historyManager.endPostProcessing(for: historyItemID)
                }
                self?.isPostProcessing = false
                assertion.end()
            }
        )
        operation.start(under: assertion, isActive: UIApplication.shared.applicationState == .active) {
            try await polish(text, model, apiKey)
        }
    }
}

// MARK: - Stop helpers

@MainActor
extension TranscriptionRecordingService {
    /// Raw text is usable immediately, including while polishing or without a key.
    static func clipboardTextAtStop(
        transcript: String,
        destination: HardwareTriggerDestination
    ) -> String? {
        guard !transcript.isEmpty else { return nil }
        switch destination {
        case .clipboard, .clipboardAndPostProcess:
            return transcript
        case .historyOnly:
            return nil
        }
    }

    static func legacySharedTranscript(_ transcript: String, sharesCompletedTranscript: Bool) -> String? {
        sharesCompletedTranscript ? transcript : nil
    }

    /// Waits, at most `timeout` seconds, for the background polish started by
    /// the stop that just happened, and returns what it produced.
    ///
    /// Returns `nil` — meaning "use the raw transcript" — in every case the
    /// polish did not deliver: no polish was started, it failed, it produced
    /// nothing, or it is still running when the budget runs out. It never
    /// returns a placeholder and never blocks past the deadline, because an
    /// intent the system kills for overrunning returns nothing at all, which
    /// is worse than the raw text.
    ///
    /// Polls rather than observes, matching the wait in `DictateIntent`: the
    /// polish runs in a detached `Task` whose completion this actor sees only
    /// through `isPostProcessing`.
    func awaitPolishedTranscript(timeout: TimeInterval) async -> String? {
        guard timeout > 0 else { return nil }
        let deadline = Date().addingTimeInterval(timeout)
        while isPostProcessing, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return isPostProcessing ? nil : lastPolishedTranscript
    }
}

private extension TranscriptionRecordingService {
    /// Stops whichever transcriber is currently active and returns its result.
    /// Falls back to a synthetic `TranscriptionResult` built from `partialText`
    /// if no transcriber is wired up (defensive — shouldn't happen in practice).
    ///
    /// We null out the transcriber property **before** awaiting `stop()` to be
    /// safe under `@MainActor` reentrancy: a rapid double-press of the Action
    /// Button can re-enter `stopRecording` while the first stop is suspended,
    /// and otherwise both calls would see the same non-nil transcriber and try
    /// to stop it twice.
    func drainActiveTranscriber(duration: Int) async -> TranscriptionResult {
        if let session = transcriptionSession {
            transcriptionSession = nil
            stoppingSession = session
            defer { stoppingSession = nil }
            do {
                guard let result = try await boundedStop(of: session) else {
                    return timedOutFinalisationResult(for: session, duration: duration)
                }
                return result
            } catch {
                handleError(error, session: session)
                return TranscriptionResult(
                    text: "",
                    segments: [],
                    confidence: nil,
                    duration: TimeInterval(duration),
                    modelIdentifier: currentModel,
                    cost: nil,
                    rawPayload: nil,
                    debugInfo: nil
                )
            }
        }
        return TranscriptionResult(
            text: partialText,
            segments: [],
            confidence: nil,
            duration: TimeInterval(duration),
            modelIdentifier: currentModel,
            cost: nil,
            rawPayload: nil,
            debugInfo: nil
        )
    }

    /// Applies the destination's side-effects (clipboard write, shared state
    /// update). History recording is handled by the caller because it always
    /// happens regardless of destination.
    func applyDestinationSideEffects(
        text: String,
        destination: HardwareTriggerDestination,
        sharesCompletedTranscript: Bool? = nil
    ) -> PolishClipboard.Receipt? {
        guard !text.isEmpty else { return nil }
        var receipt: PolishClipboard.Receipt?
        if let clipboardText = Self.clipboardTextAtStop(
            transcript: text,
            destination: destination
        ) {
            receipt = polishClipboard.copyRaw(clipboardText)
        }

        // Keyboard handoffs keep their result solely in the nonce-scoped store.
        // Other destinations publish the completed transcript so the Live
        // Activity and foreground handoff can surface it.
        if let sharedTranscript = Self.legacySharedTranscript(
            text,
            sharesCompletedTranscript: sharesCompletedTranscript ?? sharesLiveTranscript
        ) {
            sharedState.lastCompletedTranscript = sharedTranscript
        }
        return receipt
    }

    /// The most complete transcript we can produce at stop time. The transcriber
    /// result is preferred, but for very short recordings the provider may return
    /// empty while interim text is still held in `partialText` — falling back
    /// there keeps the clipboard and dialog honest. We deliberately do NOT fall
    /// back to the last completed transcript: a silent new session must stay
    /// empty rather than re-emitting the previous recording's text.
    func bestAvailableText(from result: TranscriptionResult) -> String {
        TranscriptionRecordingService.bestTranscript(
            candidates: [result.text, partialText],
            fallback: result.text
        )
    }

    /// Begins a finite-length background assertion so a headless / backgrounded
    /// process isn't suspended before the clipboard (and any post-processing)
    /// write commits. The returned object ends the task exactly once.
    func beginBackgroundAssertion(_ name: String) -> BackgroundTaskAssertion {
        BackgroundTaskAssertion(name: name)
    }

    /// Decides whether to run the background post-processor.
    ///
    /// Two paths trigger it:
    /// 1. Legacy callers (no explicit destination) honour the global
    ///    `autoPostProcess` toggle for backwards compatibility.
    /// 2. Hardware-trigger callers explicitly choose `.clipboardAndPostProcess`.
    func shouldPostProcess(
        destination: HardwareTriggerDestination,
        isLegacyCaller: Bool
    ) -> Bool {
        let settings = AppSettings.shared
        switch destination {
        case .clipboardAndPostProcess:
            return hasPolishingKey()
        case .clipboard:
            return isLegacyCaller && settings.autoPostProcess && hasPolishingKey()
        case .historyOnly:
            return false
        }
    }
}

extension TranscriptionResult {
    /// Returns a copy with `text` replaced, preserving all other metadata. Used
    /// so the returned result, history entry, clipboard, and spoken dialog all
    /// agree on the same best-available transcript.
    func replacingText(_ newText: String) -> TranscriptionResult {
        TranscriptionResult(
            text: newText,
            segments: segments,
            confidence: confidence,
            duration: duration,
            modelIdentifier: modelIdentifier,
            cost: cost,
            rawPayload: rawPayload,
            debugInfo: debugInfo
        )
    }
}

/// Reference-type wrapper around a UIKit background-task assertion that
/// guarantees `endBackgroundTask` is called exactly once — whether via the
/// normal completion path or the system expiration handler — avoiding the
/// double-end API violation.
@MainActor
final class BackgroundTaskAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var ended = false
    private var expired = false
    private let endTask: @MainActor (UIBackgroundTaskIdentifier) -> Void
    var isValid: Bool { !ended && identifier != .invalid }
    var onExpiration: (() -> Void)? {
        didSet {
            if expired { onExpiration?() }
        }
    }

    init(
        name: String,
        begin: @MainActor (String, @escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: $0, expirationHandler: $1)
        },
        end: @escaping @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
    ) {
        endTask = end
        let allocated = begin(name) { [weak self] in
            guard let self else { return }
            self.expired = true
            self.onExpiration?()
            self.end()
        }
        // Expiration can arrive before begin returns its identifier.
        if ended {
            if allocated != .invalid { endTask(allocated) }
        } else {
            identifier = allocated
        }
    }

    func end() {
        guard !ended else { return }
        ended = true
        onExpiration = nil
        if identifier != .invalid { endTask(identifier) }
        identifier = .invalid
    }
}
#endif
