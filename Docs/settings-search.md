# Settings search

Settings search finds any setting, settings card, API-key slot, model picker or
shortcut from one field, then opens its page and highlights it.

- **macOS:** press ⌘F, or click the magnifying glass in the toolbar, from
  anywhere in the main window. Type to see results and completions. Use ↑/↓ to
  move, Return to open and Tab to accept the first completion. Recent and
  suggested destinations appear before you type.
- **iOS:** pull down Settings to reveal the search field. Suggestions show
  recent and suggested destinations, then typeahead completions.

## One registry

`Sources/SpeakCore/SettingsSearch/` holds the single declarative index:

| Type | Purpose |
| --- | --- |
| `SettingsSearchEntry` | One destination: stable `id`, the exact on-screen `title`, `section`, summary, `keywords` (synonyms and control labels), `settingKeys` (persisted property names) and `platforms` |
| `SettingsSearchCatalog` | The canonical entries, page roots and suggested IDs, split by area into `SettingsSearchCatalog+*.swift` |
| `SettingsSearchIndex` | Ranked search (title > keyword > page > summary > setting name; synonyms, inflections and small typos) plus `completions(for:)` |
| `SettingsSearchRecents` | Recently opened entry IDs |

Hosts render from the catalogue. They don't keep their own lists:

- macOS `SettingsCard` and the Keyboard page's cards look themselves up by
  title and become scroll anchors with a reveal highlight. Cards with a
  computed heading pass `searchEntryID:`. API-key cards are indexed at runtime
  from the provider lists the API Keys page renders
  (`MacSettingsSearch.apiKeyEntries`).
- iOS Settings is a root list of sub-pages (`IOSSettingsPage`). Each page's
  sections use `SearchableSettingsSection("Title")` and are listed in that
  page's `sectionTitles`, which is how a search result opens the right page
  before scrolling to the section. API-key rows are indexed at runtime from
  `APIKeysView.entries(for:)`. `IOSSettingsPageTests` fails when a catalogue
  entry has no page.
- `SettingsTab.searchSection` and `MacSettingsSearch.sidebarItem(for:)` are
  exhaustive switches, so a new settings page doesn't compile until it is mapped.

## Adding a setting or settings view

1. Add or extend an entry in the right `SettingsSearchCatalog+*.swift` file.
   The `title` must match the card or section heading exactly. Add the property
   name to `settingKeys` and the words people would search for to `keywords`.
2. Mark only the platforms whose settings UI shows it.
3. Keep `id`s stable. They key recents and accessibility identifiers.

`Tests/SpeakAppTests/SettingsSearchCoverageTests.swift` fails when:

- a macOS `SettingsCard(title: "…")` or `ShortcutSettingsCard(title: "…")` has no
  macOS entry, or a card with a computed title omits `searchEntryID:`;
- an iOS Settings section uses a plain `Section("…")` or has no iOS entry;
- an `@Published` property of either platform's `AppSettings` isn't in some
  entry's `settingKeys`, unless it is exempted there with a reason;
- a `SettingsTab` has no searchable page root.

`Tests/SpeakCoreTests/SettingsSearchIndexTests.swift` covers ranking, synonyms,
typo tolerance, completions, recents and catalogue invariants (unique IDs and
titles, and each setting key owned once per platform).

## Raw configuration schema

`SettingsSchema` (`Sources/SpeakCore/SettingsConfiguration/`) describes every
persisted macOS setting for the raw editor (Settings › General › Advanced ›
**Edit raw configuration**) and the `get_configuration` / `set_configuration`
automation tools. Its keys are the same property names as `settingKeys` here,
and each field records the type, default, allowed values or range, platforms,
and whether it is read-only or sensitive.

Windows and Linux use `SettingsSchema.fields(for: .windows)` (`.linux` is the
same list), derived from `DesktopConfiguration.fields` in
`SettingsSchema+Desktop.swift`, so a new desktop preference joins the schema
and `speak config` with no extra entry. Mark consent and grants read-only there.

When you add a persisted macOS setting, also add a `SettingsSchema+macOS.swift`
field and an `AppSettingsConfiguration` binding.
`Tests/SpeakAppTests/AppSettingsConfigurationTests.swift` fails when an
`@Published` setting has no schema field (unless exempted there with a reason),
a schema key has no binding, a default disagrees with a fresh install or an
allowed value is rejected by the app. Secrets never enter the schema: API keys
are exported only as `apiKeys.<id>.isSet` (true or false).

## Accessibility

Result rows are single accessible buttons labelled with the title and page,
with the summary or matched keyword as the hint. Each has the identifier
`settingsSearchResult.<entry id>`. The macOS field is `settingsSearchField`,
the toolbar button is `settingsSearchButton`, and completions are
`settingsSearchCompletion.<n>`. The reveal highlight is decorative and hidden
from VoiceOver.

## Windows and Linux

`DesktopSettingsSearch` (SpeakCore) indexes every `DesktopConfiguration` field
automatically, adds catalogue entries marked `.windows` / `.linux` for
hand-built groups, and maps results to a `DesktopSettingsDestination` page and,
for a preference field, the field to reveal. Each host keeps one
`DesktopSettingsSearchSession`: the native window emits
`JSTI_EVENT_SETTINGS_SEARCH` as the query changes and
`JSTI_EVENT_SETTINGS_SEARCH_OPEN` when a row is chosen. Swift ranks the query,
then calls `jsti_window_set_settings_search_results`, `jsti_window_show_page` and
`jsti_window_reveal_configuration_field`.

`Tests/SpeakDesktopTests/DesktopSettingsSearchTests.swift` fails when an
`ApplicationPreferenceKey` isn't indexed (or exempted with a reason), or when a
native settings heading has no entry for its platform.

## Android

Kotlin can't read the Swift catalogue, so `SettingsSearchAndroidExport` writes it
(entries marked `.android`, plus the synonym groups) to
`android/app/src/main/assets/settings_search.json`.
`SettingsSearchAndroidExportTests` fails when that asset is stale. To regenerate
it, run:

```sh
UPDATE_SETTINGS_SEARCH_ANDROID=1 swift test --filter SettingsSearchAndroidExportTests
```

`scripts/update-android-assets` regenerates this asset and the cloud catalogue
(`cloud_catalog.json`) together.

`SettingsSearchIndex.kt` mirrors the Swift ranking rules and adds one entry per
`CloudCatalog` model and provider key. Settings has a search field with
completions, results, recents and scroll-to-highlight. Result rows use the test
tag `settingsSearchResult.<id>`. `SettingsSearchCoverageTest` fails when a
Settings heading string or an `AppPreferences` key is not indexed.
