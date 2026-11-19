# Cancelled recordings

One shared setting, **Keep audio when a recording is cancelled**
(`ApplicationPreferenceKey.keepAudioOnCancel`, default on), decides what
happens to the audio when the user cancels a recording. It is defined once in
`SpeakCore` (`SpeechDefaults.keepAudioOnCancel` and the `General`
`DesktopConfiguration` field in `CaptureDeliveryPreference`) and travels with
configuration transfer and data migration under the same key on every platform.
Search keywords: cancel, discard, keep audio, delete recording.

| Setting | Result |
|---------|--------|
| On (default) | The audio is kept and appears as a cancelled recording that can be played or transcribed later. |
| Off | The audio is deleted and nothing is added to History. |

The default is on everywhere: cancelling is often accidental (Escape), and a
kept recording can be deleted, while a deleted one cannot be recovered. It keeps
the previous Windows/Linux behaviour; Mac, iOS and Android previously deleted
the audio.

Only an explicit user cancellation of a recording follows the setting. Startup
failures, capture failures, leaving the app on Android and app shutdown keep
their own rules. Cancelling transcription of an already finished recording
still keeps its audio.

## Platforms

- **Mac:** Settings › Keyboard. Escape and the HUD/hands-free cancel call
  `MainManager.cancelRecordingByUser`. When on, the History entry carries the
  audio, so **Reprocess with Current Model** transcribes it. When off, the file
  is deleted and no History entry is written. An empty file is never kept.
- **iOS:** Settings › Recordings › Keep Audio When Cancelled.
  `AudioRecordingPersistence.cancelRecording()` reads the setting at cancel
  time. A kept file stays in **Saved Recordings**, which lists every file in
  the recordings directory, with **Transcribe**. Recordings under 0.5 s or with
  no audio are deleted. The capture's safety claim is always dropped, because
  the user chose to cancel it.
- **Windows/Linux:** Settings › General (generic `DesktopConfiguration`
  editor). When on, the History record stays with "Recording cancelled. Audio
  retained." and can be retried. When off, the host removes the record and its
  audio through the History deletion path. See
  [desktop-settings-parity.md](desktop-settings-parity.md).
- **Android:** Settings. Only Cloud mode records audio. When on, a cancelled
  Cloud recording moves to `filesDir/recordings/` and History shows a Cancelled
  entry with **Transcribe**. Deleting, clearing or pruning History deletes that
  audio. On-device and Speech Service modes produce no audio file.

Manual verification: `mac-keep-audio-on-cancel` and
`iphone-keep-audio-on-cancel` in [manual-checks.yml](manual-checks.yml).
