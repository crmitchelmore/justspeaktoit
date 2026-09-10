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
        let options = ModelCatalog.liveTranscription
            + ModelCatalog.batchTranscription
            + ModelCatalog.localTranscriptionOptions
        var seen = Set<String>()
        return options.map(\.id).filter { seen.insert($0).inserted }
    }
}

#endif
