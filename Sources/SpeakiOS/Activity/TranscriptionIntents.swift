#if os(iOS)
import AppIntents
import Foundation
import SpeakCore

// The four recording intents (start, start/toggle, stop and the Control Center
// toggle) intentionally stay together so their foreground-continuation,
// authentication and destination precedence remain auditable in one place.
// That is worth more than the file-length rule: splitting them across files is
// how one of them quietly ends up with a different policy from its siblings.
// The plumbing they share with the Dictate and automation intents lives in
// `RecordingIntentStartSupport.swift`; the copy intents and the App Shortcuts
// provider, which carry no recording policy, live in their own files.
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

/// The overrides a start intent carries, or a visible failure.
///
/// Validation happens before anything is allocated, so a Shortcut that names a
/// language or model the app does not have never opens a microphone: it fails
/// with a message naming what was wrong instead of recording with something
/// else and letting the user find out afterwards.
@available(iOS 18, *)
private func resolvedRunParameters(
    service: TranscriptionRecordingService,
    destination: CaptureDestinationAppEnum?,
    language: String?,
    model: String?,
    source: String?
) async throws -> CaptureRunParameters {
    try await journalingRefusedStartParameters(service: service) {
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
}

/// Idempotent start intent for users who wire their Action Button / Shortcut
/// to a one-shot start (and a separate one to stop). If a recording is already
/// in progress this intent leaves it running and reports the state.
@available(iOS 18, *)
public struct StartTranscriptionIntent: AudioRecordingIntent, LiveActivityIntent, ForegroundContinuableIntent {
    public static var title: LocalizedStringResource = "Start Recording"
    public static var description = IntentDescription(
        """
        Only starts recording, and does nothing if one is already running. Use it with Stop Recording \
        when you want separate start and stop buttons. For one button that does both, use Toggle Recording.
        """,
        categoryName: "Recording",
        searchKeywords: ["begin", "start", "dictation", "transcription"]
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
        if await ForegroundRecordingOwnership.shared.isOwned || SharedTranscriptionState.shared.isRecording {
            return .result(dialog: "A recording is already in progress in the app. Use the in-app stop button.")
        }
        // A refused parameter is reported as itself. Folding it into the
        // generic "check your permissions" line below would send the user to
        // the wrong place entirely.
        let parameters = try await resolvedRunParameters(
            service: service,
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
        } catch is CancellationError {
            return .result(dialog: "Recording start was cancelled.")
        } catch is ForegroundRecordingOwnership.OwnershipError {
            // A foreground claim made after this intent's own preflight, while
            // the service waited on credentials (#943), is the in-app owner —
            // not a permissions problem. Report it as the same foreign-owner
            // guidance the preflight gives, so the two answers cannot disagree.
            return .result(dialog: "A recording is already in progress in the app. Use the in-app stop button.")
        } catch {
            let presentation = CaptureStartFailurePresentation.make(for: error)
            return .result(dialog: IntentDialog(stringLiteral: presentation.message))
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
        """
        Starts recording, or stops it if one is running. Recommended for the Action Button, Back Tap, \
        and widgets. The transcript goes to the destination chosen in Settings.
        """,
        categoryName: "Recording",
        searchKeywords: ["begin", "start", "stop", "transcription", "transcribe", "action button"]
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
        Summary("Start or stop recording") {
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
                selection: await service.resolvedStopSelection(explicit: destination?.destination),
                keyboardDeliverySource: .hardwareTrigger
            )
            return .result()
        } else if await ForegroundRecordingOwnership.shared.isOwned || SharedTranscriptionState.shared.isRecording {
            throw ToggleRecordingError.alreadyRecordingInApp
        } else {
            let parameters = try await resolvedRunParameters(
                service: service,
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
            } catch is CancellationError {
                return .result()
            } catch is ForegroundRecordingOwnership.OwnershipError {
                throw ToggleRecordingError.alreadyRecordingInApp
            } catch let failure as CaptureParameterFailure {
                throw failure
            } catch {
                throw CaptureStartFailurePresentation.make(for: error)
            }
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
        """
        Stops the current recording and sends the transcript to the destination chosen in Settings. \
        Works while the device is locked but returns no text; to use the text in a later action, \
        use Stop Dictation and Get Text.
        """,
        categoryName: "Recording",
        searchKeywords: ["end", "finish", "transcription"]
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
            if await ForegroundRecordingOwnership.shared.isOwned || SharedTranscriptionState.shared.isRecording {
                return .result(dialog: "A recording is active in the app. Use the in-app stop button.")
            }
            return .result(dialog: "No active recording.")
        }

        // Explicit beats the override the start carried, which beats the
        // global setting.
        let resolved = await service.resolvedStopSelection(explicit: destination?.destination)
        let canPostProcess = await AppSettings.shared.hasPostProcessingKey
        let result = await service.stopRecording(
            selection: resolved,
            keyboardDeliverySource: .hardwareTrigger
        )
        return .result(dialog: stopResultDialog(
            for: result,
            destination: resolved.destination,
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
    /// Named after the control it backs (#1470): "Toggle Transcription" read as
    /// a different feature from Toggle Recording. Renaming the title keeps saved
    /// shortcuts working, which hiding the intent would not.
    public static var title: LocalizedStringResource = "Transcribe Voice Control"
    public static var description = IntentDescription(
        """
        The action behind the Transcribe Voice control: turns recording on or off. \
        In your own shortcuts, use Toggle Recording instead.
        """,
        categoryName: "Recording"
    )

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
        // Both desired values must report a foreign owner truthfully (#943):
        // the in-app recorder holds process-local ownership from before its
        // first suspension until its teardown settles, while the App Group
        // flag the classifier also reads is false during startup and the stop
        // drain. This guard precedes the classifier for that reason; a desired
        // `false` neither cancels the foreground finalisation nor claims to
        // have stopped it.
        try ForegroundRecordingOwnership.shared.requireUnowned()
        let action = try RecordingControlRequest.action(
            desiredValue: value,
            serviceState: service.state,
            sharedIsRecording: SharedTranscriptionState.shared.isRecording
        )
        switch action {
        case .start:
            do {
                try await startRecordingContinuingInForegroundIfNeeded(
                    from: self,
                    trigger: .control,
                    entry: entry
                )
            } catch is CancellationError {
                return .result()
            } catch let error as ForegroundRecordingOwnership.OwnershipError {
                throw error
            } catch {
                throw CaptureStartFailurePresentation.make(for: error)
            }
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
                selection: service.resolvedStopSelection(),
                keyboardDeliverySource: .hardwareTrigger
            )
        case .none:
            break
        }
        return .result()
    }
}

#endif
