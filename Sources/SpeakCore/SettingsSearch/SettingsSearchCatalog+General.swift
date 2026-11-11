import Foundation

extension SettingsSearchCatalog {
    static let generalEntries: [SettingsSearchEntry] = [
        SettingsSearchEntry(
            id: "general.microphone", title: "Microphone", section: .general, systemImage: "mic.circle",
            summary: "Choose which microphone Speak records from.",
            keywords: [
                "preferred microphone", "audio input", "input device", "headset", "airpods", "refresh microphones"
            ],
            settingKeys: ["preferredAudioInputUID"], platforms: [.macOS, .linux]
        ),
        SettingsSearchEntry(
            id: "general.language", title: "Language", section: .general, systemImage: "character.bubble",
            summary: "The language you speak, used to pick and hint transcription models.",
            keywords: ["spoken language", "locale", "english", "accent", "dialect"],
            settingKeys: ["preferredLocaleIdentifier"], platforms: .apple
        ),
        SettingsSearchEntry(
            id: "general.output", title: "Output", section: .general, systemImage: "textformat.alt",
            summary: "How transcripts reach your apps: typing, pasting, clipboard and streaming text.",
            keywords: [
                "text output", "paste", "insert text", "accessibility insertion", "insert at cursor", "replace all",
                "restore clipboard after paste", "clipboard delivery", "app switch", "stream text while dictating",
                "paste iphone and watch transcripts at the cursor", "clipboard triggers", "voice commands"
            ],
            settingKeys: [
                "textOutputMethod", "accessibilityInsertionMode", "restoreClipboardAfterPaste", "appSwitchDelivery",
                "streamingInsertionEnabled", "pasteRemoteTranscriptsAtCursor", "clipboardInsertionTriggers",
                "voiceCommandsEnabled", "restoreClipboard"
            ],
            platforms: [.macOS, .linux]
        ),
        SettingsSearchEntry(
            id: "general.appBehaviour", title: "App Behaviour", section: .general, systemImage: "gearshape.2",
            summary: "Dock or menu bar, status icon, launch at login, updates and sidebar hints.",
            keywords: [
                "show app in", "dock", "menu bar", "status bar icon", "compact status bar icon", "launch at login",
                "start at login", "automatically check for updates", "sidebar shortcut hints", "hide dock icon"
            ],
            settingKeys: [
                "appVisibility", "showStatusBarIconInDockOnly", "compactStatusBarIcon", "runAtLogin",
                "showSidebarShortcutHints"
            ],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "general.appearance", title: "Appearance", section: .general, systemImage: "paintpalette",
            summary: "Light, dark or system theme and layout density.",
            keywords: ["theme", "dark mode", "light mode", "layout density", "compact", "spacing"],
            settingKeys: ["appearance", "visualDensity"], platforms: [.macOS, .iOS, .linux]
        ),
        SettingsSearchEntry(
            id: "general.hud", title: "Heads-Up Display", section: .general, systemImage: "rectangle.on.rectangle",
            summary: "What Speak shows on screen while recording and transcribing.",
            keywords: [
                "hud", "overlay", "show live transcript in hud", "compact hud", "shorten error display",
                "recording indicator", "hud size"
            ],
            settingKeys: [
                "showHUDDuringSessions", "showLiveTranscriptInHUD", "showCompactHUD", "shortenErrorDisplay",
                "hudSizePreference"
            ],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "general.recordingSounds", title: "Recording Sounds", section: .general, systemImage: "speaker.wave.2",
            summary: "Start and stop sounds, their profile and volume.",
            keywords: ["play start/stop sounds", "sound profile", "chime", "beep", "volume", "mute sounds"],
            settingKeys: ["recordingSoundsEnabled", "recordingSoundProfile", "recordingSoundVolume"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "general.fastStart", title: "Fast Start", section: .general, systemImage: "bolt.circle",
            summary: "Prepare recording and warm connections so dictation starts instantly.",
            keywords: [
                "prepare recording while idle", "warm supported connections", "pre-warm", "latency", "startup delay"
            ],
            settingKeys: ["audioPreWarmingEnabled", "connectionPreWarmingEnabled"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "general.sendToMac", title: "Send to Mac", section: .general, systemImage: "iphone.and.arrow.forward",
            summary: "Receive dictation from your iPhone or Apple Watch on this Mac.",
            keywords: ["enable send to mac", "iphone", "apple watch", "handoff", "remote dictation"],
            settingKeys: ["enableSendToMac"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "general.iCloudSync", title: "iCloud Sync", section: .general, systemImage: "icloud",
            summary: "Sync history and model comparisons with iCloud.",
            keywords: ["sync history", "icloud", "cloudkit", "sync comparisons"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "general.automation", title: "Automation", section: .general, systemImage: "terminal",
            summary: "Let the speak CLI and MCP clients control Speak.",
            keywords: ["enable automation", "mcp", "cli", "server", "scripting", "agents"],
            settingKeys: ["enableAutomationServer"], platforms: [.macOS, .linux]
        ),
        SettingsSearchEntry(
            id: "general.automationCLI", title: "Automation CLI", section: .general, systemImage: "terminal.fill",
            summary: "Install or update the speak command-line tool.",
            keywords: ["install cli", "update cli", "command line", "terminal", "path"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "general.housekeeping", title: "Housekeeping", section: .general, systemImage: "tray.full",
            summary: "Where recordings are stored, and deleting them.",
            keywords: ["recordings folder", "recordings directory", "delete all recordings", "disk space", "storage"],
            settingKeys: ["recordingsDirectory"], platforms: [.macOS, .linux]
        ),
        SettingsSearchEntry(
            id: "general.advanced", title: "Advanced", section: .general, systemImage: "gearshape.2",
            summary: "History save interval and other advanced options.",
            keywords: ["history flush interval", "history save"],
            settingKeys: ["historyFlushInterval"], platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "permissions.system", title: "System permissions", section: .permissions, systemImage: "lock.shield",
            summary: "Grant microphone, accessibility and input monitoring access.",
            keywords: ["microphone access", "accessibility", "input monitoring", "request permission", "open settings"],
            platforms: .macOS
        ),
        SettingsSearchEntry(
            id: "permissions.resourcesInUse", title: "System resources in use", section: .permissions,
            systemImage: "gauge.with.dots.needle.33percent",
            summary: "See what Speak holds right now (microphone, audio, connections, hotkey) and release it.",
            keywords: [
                "status", "microphone in use", "mic indicator", "orange dot", "release microphone",
                "release everything", "what is using the microphone", "network connections", "background"
            ],
            platforms: .apple
        ),
        SettingsSearchEntry(
            id: "profiles.perApp", title: "Per-App Profiles", section: .profiles,
            systemImage: "person.crop.rectangle.stack",
            summary: "Use different models, prompts or delivery for specific apps.",
            keywords: ["add profile", "app specific", "edit profile", "bundle id"],
            platforms: .macOS
        )
    ]
}
