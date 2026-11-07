# Android entry and output surfaces

Assessment for epic #1328: how Android replaces the Mac's global hotkey and auto-paste. Android
deliberately prevents apps from recording in the background or typing into other apps, so the
app does not promise unrestricted cross-app insertion.

| Surface | Decision | Status | Notes |
| --- | --- | --- | --- |
| Quick Settings tile | **Ship** | Done | `DictateTileService` opens the app and starts dictation, unlocking the device first if needed. It cannot record from the shade: Android requires a visible foreground app to start the microphone. |
| Launcher shortcut | **Ship** | Done | A dynamic "Dictate" shortcut (long-press the icon, or pin it). |
| Private start entry | **Ship** | Done | The tile and shortcut use the non-exported `DictateEntry` alias, so other apps cannot start the microphone by launching the exported Activity. |
| Share target (audio in) | **Ship** | Done | Shared MP3, M4A, WAV, OGG/Opus, WebM or FLAC up to 25 MB is transcribed with the chosen cloud model, after the user confirms the upload. On-device recognisers cannot read files on the supported Android versions. |
| Share sheet (text out) | **Ship** | Done | Share a final transcript from the main screen or History. |
| Clipboard (text out) | **Ship** | Done | Copy; Android 13+ shows the system confirmation. |
| Input method (IME) | **Planned, next** | Not started | The Android equivalent of auto-paste: a minimal keyboard with a microphone key that commits the final transcript with `InputConnection.commitText` into the focused field. It runs in the foreground while visible, so it can record. Its scope is on-device and speech-service recognition first, with no cloud uploads from the keyboard until the privacy UX has been reviewed. It needs its own physical-device qualification with password fields (`TYPE_TEXT_VARIATION_PASSWORD` must disable dictation). |
| Accessibility-service insertion | **Rejected** | n/a | Google Play restricts accessibility APIs to accessibility use cases, and the permission would let the app read every screen, which is out of proportion for dictation. |
| Home-screen widget | **Deferred** | n/a | It would duplicate the tile and shortcut. Revisit if users ask for it. |
| Assistant / voice-action intents | **Deferred** | n/a | `RECOGNIZE_SPEECH` provider integration is a later option once the IME exists. |
| Hardware keys / headset button | **Deferred** | n/a | `MediaSession` button capture conflicts with media apps; it needs device testing before any promise. |

## Behaviour common to every surface

- Every start goes through the same availability check. If the selected mode is unusable, nothing
  starts and the main screen shows why; the app never falls back silently to the cloud.
- Leaving the app ends capture as a visible failure. That session is recorded in History with
  its unfinished words.
