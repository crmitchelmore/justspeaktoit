#if os(iOS)
import AppIntents
import SpeakCore
import UIKit

// App Intent declarations intentionally stay together so Shortcuts metadata and
// foreground-continuation behavior remain auditable in one place. That is worth
// more than the file-length rule: splitting the recording intents across files
// is how one of them quietly ends up with a different authentication policy or
// a different destination precedence from its siblings.
// swiftlint:disable file_length

// MARK: - Audio Recording Intent (Action Button / Shortcuts)

/// The spoken and Shortcuts result of a stop.
///
/// `receipt` is what the delivery actually did (issue #1008) and always wins:
/// it is built from observed results, so it cannot claim a copy that failed or
/// a field insert that never happened. The per-destination strings below remain
/// for the fixed destinations, where they say the same thing with the word
/// count Siri reads out.
@available(iOS 18, *)
private func stopResultDialog(
    for result: TranscriptionResult,
    destination: HardwareTriggerDestination,
    receipt: CaptureReceipt?,
    canPostProcess: Bool = true
) -> IntentDialog {
    let wordCount = result.text.split(separator: " ").count
    if result.text.isEmpty {
        return "Recording stopped. No speech detected."
    }
    switch destination {
    case .auto:
        guard let receipt else { return "Recording stopped." }
        return IntentDialog(stringLiteral: "\(receipt.headline). \(wordCount) words.")
    case .clipboard:
        return "Copied \(wordCount) words to clipboard."
    case .clipboardAndPostProcess:
        if canPostProcess {
            return "Copied \(wordCount) words. Polishing in the background."
        }
        return "Copied \(wordCount) words. Add an OpenRouter API key to polish future recordings."
    case .historyOnly:
        return "Saved \(wordCount) words to history."
    }
}

/// A keyboard-owned dictation shares the microphone with every hardware
/// trigger. Rather than colliding with it — refusing with "already recording",
/// or stopping it into the *hardware* destination and losing the field the
/// keyboard was aiming at — a physical press finishes it into that field
/// (issue #1002).
///
/// Returns `true` when the press was consumed by the keyboard session.
///
/// Every supported stop entry point must run this **before** its own generic
/// stop: `StopTranscriptionRecordingIntent`, the Action Button toggle, the
/// Control Center toggle's off position, and `StopDictationIntent`. Stopping
/// the service directly would finalise a keyboard-owned capture with the
/// *hardware* destination and publish a pickup offer, instead of completing
/// the nonce-scoped handoff into the field the keyboard opened it for.
@available(iOS 18, *)
@MainActor
func finishedKeyboardSessionIfActive() -> Bool {
    switch KeyboardDeliveryPublisher.sessionRouting() {
    case let .finishKeyboardSession(requestID):
        return KeyboardInstantDictationCoordinator.shared.finishKeyboardSession(requestID: requestID)
    case .keyboardSessionStarting:
        // The keyboard has asked for a recording that has not begun. Racing
        // its start-up would either double-start or silently drop it.
        return true
    case .proceed:
        return false
    }
}

/// Starts recording with foreground recovery if the required Live Activity is unavailable.
///
/// `LiveActivityIntent` permits activity creation without opening the app when
/// requested within its awaited `perform()` execution. `AudioRecordingIntent`
/// requires that activity throughout microphone capture. Keep this call awaited
/// so the service can reuse a primed activity or request one before starting audio.
///
/// The grant does not guarantee success in every device state. If the service
/// reports `liveActivityUnavailable`, retain the narrow foreground-continuation
/// retry: the app briefly comes to the front, where starting a Live Activity is
/// permitted, and recording proceeds. Other failures propagate without starting
/// audio through this fallback.
///
/// `entry` is the timestamp taken at `perform()` entry. It is passed through
/// unchanged — including into the foreground retry — so the measured startup
/// covers the intent hop rather than restarting the clock partway down the
/// path (issue #972).
@available(iOS 18, *)
func startRecordingContinuingInForegroundIfNeeded(
    from intent: some ForegroundContinuableIntent,
    trigger: CaptureTrigger,
    parameters: CaptureRunParameters = .none,
    entry: StartupEntry,
    endPointing: CaptureEndPointingRequest? = nil
) async throws {
    let service = await TranscriptionRecordingService.shared
    do {
        try await service.startRecording(
            trigger: trigger,
            parameters: parameters,
            endPointing: endPointing,
            entry: entry
        )
    } catch iOSTranscriptionError.liveActivityUnavailable {
        try await intent.requestToContinueInForeground {
            try await TranscriptionRecordingService.shared.startRecording(
                trigger: trigger,
                parameters: parameters,
                endPointing: endPointing,
                entry: entry
            )
        }
    }
}

/// The overrides a start intent carries, or a visible failure.
///
/// Validation happens before anything is allocated, so a Shortcut that names a
/// language or model the app does not have never opens a microphone: it fails
/// with a message naming what was wrong instead of recording with something
/// else and letting the user find out afterwards.
@available(iOS 18, *)
private func resolvedRunParameters(
    destination: CaptureDestinationAppEnum?,
    language: String?,
    model: String?,
    source: String?
) throws -> CaptureRunParameters {
    try CaptureParameterResolution.resolve(
        destinationID: destination?.rawValue,
        language: language,
        model: model,
        source: source,
        // Validate against what iOS can actually execute, not just what the
        // cross-platform catalogue can spell. A Mac-only streaming provider or
        // a batch entry with no iOS upload route is refused here rather than
        // accepted and then run as something else.
        vocabulary: CaptureModelSupport.vocabulary
    )
}

/// Idempotent start intent for users who wire their Action Button / Shortcut
/// to a one-shot start (and a separate one to stop). If a recording is already
/// in progress this intent leaves it running and reports the state.
@available(iOS 18, *)
public struct StartTranscriptionIntent: AudioRecordingIntent, LiveActivityIntent, ForegroundContinuableIntent {
    public static var title: LocalizedStringResource = "Start Recording"
    public static var description = IntentDescription(
        "Start a fresh transcription. No-op if already recording. Pair with Stop Recording to finish."
    )

    public static var openAppWhenRun: Bool = false
    /// Deliberately runs without authentication: starting a recording returns
    /// no user data, and locked-device capture via the Action Button / Siri is
    /// a core use of this intent.
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(
        title: "Destination",
        description: "Where the transcript goes. Leave unset to use the destination from Settings."
    )
    public var destination: CaptureDestinationAppEnum?

    @Parameter(
        title: "Language",
        description: "Language to transcribe in, such as en_GB. Leave unset to use the language from Settings.",
        optionsProvider: CaptureLanguageOptionsProvider()
    )
    public var language: String?

    @Parameter(
        title: "Model",
        description: "Transcription model for this recording. Leave unset to use the model from Settings.",
        optionsProvider: CaptureModelOptionsProvider()
    )
    public var model: String?

    @Parameter(
        title: "Source",
        description: "A label for your own automation. It is written to the app's log and changes nothing else."
    )
    public var source: String?

    /// Every parameter sits below the summary line, so a saved shortcut that
    /// sets none of them still reads as plain "Start recording".
    public static var parameterSummary: some ParameterSummary {
        Summary("Start recording") {
            \.$destination
            \.$language
            \.$model
            \.$source
        }
    }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let entry = StartupEntry(origin: .startIntent)
        let service = await TranscriptionRecordingService.shared
        // `starting` counts: a startup in flight is already an active
        // operation, not a free slot (issue #701).
        let isActive = await service.isActive
        if isActive {
            return .result(dialog: "Recording already in progress.")
        }
        if SharedTranscriptionState.shared.isRecording {
            return .result(dialog: "A recording is already in progress in the app. Use the in-app stop button.")
        }
        // A refused parameter is reported as itself. Folding it into the
        // generic "check your permissions" line below would send the user to
        // the wrong place entirely.
        let parameters = try resolvedRunParameters(
            destination: destination,
            language: language,
            model: model,
            source: source
        )
        do {
            try await startRecordingContinuingInForegroundIfNeeded(
                from: self,
                trigger: .shortcut,
                parameters: parameters,
                entry: entry
            )
        } catch let failure as CaptureParameterFailure {
            throw failure
        } catch {
            return .result(
                dialog: "Couldn’t start recording. Check microphone and speech-recognition access, then try again."
            )
        }
        return .result(dialog: "Recording started. Run \"Stop Recording\" to finish.")
    }
}

/// Toggle intent for starting/stopping transcription via Action Button, Siri, or Shortcuts.
/// Combines the audio-recording grant with permission to start the required Live
/// Activity during intent execution. Retains foreground recovery on iOS 18+.
@available(iOS 18, *)
public struct StartTranscriptionRecordingIntent: AudioRecordingIntent, LiveActivityIntent,
    ForegroundContinuableIntent {
    private enum ToggleRecordingError: LocalizedError {
        case alreadyRecordingInApp

        var errorDescription: String? {
            switch self {
            case .alreadyRecordingInApp:
                return "A recording is already in progress in the app. Use the in-app stop button."
            }
        }
    }

    public static var title: LocalizedStringResource = "Toggle Recording"
    public static var description = IntentDescription(
        "Start or stop voice transcription. Result lands in the destination you chose in Settings."
    )

    public static var openAppWhenRun: Bool = false
    /// Deliberately runs without authentication: the Action Button toggle must
    /// work on a locked phone (start, then stop, without unlocking), and the
    /// intent returns no transcript — results only land in the configured
    /// destination. This locked-capture flow is a deliberate product choice.
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(
        title: "Destination",
        description: "Where the transcript goes. Leave unset to use the destination from Settings."
    )
    public var destination: CaptureDestinationAppEnum?

    @Parameter(
        title: "Language",
        description: "Language to transcribe in, such as en_GB. Leave unset to use the language from Settings.",
        optionsProvider: CaptureLanguageOptionsProvider()
    )
    public var language: String?

    @Parameter(
        title: "Model",
        description: "Transcription model for this recording. Leave unset to use the model from Settings.",
        optionsProvider: CaptureModelOptionsProvider()
    )
    public var model: String?

    @Parameter(
        title: "Source",
        description: "A label for your own automation. It is written to the app's log and changes nothing else."
    )
    public var source: String?

    /// The language, model and source apply to the start half of a toggle; the
    /// destination applies to whichever half runs, because a toggle that stops
    /// an unparameterised recording still has somewhere to put the text.
    public static var parameterSummary: some ParameterSummary {
        Summary("Toggle recording") {
            \.$destination
            \.$language
            \.$model
            \.$source
        }
    }

    public init() {}

    /// Returns no Shortcuts value or dialog. Shortcuts promotes textual intent
    /// feedback to the next action's input, so a shortcut containing an extra
    /// Copy to Clipboard step could overwrite the completed transcript with
    /// "Recording started" or "Copied N words" after this intent finished.
    /// Recording feedback already lives in the Live Activity; the pasteboard is
    /// owned exclusively by `stopRecording(destination:)`.
    public func perform() async throws -> IntentResultContainer<Never, Never, Never, Never> {
        let entry = StartupEntry(origin: .toggleIntent)
        let service = await TranscriptionRecordingService.shared
        // A toggle during startup must stop (cancel) the pending run rather
        // than treating the service as free and double-starting (issue #701).
        let isActive = await service.isActive

        // Share one session with the keyboard: a physical press finishes its
        // dictation into its own field instead of colliding with it (#1002).
        if await finishedKeyboardSessionIfActive() {
            return .result()
        }

        if isActive {
            await service.stopRecording(
                destination: await service.resolvedStopDestination(explicit: destination?.destination),
                keyboardDeliverySource: .hardwareTrigger
            )
            return .result()
        } else if SharedTranscriptionState.shared.isRecording {
            throw ToggleRecordingError.alreadyRecordingInApp
        } else {
            let parameters = try resolvedRunParameters(
                destination: destination,
                language: language,
                model: model,
                source: source
            )
            try await startRecordingContinuingInForegroundIfNeeded(
                from: self,
                trigger: .shortcut,
                parameters: parameters,
                entry: entry
            )
            return .result()
        }
    }
}

/// Intent to stop an active recording from a Live Activity button or a dedicated
/// Shortcut paired with `StartTranscriptionIntent`.
///
/// `LiveActivityIntent` conformance is required so the Live Activity button runs
/// this in the *app* process. Without it the widget extension executes the intent
/// itself, where `TranscriptionRecordingService.shared` is a fresh instance with
/// `isRunning == false`, so the stop button would report "No active recording"
/// and the actual recording would keep running.
@available(iOS 18, *)
public struct StopTranscriptionRecordingIntent: AudioRecordingIntent, LiveActivityIntent {
    public static var title: LocalizedStringResource = "Stop Recording"
    public static var description = IntentDescription(
        "Stops the current transcription and routes the result to the destination you chose in Settings."
    )

    public static var openAppWhenRun: Bool = false
    /// Deliberately runs without authentication: this is the Live Activity's
    /// stop button, which must work from the lock screen, and the dialog only
    /// reports a word count — the transcript itself is never returned. Use
    /// `StopDictationIntent` (authenticated) to get the text in a Shortcut.
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    /// A stop cannot choose a language or model — the recording it is ending
    /// already made those choices — but it can still redirect the text.
    @Parameter(
        title: "Destination",
        description: "Where the transcript goes. Leave unset to use the destination from Settings."
    )
    public var destination: CaptureDestinationAppEnum?

    public static var parameterSummary: some ParameterSummary {
        Summary("Stop recording") {
            \.$destination
        }
    }

    public init() {}

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let service = await TranscriptionRecordingService.shared
        // `starting` is cancellable, not "no active recording" (issue #701).
        let isActive = await service.isActive

        // A keyboard-owned dictation finishes into its own field (#1002).
        if await finishedKeyboardSessionIfActive() {
            return .result(dialog: "Finishing into the keyboard's text field.")
        }

        guard isActive else {
            if SharedTranscriptionState.shared.isRecording {
                return .result(dialog: "A recording is active in the app. Use the in-app stop button.")
            }
            return .result(dialog: "No active recording.")
        }

        // Explicit beats the override the start carried, which beats the
        // global setting.
        let resolved = await service.resolvedStopDestination(explicit: destination?.destination)
        let canPostProcess = await AppSettings.shared.hasOpenRouterKey
        let result = await service.stopRecording(
            destination: resolved,
            keyboardDeliverySource: .hardwareTrigger
        )
        return .result(dialog: stopResultDialog(
            for: result,
            destination: resolved,
            receipt: await service.lastCaptureReceipt,
            canPostProcess: canPostProcess
        ))
    }
}

/// Control Center toggle intent for one-tap start/stop of transcription.
///
/// This lives in SpeakiOSLib (not the widget extension) so it can adopt
/// `ForegroundContinuableIntent` and reuse the Action Button's recovery path.
/// `LiveActivityIntent` permits starting the required activity in the app process
/// during `perform()` without opening the app. `AudioRecordingIntent` supplies
/// the recording grant; foreground continuation remains available if the required
/// activity cannot be started or reused.
///
/// The widget extension only ever uses this as a `SetValueIntent` (via
/// `ControlWidgetToggle`), so it never references `ForegroundContinuableIntent`
/// itself — that protocol is unavailable to app extensions, but merely using a
/// type that conforms to it is allowed.
@available(iOS 18, *)
public struct ToggleTranscriptionControlIntent: SetValueIntent, AudioRecordingIntent, LiveActivityIntent,
    ForegroundContinuableIntent {
    public static var title: LocalizedStringResource = "Toggle Transcription"

    /// Deliberately runs without authentication: Control Center is reachable
    /// from the lock screen and this toggle returns no transcript — results
    /// only land in the configured destination.
    public static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }

    @Parameter(title: "Recording")
    public var value: Bool

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult {
        let entry = StartupEntry(origin: .controlToggleIntent)
        let service = TranscriptionRecordingService.shared
        let action = try RecordingControlRequest.action(
            desiredValue: value,
            serviceState: service.state,
            sharedIsRecording: SharedTranscriptionState.shared.isRecording
        )
        switch action {
        case .start:
            try await startRecordingContinuingInForegroundIfNeeded(
                from: self,
                trigger: .control,
                entry: entry
            )
        case .stop:
            // A keyboard-owned dictation finishes into its own field (#1002);
            // only a capture nobody else owns falls through to the generic
            // hardware-destination stop.
            if await finishedKeyboardSessionIfActive() {
                return .result()
            }
            // The Control itself takes no parameters (a configurable Control
            // would change what an already-placed one means), but a Control
            // stop still honours the override the start carried.
            await service.stopRecording(
                destination: service.resolvedStopDestination(),
                keyboardDeliverySource: .hardwareTrigger
            )
        case .none:
            break
        }
        return .result()
    }
}

// MARK: - Result Row Intents

/// Copies the completed transcript from the Live Activity result row.
///
/// `LiveActivityIntent` conformance is what makes this in-process: without it the
/// widget extension performs the intent itself, and a UI-less extension cannot
/// write the general pasteboard (PBErrorDomain 11). It is the same mechanism the
/// Stop button already relies on.
///
/// The row only shows this button when the payload carries a preview, i.e. when
/// the completed transcript was actually published to the App Group, so the
/// button is never offered for a session whose text cannot be retrieved. The
/// activity is moved to `.copied` only after `UIPasteboard.changeCount` confirms
/// the write landed — nothing else in the app sets that outcome, so a `Copied`
/// row always corresponds to a clipboard write that really happened.
///
/// The intent is *not* parameterless: "the last completed transcript" is a moving
/// target. The activity is reused and a finished row is offered for three
/// minutes, so between rendering a row and tapping it another session can finish
/// and replace what the App Group holds. `completionID` is the id of the
/// completion that rendered the tapped row, and the copy is refused unless the
/// stored transcript is still that completion's — a caller is never handed a
/// different recording's text.
@available(iOS 18, *)
public struct CopyLastTranscriptIntent: LiveActivityIntent {
    public static var title: LocalizedStringResource = "Copy Last Transcript"
    public static var description = IntentDescription(
        "Copies the transcript shown on the completed recording row to the clipboard."
    )

    public static var openAppWhenRun: Bool = false
    /// Reads and writes private transcript data, so never run on a locked device.
    public static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    /// The completion the tapped row was rendered from.
    @Parameter(title: "Completion")
    public var completionID: String

    public init() {}

    public init(completionID: String) {
        self.completionID = completionID
    }

    public func perform() async throws -> some IntentResult & ProvidesDialog {
        let state = SharedTranscriptionState.shared
        // Bound to the row that was tapped, not to whatever finished most
        // recently: a row whose transcript has been superseded refuses rather
        // than copying the newer session's text.
        guard let text = state.completedTranscript(matching: completionID) else {
            return .result(dialog: "That transcript is no longer the latest one. Open the app to find it.")
        }

        let copied = await MainActor.run { Self.copyConfirmingChangeCount(text) }
        guard copied else {
            return .result(dialog: "Couldn’t reach the clipboard. Open the app to copy it.")
        }

        await TranscriptionActivityManager.shared.markCompletionCopied(completionID: completionID)
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        return .result(dialog: "Copied \(wordCount) words.")
    }

    /// Writes to the pasteboard and reports whether the system observed the write.
    @MainActor
    private static func copyConfirmingChangeCount(_ text: String) -> Bool {
        let pasteboard = UIPasteboard.general
        let before = pasteboard.changeCount
        pasteboard.string = text
        return pasteboard.changeCount != before
    }
}

// MARK: - Copy Intents

/// App Intent to copy the last transcribed sentence to clipboard.
/// Can be triggered from Live Activity, Shortcuts, or Siri.
struct CopyLastSentenceIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Last Sentence"
    static var description = IntentDescription("Copies the most recent transcribed sentence to the clipboard")

    // Make this available from Live Activity
    static var openAppWhenRun: Bool = false
    /// Returns and copies private transcript data, so never run on a locked device.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    func perform() async throws -> some IntentResult {
        let lastSentence = SharedTranscriptionState.shared.lastTranscribedSentence

        guard !lastSentence.isEmpty else {
            return .result(value: "No recent transcription to copy")
        }

        await MainActor.run {
            UIPasteboard.general.string = lastSentence
        }

        return .result(value: "Copied: \(lastSentence.prefix(50))...")
    }
}

/// App Intent to copy the full transcript to clipboard.
struct CopyFullTranscriptIntent: AppIntent {
    static var title: LocalizedStringResource = "Copy Full Transcript"
    static var description = IntentDescription("Copies the entire transcription to the clipboard")

    static var openAppWhenRun: Bool = false
    /// Returns and copies private transcript data, so never run on a locked device.
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    func perform() async throws -> some IntentResult {
        let fullText = SharedTranscriptionState.shared.currentTranscriptText

        guard !fullText.isEmpty else {
            return .result(value: "No transcription to copy")
        }

        await MainActor.run {
            UIPasteboard.general.string = fullText
        }

        let wordCount = fullText.split(separator: " ").count
        return .result(value: "Copied \(wordCount) words")
    }
}

/// App Shortcuts provider exposing transcription actions (iOS 18+, includes recording).
@available(iOS 18, *)
struct TranscriptionShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartTranscriptionRecordingIntent(),
            phrases: [
                "Toggle recording with \(.applicationName)",
                "Transcribe with \(.applicationName)",
                "Record with \(.applicationName)"
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "mic.fill"
        )

        AppShortcut(
            intent: StartTranscriptionIntent(),
            phrases: [
                "Start recording with \(.applicationName)",
                "Start transcription with \(.applicationName)",
                // The parameterised phrase is what makes a spoken destination
                // possible at all: "Start recording to History Only with
                // Just Speak to It".
                "Start recording to \(\.$destination) with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.badge.plus"
        )

        AppShortcut(
            intent: StopTranscriptionRecordingIntent(),
            phrases: [
                "Stop recording with \(.applicationName)",
                "Stop transcription with \(.applicationName)"
            ],
            shortTitle: "Stop Recording",
            systemImageName: "stop.fill"
        )

        // The one-shot action (#1011) had no phrase, so the only spoken way to
        // get text back was the two-step Start / "Stop dictation and get text"
        // pair. Every parameter it needs has a default, so a bare phrase runs.
        AppShortcut(
            intent: DictateIntent(),
            phrases: [
                "Dictate with \(.applicationName)",
                "Take a note with \(.applicationName)",
                "Dictate to \(\.$destination) with \(.applicationName)"
            ],
            shortTitle: "Dictate",
            systemImageName: "waveform.badge.mic"
        )

        AppShortcut(
            intent: StopDictationIntent(),
            phrases: [
                "Stop dictation and get text with \(.applicationName)",
                "Finish dictation with \(.applicationName)"
            ],
            shortTitle: "Stop and Get Text",
            systemImageName: "text.badge.checkmark"
        )

        AppShortcut(
            intent: GetLastTranscriptionIntent(),
            phrases: [
                "Get my last transcription from \(.applicationName)",
                "Get the last dictation from \(.applicationName)"
            ],
            shortTitle: "Last Transcription",
            systemImageName: "clock.arrow.circlepath"
        )

        AppShortcut(
            intent: CopyLastSentenceIntent(),
            phrases: [
                "Copy last sentence from \(.applicationName)",
                "Copy recent transcription from \(.applicationName)"
            ],
            shortTitle: "Copy Last Sentence",
            systemImageName: "doc.on.doc"
        )

        AppShortcut(
            intent: CopyFullTranscriptIntent(),
            phrases: [
                "Copy full transcript from \(.applicationName)",
                "Copy all transcription from \(.applicationName)"
            ],
            shortTitle: "Copy Full Transcript",
            systemImageName: "doc.on.doc.fill"
        )
    }
}

#endif
