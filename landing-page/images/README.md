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
- demo/speak-demo.mp4, .webm, .en.vtt and speak-demo-poster.webp: a 36-second
  silent cut of the same run's full-screen recording (`screencapture -v`),
  rendered by `scripts/site-media/render-demo.py` from the UI test's scene
  marks. Only waiting time is removed; kept frames are unedited. The audio is a
  synthetic clip, the transcription is a test fixture returning fixed text, the
  shortcut double-tap is sent by the test driver, and Clipboard output mode is
  used because the runner cannot grant Accessibility. The captions say so.
- ios-history-current.png: 1320 × 2868 PNG exported directly by Simulator on
  9 September 2026. Current branch, iPhone 17 Pro Max, iOS 26.2, ad-hoc signed
  Debug app. History was seeded with five fictional entries in an isolated
  simulator; these are sample copy, not customer transcripts or usage claims.

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
