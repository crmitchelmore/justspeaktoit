#if os(iOS)
import Foundation
import SpeakCore

// MARK: - Hardware Trigger Destination

/// What happens to the transcript after a hardware-triggered recording stops.
///
/// Used by every "headless" entry point: Action Button (iPhone 15 Pro+),
/// Siri voice commands, the Shortcuts app, Lock Screen / Home Screen widget,
/// Control Center, Back Tap. The main in-app record-and-stop flow is
/// unaffected — it always shows the result on screen.
public enum HardwareTriggerDestination: String, CaseIterable, Identifiable, Sendable {
    /// Resolve the destination at stop time (issue #1008): the field the Just
    /// Speak keyboard is open in when there is one, otherwise the clipboard.
    /// Every capture also goes to History, and to iCloud while iCloud History
    /// Sync is on, whichever lane runs.
    ///
    /// There is no "Mac" branch: see `AutoDestinationPolicy` for why the phone
    /// cannot tell a reachable Mac from a configured one.
    case auto

    /// Copy the transcript to the clipboard. Default — matches behaviour
    /// prior to the destination setting being added.
    case clipboard

    /// Copy to clipboard and run the configured post-processor (OpenRouter)
    /// asynchronously. Raw text is copied once and polished text is saved in
    /// History. Without a key, the raw copy remains available.
    case clipboardAndPostProcess

    /// Save to history only — don't touch the clipboard, don't post-process.
    /// Useful if the user wants to capture a thought without polluting the
    /// pasteboard with something they didn't choose to paste.
    case historyOnly

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .auto: return "Auto"
        case .clipboard: return "Copy to Clipboard"
        case .clipboardAndPostProcess: return "Copy & Polish"
        case .historyOnly: return "Save to History Only"
        }
    }

    public var summary: String {
        switch self {
        case .auto:
            return "Decided when recording stops: straight into the field if the Just Speak keyboard is open "
                + "there, otherwise the clipboard. Either way it is saved to History (and iCloud, when iCloud "
                + "History Sync is on), and the Live Activity says which one happened."
        case .clipboard:
            return "Transcript is copied to the clipboard immediately when recording stops."
        case .clipboardAndPostProcess:
            return "Raw transcript is copied immediately. Polished text is saved in History."
        case .historyOnly:
            return "Transcript is saved to history. Clipboard and post-processing are skipped."
        }
    }
}

public enum IOSTranscriptionMode: String, CaseIterable, Identifiable, Sendable {
    case streaming
    case batch

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .streaming: return "Streaming"
        case .batch: return "Batch"
        }
    }
}

enum IOSTranscriptionLocation: String, CaseIterable, Identifiable {
    case local
    case remote

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }
}

extension AppSettings {
    enum DefaultsKey: String, CaseIterable {
        case selectedModel
        case transcriptionMode
        case rememberedRemoteTranscriptionMode
        case batchTranscriptionModel
        case transcriptionKeywords
        case liveActivitiesEnabled
        case transcriptReadyNotificationsEnabled
        case visualDensity
        case autoStartRecording
        case handsFreeDictationEnabled
        case preferredLocale
        case hardwareTriggerDestination
        case autoStopOnSilenceEnabled
        case autoStopSilenceSeconds
        case postProcessingEnabled
        case postProcessingModel
        case autoPostProcess
        case hasLaunchedBefore
        case transcriptClipboardLifetimeSeconds
        case transcriptUniversalClipboard = "transcriptClipboardAllowsUniversalClipboard"
        case transcriptClipboardNoticeVersion
        case upgradeOfflineTranscriptsWhenOnline
        case keepAudioOnCancel
    }

    enum CredentialLoadingError: LocalizedError {
        case unavailable

        var errorDescription: String? {
            "API keys could not be loaded. Retry when Keychain access is available."
        }
    }
}
#endif
