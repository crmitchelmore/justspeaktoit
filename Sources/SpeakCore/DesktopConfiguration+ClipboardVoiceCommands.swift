extension DesktopConfiguration {
    public var clipboardVoiceCommandPolicy: ClipboardVoiceCommandPolicy {
        ClipboardVoiceCommandPolicy(
            isEnabled: enabled(ApplicationPreferenceKey.voiceCommandsEnabled.rawValue),
            customTriggers: text(ApplicationPreferenceKey.clipboardInsertionTriggers.rawValue)
        )
    }
}
