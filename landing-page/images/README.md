# Image provenance

## Native screenshots

The PNG screenshot files below show native app UI, not HTML reproductions or generated mockups.
Capture dates use Europe/London (BST, UTC+01:00): the captures made shortly after
midnight on 9 September are dated 8 September in UTC.

- mac-history-current.png: 1920 × 971 lossless PNG exported directly from the
  running native Mac window on 9 September 2026. Current Debug app, using the
  existing isolated CoreJourney launch profile, a private bundle identifier,
  private preferences and a five-entry fictional History fixture. No personal
  app data or credentials were used. The first session is expanded through the UI.
- ios-history-current.png: 1320 × 2868 PNG exported directly by Simulator on
  9 September 2026. Current branch, iPhone 17 Pro Max, iOS 26.2, ad-hoc signed
  Debug app. History was seeded with five fictional entries in an isolated
  simulator; these are sample copy, not customer transcripts or usage claims.
- app-dashboard.png: 2142 x 1416 native capture of the Mac Dashboard, taken
  from the developer's own running app in January 2026. The figures shown
  (session count, recorded time, spend) are that developer's real usage, not a
  claim about anyone else's. It predates the Profiles, Troubleshooting and
  About sidebar entries, so read it as a dashboard capture rather than a
  current settings inventory. Used in the "Inside the app" section.
- app-history.png: 2150 x 1412 native History capture from the same January
  2026 session. Deliberately NOT used on the website: the transcripts in it are
  the developer's real dictation, not a fixture, and there is no provenance
  record establishing otherwise. Use mac-history-current.png instead.
- ios-history.png: earlier native capture retained as an existing asset but no
  longer used on the page.
- mac-dashboard.png: earlier native dashboard capture, retained as an existing
  asset but no longer used on the page.

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
