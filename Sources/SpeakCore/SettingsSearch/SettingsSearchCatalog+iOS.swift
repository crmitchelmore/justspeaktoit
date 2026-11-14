import Foundation

/// iOS Settings is a root list of sub-pages (`IOSSettingsPage`); these entries are
/// the sections on those pages. Settings on screens opened from a section are
/// indexed as keywords of that section.
extension SettingsSearchCatalog {
    static let iOSEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "ios.transcription", title: "Transcription", section: .transcription, systemImage: "waveform",
            summary: "Where transcription runs, the Apple Speech, streaming and batch models, and keywords.",
            keywords: [
                "where transcription runs", "on device", "remote mode", "remote streaming model", "remote batch model",
                "apple speech model", "model picker", "keywords", "vocabulary", "live", "batch"
            ],
            settingKeys: [
                "selectedModel", "transcriptionMode", "rememberedRemoteTranscriptionMode", "batchTranscriptionModel",
                "transcriptionKeywords"
            ],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.autoCorrections", title: "Auto-Corrections", section: .postProcessing,
            systemImage: "text.badge.checkmark",
            summary: "Learn corrections from edits to transcripts the Just Speak Keyboard inserted, "
                + "and review or remove them.",
            keywords: [
                "learned corrections", "learn", "learning", "auto-correct", "autocorrect", "auto corrections",
                "candidate corrections", "promotion threshold", "threshold", "personal corrections", "edits",
                "keyboard edits", "dismiss", "suggestions"
            ],
            settingKeys: ["autoCorrectionsEnabled", "autoCorrectionsPromotionThreshold"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.microphone", title: "Microphone", section: .general, systemImage: "mic",
            summary: "Choose the microphone recording uses, or follow the system default.",
            keywords: [
                "microphone", "input device", "audio input", "mic", "headset", "bluetooth", "usb microphone",
                "external microphone", "system default"
            ],
            settingKeys: ["preferredAudioInputUID"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.behavior", title: "Behavior", section: .general, systemImage: "slider.horizontal.3",
            summary: "Auto-start recording, hands-free dictation and Live Activities.",
            keywords: [
                "auto-start recording", "hands-free dictation", "live activities", "dynamic island", "lock screen",
                "behaviour"
            ],
            settingKeys: ["autoStartRecording", "handsFreeDictationEnabled", "liveActivitiesEnabled"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.keyboard", title: "Just Speak Keyboard", section: .shortcuts, systemImage: "keyboard",
            summary: "Set up the dictation keyboard and Full Access.",
            keywords: ["set up keyboard", "full access", "keyboard extension", "dictate in any app"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.savedResults", title: "Saved Results", section: .general, systemImage: "tray.and.arrow.down",
            summary: "Transcript-ready alerts and upgrading offline transcripts.",
            keywords: [
                "transcript ready alerts", "notifications", "upgrade offline transcripts when back online", "offline"
            ],
            settingKeys: ["transcriptReadyNotificationsEnabled", "upgradeOfflineTranscriptsWhenOnline"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.focusCapture", title: "Focus Capture Overrides", section: .general, systemImage: "moon",
            summary: "Capture destinations chosen by Focus filters.",
            keywords: ["focus filter", "focus mode", "reset stored override", "do not disturb"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.hardwareTrigger", title: "Hardware Trigger", section: .shortcuts,
            systemImage: "button.horizontal.top.press",
            summary: "Action Button and Shortcuts: destination, stop on silence and clipboard privacy.",
            keywords: [
                "action button", "shortcuts gallery", "back tap", "destination", "stop on silence", "auto stop",
                "when recording stops", "siri", "transcribe voice"
            ],
            settingKeys: ["hardwareTriggerDestination", "autoStopOnSilenceEnabled", "autoStopSilenceSeconds"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.postProcessing", title: "Post-Processing", section: .postProcessing, systemImage: "wand.and.stars",
            summary: "Auto-polish after recording, the cleanup model and prompt.",
            keywords: [
                "auto-polish after recording", "model & prompt", "cleanup", "llm", "openrouter", "model discovery",
                "effective policy preview"
            ],
            settingKeys: [
                "autoPostProcess", "postProcessingEnabled", "postProcessingModel", "cleanupModelDiscoveryEnabled"
            ],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.apiKeys", title: "API Keys", section: .apiKeys, systemImage: "key.fill",
            summary: "Add and manage provider API keys.",
            keywords: ["manage keys", "credentials", "tokens", "openrouter key", "openai key", "deepgram key"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.sync", title: "Sync", section: .dataMigration, systemImage: "icloud",
            summary: "iCloud History sync, encrypted key sync and QR transfer.",
            keywords: [
                "icloud", "history sync", "share to another device", "import from qr code", "transfer", "last sync"
            ],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.sendToMac", title: "Send to Mac", section: .dataMigration, systemImage: "desktopcomputer",
            summary: "Pair with a Mac on your network and send it finished transcripts.",
            keywords: [
                "send to mac", "pair", "pairing code", "bonjour", "local network", "forget mac", "paste on mac"
            ],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.troubleshooting", title: "Troubleshooting", section: .troubleshooting,
            systemImage: "wrench.and.screwdriver",
            summary: "Find what's stopping dictation and fix it.",
            keywords: [
                "troubleshoot", "not working", "permissions", "microphone", "speech recognition", "api key",
                "rejected key", "keyboard", "full access", "on-device model", "fix"
            ],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.captureHealth", title: "Capture Health", section: .troubleshooting, systemImage: "stethoscope",
            summary: "Check capture is working.",
            keywords: ["diagnostics", "self test", "microphone not working", "troubleshoot"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.recordings", title: "Recordings", section: .general, systemImage: "waveform.circle",
            summary: "Saved recordings, and whether cancelled recordings keep their audio.",
            keywords: [
                "saved recordings", "audio files", "storage", "keep audio when cancelled", "keep audio", "cancel",
                "discard", "delete recording"
            ],
            settingKeys: ["keepAudioOnCancel"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.privacy", title: "Privacy & Debugging", section: .about, systemImage: "hand.raised",
            summary: "Crash reports and diagnostics, privacy information, clipboard expiry and debug logging.",
            keywords: [
                "privacy information", "debug logging", "clipboard", "transcript expiry", "universal clipboard",
                "network activity", "send crash reports and diagnostics", "crash reports", "diagnostics", "sentry"
            ],
            settingKeys: ["diagnosticsConsent", "transcriptClipboardLifetime", "transcriptAllowsUniversalClipboard"],
            platforms: .iOS
        ),
        SettingsSearchEntry(
            id: "ios.about", title: "About", section: .about, systemImage: "info.circle",
            summary: "Version, release notes and privacy policy.",
            keywords: ["version", "release notes", "privacy policy", "build", "commit"],
            platforms: .iOS
        )
    ]
}
