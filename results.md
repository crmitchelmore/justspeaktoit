# QA: PR #1487 — Android "System resources in use" (#1473)

- **PR head:** `4a5a8ac63fd01243df362ab435b6e66bbc577b2a` (`feat/1473-android-system-resources`)
- **APK:** `app-debug.apk` built by GitHub-hosted `precheck.yml` run 43019078067
  (`scripts/ci-android.sh`: testDebugUnitTest + lintDebug + assembleDebug all passed). The local build
  couldn't run because the CFS proxy (`packagefeedproxy.microsoft.io/maven/`) returns 404 for every
  Maven artefact. The throwaway `precheck/qa-android-1487` branch was deleted afterwards.
- **Device:** dedicated emulator `QA_1487_API_35` (Pixel 7, Android 15, google_apis_playstore x86_64,
  `emulator-5556`, host audio), driven with T3 `agent-device`. adb was used only for install, logcat,
  `dumpsys audio`/`appops` reads, enabling the app IME and a temporary black-hole HTTP proxy.
- **Date:** 2026-11-11

## Results

| # | Check | Result | Evidence |
|---|-------|--------|----------|
| 1 | Settings shows "System resources in use" with an idle headline ("Not holding any system resources") and a disabled "Release everything" | PASS | `02-settings-idle.png` |
| 2 | Settings search finds it ("resources in use" → "System resources in use, General"); tapping the result scrolls to the section | PASS | `03-settings-search.png`, `04-search-result-scrolled.png` |
| 3 | Dictation (Speech service): the mic is captured (`dumpsys audio`: rec start/stop `src:VOICE_RECOGNITION`, `com.google.android.tts`) and stops cleanly | PASS | `05-dictating-speech-service.png` |
| 4 | Dictation (Cloud, in-app AudioRecord): `appops RECORD_AUDIO` shows running while recording and stops on Stop and on Cancel | PASS | `11-cloud-recording.png`, `12-cloud-after-stop.png` |
| 5 | The main-screen "Dictation recording" mic hold is visible in Settings while recording | NOT REACHABLE | The Settings and History buttons are disabled while a dictation is active (pre-existing, #1343), so this hold can never be seen or released from Settings; it's covered by unit tests only |
| 6 | Keyboard dictation (app IME in the Settings search field) is listed live: "Microphone in use: Keyboard dictation", "Microphone · for 1 s", "Stop listening" | PASS | `06-keyboard-dictation-hold.png`, `07-keyboard-hold-before-release.png`, `09-before-release-everything.png` |
| 7 | Per-row release ("Stop listening") stops capture: rec stop about 1.7 s after start, before the 5 s recogniser timeout; the hold clears | PASS | `08-keyboard-after-release.png` |
| 8 | "Release everything" stops keyboard capture (rec stop about 2.3 s after start); the section returns to idle | PASS | `09-…`, `10-after-release-everything.png` |
| 9 | Cloud request hold (History › Transcribe kept audio, held open by a black-hole proxy): "Holding 1 resource", "Cloud request · Provider connection · for 15 s · Waiting for OpenAI to answer", "Cancel request" | PASS | `13-cloud-request-hold.png` |
| 10 | "Cancel request" ends the hold immediately | PASS | `14-cloud-request-released.png` |
| 11 | What History reports after a user "Cancel request" | **FAIL (bug)** | `15-history-after-cancel-request.png`: "Transcription failed: The speech service could not be reached." A deliberate release is recorded as a network failure (and names the wrong service) |
| 12 | TalkBack labels: headline `settings.resources.headline` (live region); release buttons `settings.resources.release.<kind>` with content description "Stop listening: Keyboard dictation"; `settings.resources.releaseEverything` labelled "Release everything" | PASS | `a11y-keyboard-hold.json` |
| 13 | No app crashes or ANRs in logcat for the whole session | PASS | `logcat-app.txt` (no FATAL EXCEPTION or ANR for `com.justspeaktoit.android.debug`) |

## Bug (posted on PR #1487)

Releasing a Cloud request from Settings calls `CallHandle.cancel()`, which disconnects the
`HttpURLConnection`. `CloudClient` maps the resulting `IOException` to `DictationFailure.Network`, and
`transcribeHistoryEntry` saves that as `failure`. The same applies to the main-screen transcribe path.

## Other observations (not caused by this PR)

- The main-screen mic and Cloud request holds can't be seen in Settings, because navigation is
  locked during dictation. Only keyboard dictation and History transcription show up in practice.
- The dictation keyboard has no opaque background, so app text shows through behind the status text
  and buttons (visible in `06`/`09`).

## Re-test after fixes (2026-11-11, PR branch head `f6c56d2d`)

The fixes are pushed to `feat/1473-android-system-resources` as 164dafbb, d3c11528 and f6c56d2d. The APK came from precheck
run 43024357706 and was tested on the same API 35 emulator. Cloud requests were made to hang with a
black-hole HTTP proxy; a fake OpenAI key was used.

| # | Check | Result | Evidence |
|---|-------|--------|----------|
| R1 | Settings opens while dictating; the main-screen mic hold is listed and released | PASS | `16-settings-open-while-dictating.png` |
| R2 | A Cloud recording shows as a mic hold; Stop recording ends capture (appops no longer running) | PASS | `17`, `18` |
| R3 | Main-screen upload: Cancel request in Settings returns to Ready with no failed History entry | PASS | `19`–`22` |
| R4 | History › Transcribe: Cancel request leaves the entry unchanged ("Cancelled…", Transcribe still offered) | PASS (bug fixed) | `23`, `24` |
| R5 | Keyboard has an opaque background and sits clear of the navigation bar, in light and dark modes | PASS | `25`, `26` |
| R6 | No FATAL EXCEPTION or ANR in logcat | PASS | — |

Fixed in 1ee00576: releasing during a main-screen upload now keeps the recording when "Keep audio when a recording is cancelled" is on.

| # | Check | Result | Evidence |
|---|-------|--------|----------|
| R7 | Keep audio on: release the main-screen upload → Ready; History has a Cancelled entry with Transcribe; the WAV is in `files/recordings/` | PASS | `27`–`30` |
| R8 | Keep audio off: same steps → no new History entry, and the WAV is deleted | PASS | — |

The CI change that publishes precheck APKs is in #1491.

**Overall after fixes: PASS.**
