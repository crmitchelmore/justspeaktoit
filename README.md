# QA evidence: mac-website-voiceover (#1400), 2026-11-11

Agent QA on Linux (no VoiceOver). See `results.json` for the verdict and note,
`reports/production-report.json` (justspeaktoit.com) and
`reports/fixed-build-report.json` (local build of the fix PR) for per-page data,
and `reports/audit.mjs` for the Playwright + axe-core harness.

Screenshots: `<browser>-<page>-<scheme>-01-skiplink.png` (first Tab),
`…-focus-NNN.png` (Tab stop NNN), `…-axe-fail.png`, `qa-arrow-keys-*` and
`download-label-in-name-*` (defect vs fix), `fixed-local-*` (fixed build).
