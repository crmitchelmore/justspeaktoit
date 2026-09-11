# Just Speak to It website

Static HTML, CSS and JavaScript for [justspeaktoit.com](https://justspeaktoit.com). No framework or runtime dependencies. Typography uses Cabinet Grotesk and General Sans from Fontshare, with local fallbacks.

## Development and checks

```sh
cd landing-page
bun run dev                     # http://localhost:3000
npm test                        # architecture-aware download behaviour
npm run build                   # complete deployable site in dist/
```

Without Bun, `python3 -m http.server 3000 --directory landing-page` serves the source from the repository root. Python's server does not emulate Cloudflare's extensionless `/privacy` route or `_redirects`; use `/privacy.html` locally.

Check desktop and mobile layouts (360 px to wide desktop, no horizontal scroll), full-size screenshot links, reduced motion, keyboard focus order, images and the console. Verify explicit Apple Silicon/Intel links and automatic architecture selection. With JavaScript disabled every section still reads, the hero example still shows its sentence, and automatic downloads default safely to the universal build.

## Deployment

`.github/workflows/deploy-landing-page.yml` tests and builds the site, then publishes `landing-page/dist/` to the existing Cloudflare Pages project `justspeaktoit` when website changes merge to `main`. Normal repository PR/review gates apply. Cloudflare serves `privacy.html` at `/privacy`; `_redirects` preserves the Mac downloads and Sparkle feeds. `.well-known/` contains the existing Apple association and Tesla public-key files. `npm run build` copies the complete set of public assets for standalone deployments.

## Content maintenance

Cache policy lives in `_headers`, including explicit HTML/CSS/JS revalidation. Production builds also fingerprint the stylesheet filename and rewrite its HTML reference, so a cached older CSS response cannot break a newly deployed layout. The old `_routes.json` is deliberately excluded: it contains a `routes`/`headers` shape, but Cloudflare uses that filename for Functions `include`/`exclude` routing, not static response headers. This site has no Functions. See [Cloudflare routing](https://developers.cloudflare.com/pages/functions/routing/) and [headers](https://developers.cloudflare.com/pages/configuration/headers/).

- `index.html`: content and download links.
- `site.css`: responsive layout, design tokens, typography and reduced-motion support.
- `download-architecture.js`: existing architecture detection and safe universal fallback.
- `voice-motion.js`: the one-shot hero animation; it is progressive enhancement only.
- `images/`: actual Mac and iPhone app screenshots.

## Claims and their sources

Every product claim on the page is traceable to code or a doc in this repository. Rewrite the source alongside the claim, never the claim alone.

| Section | Sourced from |
| --- | --- |
| Hero, "How it works" | `Sources/SpeakHotKeys/HotKeyTypes.swift` (Fn / custom shortcut, hold + double-tap), `Sources/SpeakApp/TextOutput.swift` and `Docs/mac-background-hotkeys-and-output.md` (captured target, clipboard restore, App Store clipboard-only) |
| "There is no server in the middle" | `Sources/SpeakCore/SecureStorage.swift`, `Sources/SpeakCore/ModelCredentialRequirement.swift`, `Sources/SpeakCore/AppleLocalModels.swift`, `Sources/SpeakApp/FluidAudioModelManager.swift`, `Docs/PRIVACY.md` |
| Provider counts | `Sources/SpeakCore/ModelCatalog.swift` (live 13 providers / 19 models; batch 13 providers plus WhisperKit and Parakeet; post-processing 20), `Sources/SpeakApp/TextToSpeech/TTSProtocol.swift` (7 macOS TTS providers, 116 built-in voices), `Sources/SpeakCore/VoiceOutputSettings.swift` (2 on iOS) |
| iPhone &amp; iPad | `Sources/SpeakiOS/Activity/TranscriptionIntents.swift`, `JustSpeakToItWidgetExtension/` (Control Center control, Live Activity with a working Stop), `Sources/SpeakiOS/Views/SettingsView.swift` (Hardware Trigger destinations), `Sources/SpeakCore/HandsFreeDictation.swift` |
| Automation | `Docs/automation.md`, `Sources/SpeakAutomationKit/` |
| Inside the app | `Sources/SpeakApp/Views/Settings/SettingsTab.swift`, `Sources/SpeakApp/Services/ShortcutManager.swift` |

Counts are stated as counts of the shipped catalogue and the page says so. If `ModelCatalog.swift` gains or loses a provider, update the numbers and the chips together.

## Deliberately not on the page

These exist in the tree but are flagged off, unverified, or not user-reachable. Do not add them without new evidence:

- Apple Watch app and complication (`TUIST_WATCH_APP` off by default).
- The iOS custom keyboard — issue #661 still has the physical-device matrix open — and in particular direct in-extension capture (`TUIST_IOS_KEYBOARD_DIRECT_CAPTURE` defaults to 0).
- The iOS home-screen widget, which is still Xcode's template.
- A share extension or share-sheet audio import: no such target exists. The Shortcuts action *Transcribe Audio File* is the real path.
- URL-scheme capture or x-callback-url. `Sources/SpeakiOS/Services/DeepLinkRouter.swift` only switches tabs.
- An Alpha release channel. `appcast.xml` and `appcast-arm64.xml` are architecture feeds, not quality channels.
- Live provider credit or balance display. Onboarding shows static free-tier text; cost is estimated locally.
- App Store availability and store badges. Verify before adding either.
- Mac to iPhone history sync: the two platforms use different CloudKit containers, so sync is within a platform family. *Send to Mac* is the cross-device path that genuinely works.

All brand icons come from `scripts/generate-icon.swift`. See `Resources/Brand/README.md` for native sizes, appearance variants and regeneration. The SVG favicon is also used as the header/footer and privacy-page mark; PNG fallbacks, an Apple touch icon and a web manifest cover browser and Home Screen surfaces.
