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
    @Published public private(set) var lastSessionError: Error?
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
    private let sharedState = SharedTranscriptionState.shared

    private(set) var transcriptionSession: IOSTranscriptionSession?
    private var startTime: Date?
    private var currentModel: String = ""
    private var sharesLiveTranscript = true
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
    /// The armed silence end-pointing monitor's poll loop (issue #1012), or
    /// `nil` when this capture runs until somebody stops it. See
    /// `TranscriptionRecordingService+EndPointing.swift`.
    var endPointingTask: Task<Void, Never>?
    /// Last time the App Group shared state was written for a partial result.
    private var lastSharedStateWriteAt: Date = .distantPast
    private static let sharedStateWriteInterval: TimeInterval = 1.0

    static let polishingClipboardPlaceholder = "Polishing… please wait"

    private init() {}

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

    /// Starts a headless recording session with Live Activity.
    public func startRecording( // swiftlint:disable:this function_body_length
        retainBatchRecording: Bool = true,
        sharesLiveTranscript: Bool = true,
        requiresLiveActivity: Bool = true,
        keyboardProfile: KeyboardDictationProfileOption? = nil,
        trigger: CaptureTrigger? = nil,
        parameters: CaptureRunParameters = .none,
        endPointing: CaptureEndPointingRequest? = nil
    ) async throws {
        guard let runID = lifecycle.beginStart() else { return }
        state = lifecycle.state
        defer { state = lifecycle.state }

        let settings = AppSettings.shared
        // AppSettings.init publishes empty API keys and loads the real values
        // from the keychain asynchronously. A cold launch from the Action
        // Button could read those empty keys and silently fall back to Apple
        // Speech, so wait for the initial load before resolving the model.
        await settings.ensureKeysLoaded()
        // A stop/cancel during the suspension above retires the run; nothing
        // has been allocated yet, so unwinding only settles the state machine.
        guard lifecycle.isCurrentStartRun(runID) else {
            unwindCancelledStart()
            throw CancellationError()
        }

        lastSessionError = nil
        providerFallbackNotice = nil
        currentTrigger = keyboardProfile == nil ? trigger : .keyboard
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
        sharedState.clear()
        sharedState.isRecording = true
        sharedState.recordingStartTime = startTime

        if !usesBatchTranscription && keyboardProfile == nil {
            try resolveLiveModelHonouringRequest(
                settings: settings,
                requestedModelID: runParameters.modelID
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
            ? activityManager.startActivity(provider: activityProvider)
            : false
        if requiresLiveActivity && !activityStarted && !appIsActive {
            unwindCancelledStart()
            throw iOSTranscriptionError.liveActivityUnavailable
        }

        #if DEBUG && targetEnvironment(simulator)
        if let transcript = sharedState.simulatorValidationTranscript {
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
            session.onPartialResult = { [weak self, weak session] text, _ in
                guard let self, let session,
                      self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session else { return }
                self.handlePartialResult(text: text)
            }
            session.onError = { [weak self, weak session] error in
                guard let self, let session,
                      self.lifecycle.isCurrentStartRun(runID) || self.transcriptionSession === session else { return }
                self.handleError(error)
            }
            startedSession = session
            guard lifecycle.installStartCancellation(for: runID, cancel: { session.cancel() }) else {
                throw CancellationError()
            }
            try await session.start()
            // The session this run allocated is published only while the run
            // is still current; a stop during start() retires the run, and the
            // cleanup below tears down exactly what this run owns without
            // touching any replacement run's session (issue #701).
            guard lifecycle.activate(runID) else {
                session.cancel()
                unwindCancelledStart()
                throw CancellationError()
            }
            transcriptionSession = session
            isRunning = true
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
            unwindCancelledStart()
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
        requestedModelID: String?
    ) throws {
        let substituted = resolveLiveModel(settings: settings)
        guard substituted, requestedModelID != nil else { return }
        unwindCancelledStart()
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
    private func unwindCancelledStart() {
        disarmEndPointing()
        startTime = nil
        sharesLiveTranscript = true
        partialText = ""
        wordCount = 0
        sharedState.clearRecordingState()
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
        let duration = elapsedSeconds

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
            ? iOSHistoryManager.shared.recordTranscription(
                text: text,
                model: currentModel,
                duration: result.duration
            )
            : nil

        // Resolve the destination. When nil (legacy callers), preserve the
        // pre-destination behaviour: clipboard + post-process if user opted in.
        let resolvedDestination: HardwareTriggerDestination = destination ?? .clipboard
        await applyDestinationSideEffects(text: text, destination: resolvedDestination)

        // Update shared state. Live writes are throttled, so commit the
        // complete transcript exactly once at stop.
        if sharesLiveTranscript {
            sharedState.updateTranscript(text)
        }
        sharedState.clearRecordingState()
        sharesLiveTranscript = true

        // Complete Live Activity with clipboard confirmation
        completeRecordingActivity(duration: duration, primedMessage: primedActivityMessage)

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
                iOSHistoryManager.shared.beginPostProcessing(for: historyItem.id)
            }
            isPostProcessing = true
            Task { [resolvedDestination, assertion] in
                await postProcess(
                    text: text,
                    historyItemID: historyItem?.id,
                    replacingClipboard: resolvedDestination != .historyOnly
                )
                isPostProcessing = false
                assertion.end()
            }
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

        activityManager.updateActivity(
            status: .listening,
            lastSnippet: text,
            wordCount: wordCount,
            duration: elapsedSeconds
        )
    }

    private func handleError(_ error: Error) {
        activityManager.reportError(error.localizedDescription)

        // A mid-session failure previously only updated the Live Activity —
        // the mic stayed hot while the user dictated into a dead session.
        // Tear the session down, preserving the accumulated transcript, and
        // publish the error so the app can surface it on next foreground.
        guard lifecycle.state == .recording else { return }
        lastSessionError = error
        Task { [weak self] in
            guard let self, self.isRunning else { return }
            await self.stopRecording(
                // Nil when the run carried no override, which keeps the
                // pre-existing default for an unparameterised session.
                destination: self.runDestinationOverride,
                primedActivityMessage: "Stopped: \(error.localizedDescription)"
            )
        }
    }

    private func postProcess(
        text: String,
        historyItemID: UUID?,
        replacingClipboard: Bool = true
    ) async {
        let settings = AppSettings.shared
        let processor = iOSPostProcessingManager.shared

        do {
            let polished = try await processor.polish(
                text: text,
                model: settings.postProcessingModel,
                apiKey: settings.openRouterAPIKey
            )
            guard !polished.isEmpty else { throw PostProcessingError.emptyResult }
            if replacingClipboard {
                await Self.writeClipboardReliably(polished)
            }
            lastPolishedTranscript = polished
            sharedState.lastCompletedTranscript = polished
            if let historyItemID {
                iOSHistoryManager.shared.setPostProcessed(polished, for: historyItemID)
            }
        } catch {
            // Never strand the user with the temporary polishing message.
            if replacingClipboard {
                await Self.writeClipboardReliably(text)
            }
            if let historyItemID {
                iOSHistoryManager.shared.setError(error.localizedDescription, for: historyItemID)
                iOSHistoryManager.shared.endPostProcessing(for: historyItemID)
            }
        }
    }
}

// MARK: - Stop helpers

@MainActor
extension TranscriptionRecordingService {
    /// The pasteboard value that should be committed synchronously when the
    /// recording stops. Polishing gets a non-sensitive placeholder only when a
    /// post-processor can actually replace it; without a key, the raw transcript
    /// must be copied instead of leaving "Polishing… please wait" forever.
    static func clipboardTextAtStop(
        transcript: String,
        destination: HardwareTriggerDestination,
        canPostProcess: Bool
    ) -> String? {
        switch destination {
        case .clipboard:
            return transcript
        case .clipboardAndPostProcess:
            return canPostProcess ? polishingClipboardPlaceholder : transcript
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
            do {
                return try await session.stop()
            } catch {
                handleError(error)
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
    ) async {
        guard !text.isEmpty else { return }
        if let clipboardText = Self.clipboardTextAtStop(
            transcript: text,
            destination: destination,
            canPostProcess: AppSettings.shared.hasOpenRouterKey
        ) {
            await Self.writeClipboardReliably(clipboardText)
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
    }

    /// Pasteboard writes from a background AppIntent can race process
    /// suspension. Verify the value and retry briefly before reporting success.
    static func writeClipboardReliably(_ text: String) async {
        for attempt in 0..<3 {
            UIPasteboard.general.string = text
            await Task.yield()
            if UIPasteboard.general.string == text { return }
            if attempt < 2 {
                try? await Task.sleep(for: .milliseconds(80))
            }
        }
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
            return settings.hasOpenRouterKey
        case .clipboard:
            return isLegacyCaller && settings.autoPostProcess && settings.hasOpenRouterKey
        case .historyOnly:
            return false
        }
    }
}

private extension TranscriptionResult {
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

    init(name: String) {
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif
