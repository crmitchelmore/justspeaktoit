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

Check desktop and mobile layouts, full-size screenshot links, reduced motion, keyboard-operated provider/roadmap disclosures, images and the console. Verify explicit Apple Silicon/Intel links and automatic architecture selection. With JavaScript disabled, screenshots and all release/roadmap content remain readable; automatic downloads default safely to the universal build.

## Deployment

`.github/workflows/deploy-landing-page.yml` tests and builds the site, then publishes `landing-page/dist/` to the existing Cloudflare Pages project `justspeaktoit` when website changes merge to `main`. Normal repository PR/review gates apply. Cloudflare serves `privacy.html` at `/privacy`; `_redirects` preserves the Mac downloads and Sparkle feeds. `.well-known/` contains the existing Apple association and Tesla public-key files. `npm run build` copies the complete set of public assets for standalone deployments.

## Content maintenance

Cache policy lives in `_headers`, including explicit HTML/CSS/JS revalidation. The old `_routes.json` is deliberately excluded: it contains a `routes`/`headers` shape, but Cloudflare uses that filename for Functions `include`/`exclude` routing, not static response headers. This site has no Functions. See [Cloudflare routing](https://developers.cloudflare.com/pages/functions/routing/) and [headers](https://developers.cloudflare.com/pages/configuration/headers/).

- `index.html`: content, release highlights, roadmap disclosures and download links.
- `site.css`: responsive layout, design tokens, typography and reduced-motion support.
- `download-architecture.js`: existing architecture detection and safe universal fallback.
- `images/`: actual Mac and iPhone app screenshots.

The updates area is deliberately small and static: it works without a GitHub request, JavaScript or API quota. Update it during a website/release editorial pass, using **published** GitHub releases (exclude drafts). The September 2026 selection is sourced from `mac-v3.0.0`, `mac-v2.72.1` and `mac-v2.71.0`. Dates and version labels link directly to those releases. Mac and iOS delivery remain separate tracks.

Roadmap entries link to the current work in issues #661 (keyboard), #657 (Watch), #655 (CLI) and #656 (MCP). Recheck their labels, comments and release/device evidence before changing statuses. Implementation or an open issue is not proof of general availability; avoid promised dates. Verify App Store availability before adding store badges or replacing the iOS release-information link.

The design uses the locally available official Claude `frontend-design` skill: expressive Cabinet Grotesk typography, the app’s charcoal, orange and lagoon palette from `Sources/SpeakCore/BrandColors.swift`, and real native app captures, with quiet supporting sections. Screenshots open as ordinary full-size image links without requiring JavaScript. Capture provenance is recorded in `images/README.md`.

All brand icons come from `scripts/generate-icon.swift`. See `Resources/Brand/README.md` for native sizes, appearance variants and regeneration. The SVG favicon is also used as the header/footer and privacy-page mark; PNG fallbacks, an Apple touch icon and a web manifest cover browser and Home Screen surfaces.
