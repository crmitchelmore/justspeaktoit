#if os(iOS)
import Foundation
import SpeakCore

/// Values `AppSettings` reads once at launch whose loading is more than a
/// single stored-value lookup.
extension AppSettings {
    /// Normalise to canonical catalogue ids. Keep only models that this iOS
    /// target can actually run; a previously stored macOS-only model falls
    /// back to Apple Speech instead of leaking into the iPhone picker.
    static func storedSelectedModel(in defaults: UserDefaults) -> String {
        let selectedRaw = Shared.liveTranscriptionModel.iOS.value(in: defaults)
        let selectableLiveIDs = Set(
            (ModelCatalog.onDeviceLiveTranscription + Self.supportedLiveModels).map(\.id)
        )
        if AppleLocalModels.isAppleSpeechModel(selectedRaw) {
            return selectedRaw
        } else if selectableLiveIDs.contains(selectedRaw) {
            return selectedRaw
        } else if selectedRaw.hasPrefix("apple/") {
            return selectedRaw
        } else if selectedRaw.hasPrefix("deepgram/") {
            return "deepgram/nova-3-streaming"
        } else if selectedRaw.hasPrefix("elevenlabs/") {
            return "elevenlabs/scribe-v2-streaming"
        } else if selectedRaw.hasPrefix("openai/") {
            return "openai/gpt-realtime-whisper-streaming"
        }
        return AppleLocalModels.preferredSpeechModelID
    }

    static func storedClipboardPolicy(in defaults: UserDefaults) -> TranscriptClipboardPolicy {
        TranscriptClipboardPolicy(
            storedLifetime: defaults.object(forKey: DefaultsKey.transcriptClipboardLifetimeSeconds.rawValue),
            storedAllowsUniversalClipboard: defaults.object(forKey: DefaultsKey.transcriptUniversalClipboard.rawValue)
        )
    }

    /// Only an exact numeric 1 records the acknowledged notice.
    static func storedClipboardNoticeVersion(in defaults: UserDefaults) -> Int {
        let storedClipboardNotice = defaults.object(forKey: DefaultsKey.transcriptClipboardNoticeVersion.rawValue)
        if let number = storedClipboardNotice as? NSNumber,
           CFGetTypeID(number) != CFBooleanGetTypeID(),
           number.intValue == 1,
           number.doubleValue == 1 {
            return 1
        }
        return 0
    }

    /// Hardware trigger destination (Action Button, Siri, Shortcuts).
    /// `.auto` is the default only for users who never made a choice: an
    /// explicitly stored value is always honoured (issue #1008). Auto is a
    /// superset of the old default — it copies to the clipboard except when
    /// the Just Speak keyboard is demonstrably open in a text field, where
    /// the words go into that field instead.
    ///
    /// A stored value this build cannot parse is *not* the same thing as no
    /// stored value: it means a malformed, downgraded or migrated
    /// preference, and defaulting it to Auto would silently opt that user
    /// into suppressing the clipboard whenever a targeted keyboard offer
    /// exists. Missing keeps the new default; unrecognised keeps the
    /// pre-Auto behaviour it was last known to have.
    static func storedHardwareTriggerDestination(in defaults: UserDefaults) -> HardwareTriggerDestination {
        if let hardwareDestRaw = defaults.string(forKey: DefaultsKey.hardwareTriggerDestination.rawValue) {
            return HardwareTriggerDestination(rawValue: hardwareDestRaw) ?? .clipboard
        }
        return .auto
    }

    /// The normalised cleanup model when this build can run it, else the catalogue default.
    static func storedPostProcessingModel(in defaults: UserDefaults) -> String {
        let normalizedPostModel = Shared.postProcessingModel.iOS.value(in: defaults)
        return (Self.postProcessingModels.contains { $0.id == normalizedPostModel }
            || CleanupModelSelection.modelID(from: normalizedPostModel) != nil)
            ? normalizedPostModel
            : ModelCatalog.defaultPostProcessingModel
    }

    /// An install that has never seen this setting gets the default window,
    /// not the zero `double(forKey:)` returns for a missing key — which the
    /// clamp would raise to the floor anyway, but reading it explicitly
    /// keeps the stored value and the default from ever disagreeing.
    static func storedAutoStopSilenceSeconds(in defaults: UserDefaults) -> TimeInterval {
        CaptureEndPointingPolicy.silenceWindow(
            configured: defaults.object(forKey: DefaultsKey.autoStopSilenceSeconds.rawValue) as? TimeInterval
                ?? CaptureEndPointingPolicy.defaultSilenceWindowSeconds
        )
    }
}
#endif
