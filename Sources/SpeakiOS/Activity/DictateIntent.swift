#if os(iOS)
import AppIntents
import Foundation
import SpeakCore

// The one-shot Dictate action (issue #1011): record, end on silence, hand the
// text back — one trigger instead of the Start / "Stop Dictation and Get Text"
// pair that is the only text-returning path today.
//
// The end-pointing this depends on is issue #1012's, and every rule about when
// to stop is in `SpeakCore/CaptureEndPointing.swift` where it is unit-tested.
// This file is the Shortcuts-facing wrapper and the wait.

/// One-shot dictation that returns its transcript.
///
/// `requiresAuthentication` because it returns the text: a transcript is
/// private data and a locked device must not hand it to a Shortcut. The plain
/// Start / Stop pair stays available for locked Action Button flows, which
/// return nothing.
///
/// **Not a `LongRunningIntent`.** That protocol, and `CancellableIntent`
/// alongside it, are iOS 27 API and are absent from the iOS 26.2 SDK this
/// builds against — `ProgressReportingIntent` is the only one of the three that
/// exists. Adopting them unverified would be guessing at a contract; issue
/// #1018 owns that work and is explicitly gated on checking it at GM. Until
/// then this runs inside the ordinary `perform()` budget, which is what caps
/// ``CaptureEndPointingPolicy/intentMaximumDurationRange``.
@available(iOS 18, *)
struct DictateIntent: AudioRecordingIntent {
    static var title: LocalizedStringResource = "Dictate"
    static var description = IntentDescription(
        "Records, finishes on its own once you stop speaking, and returns the transcript."
    )

    static var openAppWhenRun: Bool = false
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresAuthentication }

    // The literals in `default:` and `inclusiveRange:` below are not a second
    // copy of the budgets: AppIntents requires compile-time constants there, so
    // the policy constants cannot be spelled. `DictateIntentBoundsTests` fails
    // the build if these literals and `CaptureEndPointingPolicy` ever disagree,
    // and `perform()` clamps through the policy regardless of what arrives.
    @Parameter(
        title: "Pause Length",
        description: """
            Seconds of silence that end the recording. Longer is safer: a short \
            pause length can finish while you are still thinking.
            """,
        default: 3,
        inclusiveRange: (2, 8)
    )
    var pauseLength: Double

    @Parameter(
        title: "Maximum Length",
        description: """
            Seconds after which the recording stops whatever happens. Above 25 the \
            action may be ended by the system before it returns.
            """,
        default: 25,
        inclusiveRange: (5, 60)
    )
    var maximumLength: Double

    @Parameter(
        title: "Destination",
        description: """
            Where the transcript also goes. The text is returned either way. \
            Leave unset to use the destination from Settings.
            """
    )
    var destination: CaptureDestinationAppEnum?

    @Parameter(
        title: "Language",
        description: "Language to transcribe in, such as en_GB. Leave unset to use the language from Settings.",
        optionsProvider: CaptureLanguageOptionsProvider()
    )
    var language: String?

    @Parameter(
        title: "Model",
        description: "Transcription model for this recording. Leave unset to use the model from Settings.",
        optionsProvider: CaptureModelOptionsProvider()
    )
    var model: String?

    @Parameter(
        title: "Source",
        description: "A label for your own automation. It is written to the app's log and changes nothing else."
    )
    var source: String?

    /// Issue #1015. Same contract as `StopDictationIntent.waitForPolish`, and
    /// the same default: off, which is what this action already did.
    @Parameter(
        title: "Wait For Polish",
        description: """
            Wait for the polished version and return that instead of the raw transcript. \
            Only has an effect when your destination polishes; if the polish fails or takes \
            too long, the raw transcript is returned.
            """,
        default: false
    )
    var waitForPolish: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Dictate and get text") {
            \.$pauseLength
            \.$maximumLength
            \.$destination
            \.$language
            \.$model
            \.$source
            \.$waitForPolish
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = await TranscriptionRecordingService.shared
        // Single-flight (issue #943): a Dictate arriving while something is
        // already recording is refused, never allowed to open a second
        // microphone or to hijack the running capture's stop.
        guard await !service.isActive, !SharedTranscriptionState.shared.isRecording else {
            throw DictateIntentError.alreadyRecording
        }

        let parameters = try CaptureParameterResolution.resolve(
            destinationID: destination?.rawValue,
            language: language,
            model: model,
            source: source
        )
        // Clamped through the policy, not trusted from the parameter: a
        // Shortcut can pass a variable rather than use the picker, and
        // `inclusiveRange` is a hint to the editor, not a guarantee.
        let endPointing = CaptureEndPointingRequest(
            silenceWindow: pauseLength,
            maximumDuration: CaptureEndPointingPolicy.intentMaximumDuration(configured: maximumLength)
        )

        do {
            try await service.startRecording(
                trigger: .shortcut,
                parameters: parameters,
                endPointing: endPointing
            )
        } catch let failure as CaptureParameterFailure {
            throw failure
        } catch {
            throw DictateIntentError.couldNotStart
        }

        let transcript = await Self.awaitTranscript(
            service,
            maximumDuration: endPointing.maximumDuration
        )
        let polished = waitForPolish
            ? await service.awaitPolishedTranscript(
                timeout: AutomationIntentSupport.PolishWait.defaultSeconds
            )
            : nil
        guard let text = AutomationIntentSupport.transcriptAfterPolishWait(
            raw: transcript,
            polished: polished,
            didWait: waitForPolish
        ) else {
            throw AutomationIntentError.emptyTranscript
        }
        return .result(value: text)
    }

    /// Waits for the dictation to end, then produces its text.
    ///
    /// Three things can end it, and this handles all three the same way: the
    /// silence end-pointing armed above, a stop from any other surface (the
    /// Live Activity button, a Siri stop, the in-app button), or — only if both
    /// of those somehow failed — the grace deadline here, which stops the
    /// capture itself so a returning intent can never leave a microphone open.
    ///
    /// These are the semantics the `dictate` URL verb established in #1070:
    /// poll rather than observe, so exactly one owner ever performs the stop
    /// and a dictation cannot be stopped twice, and read the completed
    /// transcript from shared state when somebody else was that owner. #1070 is
    /// on a parallel stack and cannot be imported, so this is a matching copy
    /// carried the way #1076 carried its parameter validation: whichever of the
    /// two stacks lands second deletes its copy and forwards to the other, so
    /// `justspeaktoit://dictate` and the Dictate action can never come to mean
    /// different things.
    private static func awaitTranscript(
        _ service: TranscriptionRecordingService,
        maximumDuration: TimeInterval
    ) async -> String {
        // Past the monitor's own cap, so in the ordinary case the stop comes
        // through `stopRecording` from the end-pointing monitor and this is
        // only ever the backstop.
        let deadline = Date().addingTimeInterval(maximumDuration + Self.graceSeconds)
        while await service.isActive, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        guard await service.isActive else {
            return SharedTranscriptionState.shared.lastCompletedTranscript ?? ""
        }
        let destinationOverride = await service.resolvedStopDestination()
        return await service.stopRecording(destination: destinationOverride).text
    }

    /// How long past the capture's own cap the wait allows for the stop to
    /// finalise — draining the transcriber, writing History — before treating
    /// the end-pointing as having failed and stopping the capture itself.
    private static let graceSeconds: TimeInterval = 3
}

// MARK: - Errors

enum DictateIntentError: LocalizedError {
    case alreadyRecording
    case couldNotStart

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A recording is already in progress. Stop it before starting a new dictation."
        case .couldNotStart:
            return "Couldn’t start recording. Check microphone and speech-recognition access, then try again."
        }
    }
}
#endif
