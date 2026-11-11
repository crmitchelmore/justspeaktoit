# API key creation guidance

Speak helps people create provider keys with the least access its features
need. The single source is `APIKeyGuidance` in SpeakCore
(`Sources/SpeakCore/Credentials/APIKeyGuidance.swift`, provider table in
`APIKeyGuidanceProviders.swift`). Every surface reads it:

| Surface | Where |
|---|---|
| Mac Settings › API Keys | `SettingsView+APIKeys.swift`, collapsed `APIKeyGuideDisclosure` per card |
| Mac onboarding | `OnboardingView.swift`, step 2 |
| Mac missing-key alerts | `MissingLiveAPIKeyAlert.message` / `keyPageURL` |
| iOS Settings › API Keys | `APIKeysView.swift`, disclosure per section |
| iOS missing-key alert | `MissingTranscriptionAPIKeyAlert.swift` |
| Windows and Linux API Keys | `DesktopAPIKeyRow.entryHint` from `APIKeyCatalogEntry.setupHint` |

## Rules

- One guide per stored credential identifier. A guide lists the requests Speak
  actually makes for each use (`APIKeyUses`), plus the key check every save
  runs. A surface passes only the uses it offers, so a transcription-only card
  never asks for voice permissions and a shared key shows the union.
- Optional extras, such as balance lines, are marked `isOptional` and never join
  the minimum. Do not raise a role, add billing access or use a management key
  to make them work.
- Creation links are plain console pages. No provider documented a link that
  preselects permissions as of the last check, and every guide says so. Do not
  add URL parameters unless the provider documents them.
- Expiry has three parts, kept apart: whether the provider offers a setting
  (`APIKeyExpirySetting`), what the provider itself recommends
  (`providerRecommendation`, nil when none is published) and Speak's own advice
  (`APIKeyGuidance.appAdvice`, labelled as Speak's).
- Replacing a key reuses the same credential identifier, so selected models,
  prompts and voices stay in place. Guides never contain secrets.

## Updating

Check each provider's linked `sources`, change the entry, and move
`APIKeyGuidance.lastVerified` to the date of that check. `APIKeyGuidanceTests`
fails when a known credential has no guide, a link is not plain HTTPS, an
optional check widens the minimum, a limitation is not stated, or a desktop
hint exceeds the Windows 512-character limit.

The permission names come from provider documentation. They have not been
checked against every combination with restricted test keys; a guide must not
call a combination verified until someone has.
