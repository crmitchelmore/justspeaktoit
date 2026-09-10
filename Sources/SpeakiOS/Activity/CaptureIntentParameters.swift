#if os(iOS)
import AppIntents
import SpeakCore

// The Shortcuts-facing half of the per-run capture parameters (issue #1013).
// Everything that *decides* anything is in `SpeakCore/CaptureParameters.swift`
// and unit-tested on the host; this file only describes the parameters to
// Shortcuts and converts between its types and plain identifiers.
//
// Every parameter is optional and unset means "use the global setting", so a
// Shortcut, Control, Action Button binding or automation saved before these
// existed keeps behaving exactly as it did.

// MARK: - Destination

/// The destination picker Shortcuts and Siri show.
///
/// An `AppEnum` rather than a text field because the set is closed and lives
/// in source: three cases that only change when the app changes. The language
/// and model parameters are catalogue-driven instead (see below).
@available(iOS 18, *)
public enum CaptureDestinationAppEnum: String, AppEnum {
    case clipboard
    case clipboardAndPostProcess
    case historyOnly

    public static var typeDisplayRepresentation: TypeDisplayRepresentation = "Destination"

    public static var caseDisplayRepresentations: [CaptureDestinationAppEnum: DisplayRepresentation] = [
        .clipboard: DisplayRepresentation(
            title: "Clipboard",
            subtitle: "Copy the transcript when recording stops."
        ),
        .clipboardAndPostProcess: DisplayRepresentation(
            title: "Clipboard and Polish",
            subtitle: "Copy, then re-copy the polished version when it lands."
        ),
        .historyOnly: DisplayRepresentation(
            title: "History Only",
            subtitle: "Save to history without touching the clipboard."
        )
    ]

    public var destination: HardwareTriggerDestination {
        HardwareTriggerDestination(rawValue: rawValue) ?? .clipboard
    }
}

// MARK: - Catalogue-driven option providers

/// Offers the language catalogue as a picker.
///
/// A provider rather than an `AppEnum` because the catalogue is data, not
/// source cases: an enum would be a second copy to keep in step, and the first
/// time the two drifted a Shortcut would name a language the app no longer
/// has. The user still picks from a list; a Shortcut that prefers to pass a
/// variable can, and an unrecognised value is refused rather than substituted.
///
/// Available from the deployment target rather than iOS 18: `Transcribe Audio
/// File` runs on iOS 17 and offers the same picker.
public struct CaptureLanguageOptionsProvider: DynamicOptionsProvider {
    public init() {}

    public func results() async throws -> [String] {
        TranscriptionLanguageCatalog.options.map(\.id)
    }
}

/// Offers every transcription model the app can actually run, live or batch.
public struct CaptureModelOptionsProvider: DynamicOptionsProvider {
    public init() {}

    public func results() async throws -> [String] {
        CaptureModelSupport.executableModelIDs
    }
}

// MARK: - What iOS can actually execute

/// The models with a real iOS execution path, and the mode each one runs in.
///
/// The shared `ModelCatalog` is cross-platform: it lists streaming providers
/// whose clients only exist in the Mac app and batch entries whose upload
/// route is not implemented here. Settings has always narrowed it with
/// `AppSettings.supportedLiveModels` / `supportedBatchModels`; the intent
/// surface now uses exactly the same two lists rather than a third, wider
/// idea of what is runnable. Anything not in here is refused before the
/// microphone opens instead of failing after the recording, or falling
/// through to the OpenRouter route under a name the caller did not choose.
public enum CaptureModelSupport {
    /// Models this app can stream: on-device transcription plus the remote
    /// live models whose route reports iOS support.
    public static var liveModelIDs: Set<String> {
        Set((ModelCatalog.onDeviceLiveTranscription + AppSettings.supportedLiveModels).map(\.id))
    }

    /// Models this app can upload for batch transcription.
    public static var batchModelIDs: Set<String> {
        Set(AppSettings.supportedBatchModels.map(\.id))
    }

    /// Every executable identifier, catalogue order, deduplicated — the model
    /// picker Shortcuts renders.
    public static var executableModelIDs: [String] {
        let live = liveModelIDs
        let batch = batchModelIDs
        let ordered = ModelCatalog.liveTranscription
            + ModelCatalog.localTranscriptionOptions
            + ModelCatalog.batchTranscription
        var seen = Set<String>()
        return ordered
            .map(\.id)
            .filter { live.contains($0) || batch.contains($0) }
            .filter { seen.insert($0).inserted }
    }

    /// Whether the identifier can run in the mode the session will use. A
    /// model that is only live cannot be uploaded as a batch job, and a
    /// batch-only model cannot be streamed.
    public static func canRun(_ modelID: String, usesBatch: Bool) -> Bool {
        usesBatch ? batchModelIDs.contains(modelID) : liveModelIDs.contains(modelID)
    }

    /// The vocabulary the intent surface validates against, so a value the
    /// picker offers and a value the resolver accepts are the same set.
    public static var vocabulary: CaptureParameterVocabulary {
        CaptureParameterVocabulary(
            destinationIDs: Set(HardwareTriggerDestination.allCases.map(\.rawValue)),
            executableModelIDs: Set(executableModelIDs)
        )
    }
}

#endif
