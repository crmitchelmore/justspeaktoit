# Feature parity

Which user-facing features each app has, checked against the code (November 2026
audit). Every **No** or **Partial** that the platform can support has one open
cross-platform issue covering all the platforms that lack it. Update the row in
the same pull request that changes a platform's capability.

Platform detail lives in [Android parity matrix](android-parity-matrix.md),
[Windows development](windows-development.md#feature-parity-matrix),
[Linux development](linux-development.md) and
[desktop settings coverage](desktop-settings-parity.md). This table is the
cross-platform summary; those documents hold acceptance evidence.

Key: **Yes** implemented; **Partial** implemented with a gap tracked by the issue; **Limited** implemented as far as the OS allows, with the limit in Notes; **No** missing
(see the issue); **N/A** the OS cannot support it, with the reason in Notes.
watchOS is a capture companion (start/stop, complication, transfer to iPhone) and
is not listed per row. The `speak` CLI, MCP tools and automation socket/pipe are
row F35.

| # | Feature | macOS | iOS | Windows | Linux | Android | Issue | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| F01 | Global record hotkey (hold, toggle, double-tap) | Yes | N/A | Yes | Limited | N/A | | iOS uses Action Button/Controls; Android uses the Quick Settings tile and shortcut. Linux global shortcuts depend on the Wayland portal. |
| F02 | Custom action shortcuts | Yes | N/A | Yes | Yes | N/A | | No background key handling on iOS/Android. |
| F03 | Live streaming cloud transcription | Yes | Yes | Yes | Yes | Partial | #1590 | Android partials come only from the platform recogniser. |
| F04 | Batch cloud provider catalogue | Yes | Yes | Yes | Yes | Partial | #1636 | Android: OpenAI and Groq only. |
| F05 | Downloaded local transcription models | Yes | Partial | Yes | Yes | No | #1650 | iOS: WhisperKit/Apple on-device, no Hugging Face import. Android runtime assessment: #1593. |
| F06 | Platform on-device recogniser | Yes | Yes | N/A | N/A | Yes | | Apple Speech and Android `SpeechRecognizer` only; desktops use local models. |
| F07 | Remote cleanup (OpenRouter and native LLMs) | Yes | Yes | Yes | Yes | Yes | | |
| F08 | Local LLM cleanup | Yes | No | Yes | Yes | No | #1650 | |
| F09 | Custom cleanup prompt | Yes | Yes | Yes | Yes | No | #1591 | |
| F10 | Browse OpenRouter models picker | Yes | Yes | No | No | Partial | #1618 | Android has a searchable cleanup list only. |
| F11 | Dictation profiles | Yes | Limited | Yes | Yes | No | #1591 | iOS cannot see the frontmost app; profiles apply through keyboard handoff. |
| F12 | Vocabulary, corrections, pronunciation | Yes | Yes | Yes | Yes | No | #1626 | |
| F13 | Transcription language selection | Yes | Yes | Yes | Yes | No | #1627 | |
| F14 | History list and search | Yes | Yes | Yes | Yes | Partial | #1628 | Android has no search. |
| F15 | History filters (model, errors, dates) | Yes | Partial | Yes | Yes | No | #1628 | |
| F16 | History retry and audio playback | Yes | Yes | Yes | Yes | Partial | #1629 | Android retries but has no playback. |
| F17 | History sync | Yes | Yes | Yes | Yes | No | #1630 | Desktops use CloudKit Web Services. |
| F18 | Settings search | Yes | Yes | Yes | Yes | Yes | | |
| F19 | Command palette | Yes | N/A | No | No | N/A | #1619 | Mobile uses settings search and system Shortcuts. |
| F20 | Compare models | Yes | No | Yes | Yes | No | #1622 | |
| F21 | Voice output / read aloud | Yes | Yes | Yes | Yes | No | #1631 | |
| F22 | Voice edit of selected text | Yes | Yes | Yes | No | No | #1620 | |
| F23 | Hands-free and silence auto-stop | Yes | Yes | Yes | Yes | No | #1632 | |
| F24 | Insert text into other apps | Yes | Limited | Yes | Limited | Yes | | iOS and Android insert through their keyboards; Linux depends on AT-SPI/portal support. |
| F25 | Recording HUD / live text overlay | Yes | Yes | Yes | Yes | Partial | #1592 | iOS uses a Live Activity; Android needs the foreground-service notification. |
| F26 | Menu bar / tray presence | Yes | N/A | Yes | Yes | N/A | | Android equivalent is the Quick Settings tile. |
| F27 | Resources-in-use status | Yes | Yes | Yes | Yes | Yes | | #1473 is done. |
| F28 | Report an issue with diagnostics | Yes | Yes | Yes | Yes | No | #1633 | |
| F29 | Troubleshooting page | Yes | Partial | Yes | Yes | No | #1634 | iOS has Capture Health only. |
| F30 | Onboarding and permissions guide | Yes | Yes | Yes | Yes | Partial | #1639 | |
| F31 | API keys page | Yes | Yes | Yes | Yes | Yes | | |
| F32 | Provider credit balances | Yes | Yes | No | No | No | #1621 | |
| F33 | Configuration export/import and backup | Yes | Yes | Partial | Partial | No | #1635 | Desktops back up History (and Windows profiles) only. |
| F34 | Raw settings editor and config tools | Yes | No | No | No | No | #1608 | |
| F35 | Automation (CLI, MCP, App Intents) | Yes | Yes | Yes | Yes | Limited | | Android: tile and launcher shortcut; no CLI by design. |
| F36 | Usage insights dashboard | Yes | No | Yes | Yes | No | #1623 | |
| F37 | Opt-in analytics and crash reporting | Yes | Yes | No | No | No | #1624 | |
| F38 | Tip jar / paid access | Yes | Yes | No | No | No | #1625 | |
| F39 | Audio file import | Yes | Yes | Yes | Yes | Yes | | |
| F40 | Launch at login | Yes | N/A | Yes | Yes | N/A | | Mobile apps do not launch at login. |
| F41 | Updates | Yes | N/A | Yes | Yes | N/A | | Sparkle on Mac; MSIX App Installer and Flatpak repository on desktops; stores elsewhere. |
| F42 | Microphone selection | Yes | Partial | Yes | Yes | No | #1637 | iOS follows the system route. |
| F43 | Recording start/stop sounds | Yes | Yes | Yes | Yes | No | #1638 | |
| F44 | Per-app output target (profiles) / Focus overrides | Yes | Yes | Yes | Limited | N/A | | iOS uses Focus filters instead of app detection. Linux app detection depends on the Wayland compositor. Android keyboards always insert in the focused field. |
| F45 | Recording audio housekeeping | Yes | Yes | Yes | Yes | Partial | #1629 | Android deletes cloud audio after upload. |
| F46 | Send transcripts from phone to desktop | Yes | Yes | No | No | No | #1640 | Receiver on desktops, sender on Android. |
| F47 | Accessible names, IDs and recording announcements | Yes | Yes | Yes | Yes | Yes | | Owner passes tracked in #1399; see [accessibility](accessibility.md). |
| F48 | Learned auto-corrections | Yes | No | Yes | Yes | No | #1651 | Desktops share `DesktopHostCorrectionLearning`; iOS has automatic polish only. |
| F49 | Appearance settings | Yes | Yes | Yes | Yes | No | #1652 | Android always follows the system theme. |
| F50 | Keyboard / IME surface | N/A | Yes | N/A | N/A | Yes | | Desktops use hotkeys and direct insertion instead. |
