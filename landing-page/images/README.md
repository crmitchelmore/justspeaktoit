# Image provenance

## Native screenshots

The PNG screenshot files below show native app UI, not HTML reproductions or generated mockups.

- mac-history-sample.png / .webp and mac-dashboard-sample.png / .webp:
  1080 × 720 native window captures (1× display, never upscaled) taken on
  2 November 2026 by `.github/workflows/site-media.yml` on a hosted macOS
  runner. Debug build of main just after the 3.2.0 release, isolated CoreJourney launch profile
  with the `SPEAK_CORE_JOURNEY_SITE_MEDIA` fixture
  (`Sources/SpeakApp/CoreJourneySiteMediaFixture.swift`): five fictional
  History entries, no credentials, no network providers. The runner grants no
  privacy permissions, so the dashboard honestly shows them as not granted.
  The WebP copies are `cwebp -q 90` encodes of the PNGs.
- ios-history-current.png: 1320 × 2868 PNG exported directly by Simulator on
  9 September 2026. Current branch, iPhone 17 Pro Max, iOS 26.2, ad-hoc signed
  Debug app. History was seeded with five fictional entries in an isolated
  simulator; these are sample copy, not customer transcripts or usage claims.

## Marketing clips (`clips/`)

Seven narrated, captioned clips: `hero` (Mac), `corrections`, `history`,
`models`, `iphone`, `windows` (beta) and `linux` (beta), each in a `-light`
and a `-dark` variant. Each variant has an H.264/AAC `.mp4`, an AV1/Opus
`.webm` and a WebP poster; both variants share one timeline, so they share one
WebVTT `.en.vtt` caption track and one narration. `manifest.json` lists
durations, sizes and alt text; `desktop-source.json` names the exact Windows
and Linux runs used.

They are rendered by `scripts/site-media/render-clips.py` in the `render` job
of `.github/workflows/site-media.yml`, only from footage captured on
GitHub-hosted runners, never the owner's machine:

- Mac: the full-screen recording of the real Debug app driven by
  `Tests/SpeakAppUITests/SiteMediaCaptureUITests.swift` with the same fixture:
  the shortcut double-tap is sent by the test driver, the audio is a synthetic
  clip, a test fixture returns fixed text, and Clipboard output mode is used
  because the runner cannot grant Accessibility. It also tours Transcription,
  Post-processing and Corrections (three fictional rules). Scenes are cut at
  the test's marks and cropped 1:1 to the window frames it records; frames are
  never enlarged or retouched. The capture runs twice, with the app's
  Appearance set to Light and to Dark.
- iPhone: full-screen screenshots of the Debug app in an owned Simulator, set
  to light and then dark appearance, saved by
  `Tests/SpeakiOSUITests/SiteMediaCaptureUITests.swift` at each step and shown
  as unretouched stills. (`simctl io recordVideo` writes variable-frame-rate
  video that drifts 9-17 s from the test clock, so it cannot be cut reliably.)
  The Simulator transcript hook returns fixed fictional text instead of a
  microphone and transcriber, and the narration says so.
- Windows and Linux: unretouched page screenshots from the native apps'
  `--ui-screenshots` tours in `windows.yml` and `linux.yml` (sample History),
  fetched from the newest successful `main` run whose job ran on a hosted
  runner by `scripts/site-media/fetch-desktop-tours.py`. Each variant uses the
  tour's light or dark page; the recording overlay is dark in both, as in the
  apps. Where a tour has no light recording page, the light variant shows the
  Keyboard (shortcut) page instead.

Title cards, the platform badge and narration are the only additions; there is
no music. Narration is the caption text spoken by the Piper TTS voice
`en_GB-cori-high` (Piper is GPL-3.0 and runs only in CI; the voice was trained
on public-domain LibriVox recordings, see its model card in
`rhasspy/piper-voices`). The model is pinned by SHA-256 and its two noise
generators are seeded, so the same text renders the same audio. Physical
iPhone Action Button, Live Activity and Apple Watch shots need the owner and
are tracked in the /qa checklist (#1368).

To regenerate for a release: run the Site Media Capture workflow, download its
`site-clips-*` artifact and copy the files into `clips/`. Locally,
`python3 scripts/site-media/render-clips.py <captures> <output> --voices <dir>`
re-renders from downloaded capture artifacts (needs ffmpeg and
`scripts/site-media/requirements.txt`).

The page loads no clip data until someone presses play (`preload="none"`).
`clips.js` serves the variant matching the visitor's `prefers-color-scheme`,
switches it live (keeping the playback position) when the scheme changes, and
defers each poster until its clip nears the viewport; without JavaScript the
`<source media>` queries pick the variant. PAGE_WEIGHT

Earlier captures that showed the developer's own usage and dictation
(app-dashboard.png, app-history.png) and superseded captures were removed.
Regenerate media by running the Site Media Capture workflow and copying from
its artifact.

The website links screenshots to the original image for full-size viewing.
Do not enlarge raster screenshots beyond their captured pixel dimensions or
alter controls/text in an image editor. Recapture the actual app to update UI.


## HDR wordmark asset (not a screenshot)

`wordmark-white-1.5x.jpg` is a locally authored 64 × 64 uniform-white SDR JPEG
with an embedded uniform gain map, encoded with Google libultrahdr commit
`66821e0a261aa3a06c0e7c889f52eced52850be1`. ISO 21496-1 and XMP metadata cap
both gain and capacity at 1.5× (+0.585 stop). It contains no native capture,
logo artwork or personal data. Its SHA-256 is
`511edb2c416eb20f902d7b6c5015063ee1169ea9b34c085e02b07a9cc5406d32`.

Keep this gain-map JPEG byte-for-byte through the static build. Do not apply
screenshot recapture rules, resize it or run it through an SDR-only image
optimiser. Replacements must retain a white SDR base and verified 1.5× gain-map
metadata; verify the built asset identity with `npm test`. Only existing small
header/footer wordmarks consume it; physical HDR luminance is not verified by
headless browser tests.
