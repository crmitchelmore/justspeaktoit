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
    @Published public internal(set) var state: RecordingServiceState = .idle

    /// Whether a stop/toggle has an operation to act on: a live recording or
    /// a startup still in flight (which stop will cancel).
    public var isActive: Bool { lifecycle.isActive }

    @Published public internal(set) var isRunning = false
    @Published public internal(set) var partialText = ""
    @Published public internal(set) var wordCount = 0
    /// Nonfatal audio-loss notice, separate from errors that stop recording.
    @Published public internal(set) var recordingWarning: String?
    var recordingWarningRunID = UUID()
    /// Error that ended the most recent session mid-recording. Published so the
    /// app can surface it on next foreground instead of silently losing audio.
    @Published public internal(set) var lastSessionError: Error? {
        didSet {
            // Every publication gets a fresh identity, including one that
            // repeats an earlier failure word for word — a presenter that
            // de-duplicated on the message would swallow the later one, with no
            // intervening `nil` to tell the two apart (#1084).
            let token = lastSessionError == nil ? nil : UUID()
            requestDiagnostics.publish(pendingIssueFailure, token: token)
            pendingIssueFailure = nil
            sessionErrorToken = token
            // One funnel for every capture failure, so the health screen can
            // report how the last real run ended rather than only what is
            // true this second (issue #997). The journal keeps a closed-set
            // label, local diagnostic code and a date — never the error's text.
            guard let lastSessionError else { return }
            CaptureOutcomeJournal.record(
                CaptureOutcomeJournal.outcome(for: lastSessionError), failure: lastSessionError,
                defaults: outcomeJournalDefaults()
            )
        }
    }
    /// Identifies the *publication* of `lastSessionError`, not its text, so a
    /// failure that reads identically to the last one is still a new event.
    @Published public private(set) var sessionErrorToken: UUID?
    /// Non-nil when the session silently fell back to on-device transcription
    /// because the selected cloud model had no API key available.
    @Published public internal(set) var providerFallbackNotice: String?
    /// What the last completed capture actually did with the transcript
    /// (issue #1008). Built from observed results, never from intentions, so
    /// it is safe for any surface to render verbatim.
    @Published public internal(set) var lastCaptureReceipt: CaptureReceipt?

    /// Whether the background polish started by the most recent stop is still
    /// running, and what it produced (issue #1015).
    ///
    /// Published so a returning intent can opt in to waiting for the polished
    /// text instead of handing a Shortcut the raw transcript while the
    /// clipboard is about to hold a different one. `lastPolishedTranscript`
    /// stays `nil` when the polish failed or was never started, which is what
    /// keeps the wait honest: the caller falls back to the raw transcript
    /// rather than being told nothing came back.
    @Published public internal(set) var isPostProcessing = false
    @Published public internal(set) var lastPolishedTranscript: String?
    /// Which capture's polish `isPostProcessing` and `lastPolishedTranscript`
    /// describe.
    ///
    /// Both used to be service-wide with no owner, so recording B could start,
    /// stop and begin waiting while A was still polishing; A would then write
    /// its own result and clear the flag, and B's waiter would return A's
    /// text. Completion state belongs to a particular stop, so it is tagged
    /// with one.
    @Published public internal(set) var polishingRunID: UUID?

    /// What one capture finished with, tagged with the session that produced it.
    ///
    /// A caller that starts a capture does not necessarily own its stop — the
    /// Live Activity, the Action Button and `justspeaktoit://stop` can all end
    /// it — and "the last completed transcript" in the App Group is a global
    /// that a *later* recording overwrites. Anything waiting on a result it did
    /// not stop needs to be able to tell one session's outcome from another's,
    /// and to tell an empty transcript apart from a failed one.
    public struct FinishedCapture: Sendable, Equatable {
        /// The session this outcome belongs to, matching `currentSessionID` at
        /// the time that session was started.
        public let sessionID: UUID
        /// The transcript, which is legitimately empty when nothing was said.
        public let text: String
        /// Set when the session ended in a provider or recording error, in
        /// which case `text` is whatever had accumulated and is not an answer.
        public let failureMessage: String?

        public var failed: Bool { self.failureMessage != nil }
    }

    /// Identifies the capture currently starting or running, from the moment
    /// `startRecording` commits to it until it finishes.
    @Published public private(set) var currentSessionID: UUID?

    /// The most recent capture to finish, whoever stopped it. Published after
    /// the transcriber has drained and the transcript has been committed, so a
    /// waiter that sees its own session id here is reading a settled result.
    @Published public private(set) var lastFinishedCapture: FinishedCapture?

    private let audioSessionManager = AudioSessionManager()
    let dependencies: RecordingServiceDependencies
    let settings: AppSettings
    let focusOverride: @MainActor (CaptureRunParameters) async throws -> FocusCaptureOverride
    let activityManager: RecordingServiceActivity
    let sharedState: SharedTranscriptionState
    let historyManager: iOSHistoryManager
    private let foregroundOwnership: ForegroundRecordingOwnership
    private let ensureKeysLoaded: @MainActor () async -> Void
    let networkSnapshot: CaptureNetworkPathMonitor.SnapshotProvider
    let localRecognitionCapability: @MainActor (String) -> AppleLocalRecognitionCapability

    var transcriptionSession: (any IOSRecordingSession)?
    var stoppingSession: (any IOSRecordingSession)?
    /// Test seam: lets lifecycle tests inject a session without a microphone or provider.
    var makeSession: (() throws -> any IOSRecordingSession)?
    /// A controlled stop reason (an audio interruption) that is not a failure.
    /// Cleared at the start of every run; never populates `lastSessionError`.
    @Published var captureStopNotice: String?
    var startTime: Date?
    var currentModel: String = ""
    var sharesLiveTranscript = true
    var sharedTranscriptRequested = true
    private(set) var automaticStopDestination: HardwareTriggerDestination = .clipboard
    var onCaptureDisruption: (() async -> Void)?
    /// Which trigger started the session in flight, so onboarding can only
    /// mark a trigger proven when a transcript really arrived through it.
    /// `nil` means the caller did not identify itself, and nothing is claimed.
    var currentTrigger: CaptureTrigger?
    /// Per-run parameter overrides supplied by the surface that started the
    /// session (issue #1013). They travel with the run so every stop path —
    /// the Live Activity button, a Siri stop, a quick action, an interruption
    /// — finishes where the caller asked, not where the global setting says.
    /// `.none` is the pre-parameter behaviour in every respect.
    var currentRunParameters: CaptureRunParameters = .none
    var effectiveConfiguration: EffectiveCaptureConfiguration?
    var effectiveDestination: CaptureDestinationSelection?
    var lastCompletedDestination: CaptureDestinationSelection?

    public var captureDestinationStatus: String? {
        guard let effectiveConfiguration,
              let destination = HardwareTriggerDestination(rawValue: effectiveConfiguration.destinationID)
        else { return nil }
        return destination.displayName + (effectiveConfiguration.destinationOrigin == .focus ? " · Focus" : "")
    }
    /// Identity of the capture in flight, so a caller that started one can
    /// recognise its own result. `nil` once that capture has settled.
    var currentRunID: UUID?
    var requestDiagnostics = IOSRequestDiagnosticState()
    private var pendingIssueFailure: IOSIssueReportSnapshot?

    func issueSnapshot(for token: UUID?) -> IOSIssueReportSnapshot { requestDiagnostics.snapshot(for: token) }

    func publishRequestFailure(_ error: Error, failure: RequestDiagnosticContext.Failure) {
        pendingIssueFailure = error is CancellationError ? nil
            : requestDiagnostics.freezeFailure(failure, run: currentRunID)
        lastSessionError = error
    }
    /// The transcript the most recent capture committed, tagged with the
    /// capture it belongs to.
    ///
    /// A waiter cannot read "the last completed transcript" and assume it is
    /// its own: a stop leaves `recording` for `stopping` before it drains the
    /// session, so a poll on liveness can return while finalisation is still
    /// running, and an untagged slot would then hand back the *previous*
    /// capture's text. Tagging also lets an empty result stay empty instead of
    /// being satisfied by an older non-empty one.
    private var lastRunCompletion: CaptureRunCompletion?
    /// Closed typed cause retained while this startup owns cancellation cleanup.
    private var startupWatchdogFailure: (runID: UUID, error: iOSTranscriptionError)?
    /// Run-identity state machine for cancellable startup (issue #701); the
    /// pure mechanics live in SpeakCore so they are testable on every
    /// platform. `state` mirrors it for observers.
    let lifecycle = RecordingLifecycleCoordinator()
    /// Truthful capture presentation (issue #983): startup stays visibly
    /// "preparing" until this run has both started its backend and observed a
    /// buffer from its own live input tap.
    var presentation = CapturePresentationGate()
    /// Local run-scoped startup timing (issue #972). Measurement only: it adds
    /// no network call, no vendor reporting and no behaviour change.
    var diagnostics = StartupDiagnostics()
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
    /// The session whose transcript is being delivered by the stop in
    /// progress. Held only across delivery so a non-retained batch capture's
    /// recording can be discarded *after* its transcript has landed, never at
    /// the moment the provider replied.
    var deliveringSession: (any IOSRecordingSession)?
    /// The cloud model this run would have used had the network been up,
    /// when offline routing substituted on-device recognition (issue #999).
    var offlineIntendedModel: String?
    /// Last time the App Group shared state was written for a partial result.
    var lastSharedStateWriteAt: Date = .distantPast
    static let sharedStateWriteInterval: TimeInterval = 1.0

    let polishClipboard: PolishClipboard
    let hasPolishingKey: @MainActor () -> Bool
    let polish: @MainActor (String, String, String) async throws -> String
    var latestCompletionID: UUID?
    typealias ActivityCompletion =
        @MainActor (Int, Int, String, TranscriptionCompletionOutcome, String, String?, String) -> Void
    typealias OwnedActivityCompletion =
        @MainActor (Int, Int, String, TranscriptionCompletionOutcome, String, String?, String, UUID) -> Void
    let completeActivity: ActivityCompletion
    let completeOwnedActivity: OwnedActivityCompletion?
    private let sessionFactory: (() throws -> IOSTranscriptionSession)?
    let outcomeJournalDefaults: @MainActor () -> UserDefaults?

    private convenience init() {
        let settings = AppSettings.shared
        let clipboard = TranscriptClipboard(
            pasteboard: UIPasteboard.general,
            now: Date.init,
            policy: { settings.transcriptClipboardPolicy }
        )
        self.init(
            sharedState: .shared,
            historyManager: .shared,
            polishClipboard: PolishClipboard(pasteboard: SystemPolishPasteboard(clipboard: clipboard)),
            hasPolishingKey: { settings.hasOpenRouterKey },
            polish: { text, model, apiKey in
                try await iOSPostProcessingManager.shared.polish(text: text, model: model, apiKey: apiKey)
            },
            networkSnapshot: CaptureNetworkPathMonitor.liveSnapshotProvider(),
            localRecognitionCapability: AppleLegacyRecognitionCapabilityProbe.capability(for:),
            dependencies: .live(settings: settings)
        )
    }

    /// Keeps recording lifecycle tests isolated from the real clipboard, History and provider.
    init(
        sharedState: SharedTranscriptionState,
        historyManager: iOSHistoryManager,
        polishClipboard: PolishClipboard,
        hasPolishingKey: @escaping @MainActor () -> Bool,
        polish: @escaping @MainActor (String, String, String) async throws -> String,
        completeActivity: ActivityCompletion? = nil,
        sessionFactory: (() throws -> IOSTranscriptionSession)? = nil,
        foregroundOwnership: ForegroundRecordingOwnership? = nil,
        ensureKeysLoaded: (@MainActor () async -> Void)? = nil,
        networkSnapshot: @escaping CaptureNetworkPathMonitor.SnapshotProvider = { .unknown },
        localRecognitionCapability: @escaping @MainActor (String) -> AppleLocalRecognitionCapability =
            { _ in .available },
        dependencies: RecordingServiceDependencies? = nil,
        outcomeJournalDefaults: @escaping @MainActor () -> UserDefaults? = { CaptureOutcomeJournal.defaults }
    ) {
        // Injected constructors without dependencies retain a no-op Focus seam.
        self.focusOverride = dependencies?.focusOverride ?? { _ in .none }
        let dependencies = dependencies ?? .live()
        self.dependencies = dependencies
        self.settings = dependencies.settings
        self.activityManager = dependencies.activity
        self.sessionFactory = sessionFactory
        self.outcomeJournalDefaults = outcomeJournalDefaults
        self.foregroundOwnership = foregroundOwnership ?? .shared
        self.ensureKeysLoaded = ensureKeysLoaded ?? { await dependencies.settings.ensureKeysLoaded() }
        self.networkSnapshot = networkSnapshot
        self.localRecognitionCapability = localRecognitionCapability
        self.sharedState = sharedState
        self.historyManager = historyManager
        self.polishClipboard = polishClipboard
        self.hasPolishingKey = hasPolishingKey
        self.polish = polish
        self.completeActivity = completeActivity ?? dependencies.activity.complete
        // An existing injected completion callback keeps complete ownership of its effects.
        self.completeOwnedActivity = completeActivity == nil ? dependencies.activity.completeOwned : nil
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

    var elapsedSeconds: Int {
        guard let start = startTime else { return 0 }
        return Int(Date().timeIntervalSince(start))
    }

    var modelDisplayName: String {
        ModelCatalog.transcriptionDisplayName(
            for: currentModel,
            isBatch: transcriptionSession?.isBatch
                ?? effectiveConfiguration?.usesBatch
                ?? (settings.transcriptionMode == .batch)
        )
    }

    // MARK: - Public API

    /// Surfaces a refused capture link on the same alert path a failed session
    /// uses, so a link that does nothing says why. The caller is told through
    /// its `x-error` callback; this is the half the user can see.
    public func reportCaptureFailure(_ failure: Error) {
        lastSessionError = failure
        sessionErrorToken = UUID()
    }

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
        currentRunID = runID
        requestDiagnostics.begin(runID)
        recordingWarningRunID = UUID()
        state = lifecycle.state
        defer { state = lifecycle.state }

        let settings = self.settings
        let configuration = try await admittedConfiguration(
            parameters: parameters, keyboardProfile: keyboardProfile, destination: destination,
            request: configurationRequest, run: runID
        )
        effectiveConfiguration = configuration
        requestDiagnostics.admit(
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
        lastSharedStateWriteAt = .distantPast
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
        // so only enforce this when the app isn't active.
        let appIsActive = dependencies.applicationState() == .active
        let activityProvider = providerFallbackNotice == OfflineCaptureRouting.fallbackNotice
            ? "\(modelDisplayName) (Offline)"
            : providerFallbackNotice == nil
                ? modelDisplayName
                : "\(modelDisplayName) (\(settings.credentialFallbackReason))"
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
            requestDiagnostics.observe(
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

    /// Settles the current session's outcome under its own identity and clears
    /// the identity, so nothing waiting on it can be answered twice or answered
    /// with a later recording's result.
    func publishFinishedCapture(text: String, failure: Error?) {
        guard let sessionID = currentSessionID else { return }
        currentSessionID = nil
        lastFinishedCapture = FinishedCapture(
            sessionID: sessionID,
            text: text,
            failureMessage: failure?.localizedDescription
        )
    }

    /// The transcript committed by a specific capture, tagged with its
    /// identity.
    public struct CaptureRunCompletion: Sendable, Equatable {
        public let runID: UUID
        public let text: String
    }

    /// Identity of the capture in flight, or `nil` when none is. A caller that
    /// starts a capture and then waits for it reads this immediately after
    /// `startRecording` returns and uses it to claim its own result.
    public var activeCaptureID: UUID? { currentRunID }

    /// Whether anything is still in flight — including a stop that is draining
    /// the transcriber and committing its result.
    ///
    /// `isActive` deliberately excludes `stopping`, because a stop has nothing
    /// left to act on. A *waiter* needs the wider question: a poll on
    /// `isActive` returns while finalisation is still running.
    public var isSettling: Bool { state != .idle }

    /// The transcript `runID` committed, or `nil` when that capture has not
    /// completed (or a different one did). An empty string is a real answer:
    /// the capture finished and produced no text.
    public func completedTranscript(forRun runID: UUID) -> String? {
        guard let lastRunCompletion, lastRunCompletion.runID == runID else { return nil }
        return lastRunCompletion.text
    }

    func retainStartupWatchdogFailure(_ error: iOSTranscriptionError, run: UUID) {
        guard currentRunID == run, lifecycle.isCurrentStartRun(run) else { return }
        startupWatchdogFailure = (run, error)
    }

    /// A final intent failure may only annotate its own failed, fully settled admission.
    /// A late framework error after a successful start cannot rewrite even that same run's result.
    func recordTerminalStartupFailure(
        _ error: Error,
        request: CaptureConfigurationRequest
    ) {
        guard !request.serviceStartReturnedNormally, let run = request.admittedRunID,
              state == .idle, !foregroundOwnership.isOwned, lastRunCompletion?.runID == run else { return }
        let cause = startupWatchdogFailure.flatMap { $0.runID == run ? $0.error : nil }
        let failure: Error = (cause as Error?) ?? error
        CaptureOutcomeJournal.record(
            CaptureOutcomeJournal.outcome(for: failure), failure: failure, defaults: outcomeJournalDefaults()
        )
    }

    /// A start intent refused its own Shortcut parameters before any admission,
    /// so the foreground helper never ran and nothing else journals the refusal.
    /// Recorded only while nothing is in flight or owned in the foreground, so a
    /// refused retry cannot overwrite a running or in-app capture's outcome.
    func recordRefusedStartParameters(_ failure: CaptureParameterFailure) {
        guard state == .idle, !foregroundOwnership.isOwned else { return }
        CaptureOutcomeJournal.record(.failed, failure: failure, defaults: outcomeJournalDefaults())
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

    /// Publishes the result of the capture in flight, if there is one, and
    /// retires its identity.
    func completeRun(with text: String) {
        guard let currentRunID else { return }
        lastRunCompletion = CaptureRunCompletion(runID: currentRunID, text: text)
        requestDiagnostics.retire(currentRunID)
        self.currentRunID = nil
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
        // The cancelled run's loss notice describes a recording that is being
        // discarded; retire it with the run so a later capture cannot inherit it.
        recordingWarningRunID = UUID()
        recordingWarning = nil
        if lifecycle.state == .starting {
            lifecycle.retireStartRun()
            return
        }
        // A cancelled session still has to settle for anything waiting on it:
        // an empty outcome is what a cancel produced, and a waiter must not be
        // left reading the previous recording's result instead.
        self.publishFinishedCapture(text: "", failure: nil)
        transcriptionSession?.cancel()
        transcriptionSession = nil
        currentRunParameters = .none
        effectiveConfiguration = nil
        effectiveDestination = nil
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
        // A cancelled capture completes empty for its own run, so a waiter
        // returns nothing rather than an earlier capture's transcript.
        completeRun(with: "")
        lifecycle.finishStopping()
        state = lifecycle.state
    }
}

#endif
