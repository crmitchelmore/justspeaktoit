# Settings persistence audit

Every user-configurable setting must have one owner, one storage path, and a
defaulting rule that only applies when there is no valid prior choice. This
document records the audit carried out for issue #642 and the rules the code now
follows.

## Rules

1. **One owner per setting.** A setting is owned by a settings object (or an
   explicitly named store below), never by screen-local `@State`. Settings
   screens bind to the owner; they never compute or reset stored values.
2. **Write on change.** Owners persist in `didSet`, so a change survives an
   immediate quit. Values seeded during `init` are persisted explicitly because
   Swift does not run property observers during initialisation.
3. **Defaults fill gaps only.** A default may be applied on first run, or when a
   stored value is missing, unknown, or unusable on the current platform. It
   must never replace a valid user selection — including when the user switches
   modes, saves an API key, or relaunches the app.
4. **Independent selections stay independent.** Local and remote transcription
   remember their own model and sub-mode.

## Owners and storage paths

| Area | Owner | Storage |
| --- | --- | --- |
| macOS app settings (appearance, transcription, output, hot keys, HUD, TTS, silence detection, sounds, post-processing, …) | `SpeakApp.AppSettings` | `UserDefaults` via `AppSettings.DefaultsKey` |
| iOS app settings (model selection, mode, language, behaviour, post-processing, hardware trigger, Live Activities, density) | `SpeakiOSLib.AppSettings` | `UserDefaults` (injectable for tests) |
| Live transcription model memory (both platforms) | `SpeakCore.LiveTranscriptionSelection` | `UserDefaults` keys `rememberedOnDeviceLiveTranscriptionModel`, `rememberedRemoteLiveTranscriptionModel` |
| API keys / credentials | `SpeakCore.SecureStorage` (`SecureAppStorage` on macOS) | Keychain service `com.github.speakapp.credentials` |
| Downloaded local models and imported sources | `LocalModelManager`, `LocalPostProcessingModelManager` | JSON marker files in Application Support |
| Dictation profiles | `DictationProfileStore` | JSON on disk |
| Personal lexicon, pronunciation, auto-corrections | `PersonalLexiconService`, `PronunciationManager`, `AutoCorrectionTracker` | JSON on disk |
| History | `HistoryManager` / `HistoryWALStore` (iOS: `iOSHistoryManager`) | Write-ahead log + JSON |
| OpenClaw (iOS) | `OpenClawSettings` | `UserDefaults` (`openclaw.*`) |

`SessionProfileApplier` applies session-scoped dictation-profile overrides with
`suppressesPersistence`, so those temporary values never reach `UserDefaults`
and never enter the live model memory.

## Defects found and fixed

| Defect | Effect | Fix |
| --- | --- | --- |
| One stored slot held both the on-device and the remote streaming model | Choosing Local overwrote a remote choice; returning to Remote fell back to the catalogue default (Deepgram), losing Soniox | `LiveTranscriptionSelection` remembers a model per placement; both platforms restore it |
| Local ↔ remote switching lived in settings-screen bindings | Untestable, and each screen re-derived defaults | Switching moved onto `AppSettings` (`selectTranscriptionLocation`, `selectRemoteTranscriptionMode`, `selectLocalTranscriptionSource`) |
| Returning to Local always selected Apple Speech (macOS) | A downloaded local model choice was lost | `rememberedLocalTranscriptionSource` restores the last local source |
| Returning to Remote always selected streaming | A Remote Batch preference was lost | `rememberedRemoteTranscriptionMode` restores the last remote sub-mode |
| iOS `reconfigureDefaultProvider()` ran on every saved Deepgram key | Saving a key moved the user onto Deepgram even after they chose another provider | Only applies when no remote model is remembered |
| macOS launch auto-configuration treated "currently Apple" as "not chosen" | A deliberate Apple Speech selection was replaced by Deepgram on every launch when a key existed | Guarded by `hasExplicitLiveTranscriptionModelChoice` (a stored choice) |
| iOS `AppSettings` was pinned to `UserDefaults.standard` | Persistence could not be tested; tests duplicated the logic instead | `init(defaults:loadsSecureStorage:)` seam |

## Coverage

- `Tests/SpeakCoreTests/LiveTranscriptionSelectionTests.swift` — placement
  resolution, defaults-only-when-missing, platform filtering, relaunch.
- `Tests/SpeakAppTests/TranscriptionSelectionPersistenceTests.swift` — macOS
  mode switching, relaunch restoration, independent local/remote selections.
- `Tests/SpeakiOSTests/TranscriptionSelectionPersistenceTests.swift` — the same
  behaviour on iOS, plus API-key saving and representative settings round-trips.
