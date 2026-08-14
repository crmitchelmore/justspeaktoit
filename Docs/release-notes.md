# Release notes

macOS releases use `scripts/generate-release-notes.mjs` to turn the commits and
changed-file summary between adjacent `mac-v*` tags into detailed, user-facing
notes. The generator calls the OpenAI Responses API with `gpt-5.6-luna` and
medium reasoning effort.

The release workflow writes three formats from the same source:

- Markdown for the GitHub release description.
- Escaped HTML for Sparkle's in-app update interface.
- A JSON catalogue bundled into the app for the in-app Release Notes screen.

`OPENAI_API_KEY` is stored as a GitHub Actions secret. If the secret, model, or
API is unavailable, the generator produces a deterministic changelog grouped by
conventional commit type so an otherwise valid release is not blocked.

## Generate notes locally

```bash
OPENAI_API_KEY="..." node scripts/generate-release-notes.mjs \
  --tag mac-v2.41.0 \
  --output /tmp/release-notes.md \
  --html-output /tmp/release-notes.html
```

The previous tag is discovered from Git ancestry within the same tag family.
Pass `--previous-tag <tag>` only when intentionally overriding that comparison.

## Backfill published releases

Generate a reviewable cache without changing GitHub:

```bash
OPENAI_API_KEY="..." node scripts/backfill-release-notes.mjs \
  --output-dir /tmp/justspeaktoit-release-notes
```

After reviewing the files, add `--apply` to update release descriptions. This
operation changes only the descriptions; it does not move tags or replace
release assets. Cached files are reused unless `--force` is supplied.

Use `--tag <tag>` to generate or apply one release. Legacy `v*`, macOS `mac-v*`,
and iOS `ios-v*` histories are kept separate when the previous tag is selected.

## Bundled in-app release notes

`Sources/SpeakCore/Resources/ReleaseNotes.json` ships inside the app so
**Settings → About → Release Notes** works offline on macOS and iOS. The file is
compiled into SpeakCore's resource bundle and read through
`ReleaseNotesCatalog.bundled`; `ReleaseNotesBrowser` selects the installed
version by default and keeps earlier versions browsable.

Every distribution workflow refreshes and then verifies the catalogue before
upload. The direct macOS release generates the new tag's notes before archiving
and runs the updater twice:

```bash
# 1. Restore the history released since the checked-in file was last refreshed.
node scripts/update-release-notes-catalogue.mjs --backfill --platform mac

# 2. Merge in the notes for the tag being released.
node scripts/update-release-notes-catalogue.mjs \
  --platform mac --version 2.46.0 --tag mac-v2.46.0 \
  --notes-file "$RUNNER_TEMP/release-notes.md"
```

The rebuilt catalogue lives only in the runner's checkout — the release job does
not commit it back to `main`. The backfill is what keeps the shipped history
complete: without it each release would merge a single entry onto whatever was
last committed, and every version released in between would be missing. The
checked-in file therefore only needs to be a reasonable starting point; run the
same backfill locally (it needs an authenticated `gh` CLI) when refreshing it:

```bash
node scripts/update-release-notes-catalogue.mjs --backfill --platform mac --limit 12
```

The Mac App Store workflow backfills the same `mac-v*` history and verifies the
archive against the explicit version, so direct and App Store builds show the
same notes. The iOS workflow requires a `release_notes_source_tag`; automated
paired releases pass their new `mac-v*` tag, while an iOS-only release must name
the existing `mac-v*` or `ios-v*` tag that describes its changes. It generates
from that tag, stores the entry on the iOS track, and verifies the archived app.

Entries are keyed by platform plus marketing version, sorted newest first and
capped at `--limit` per platform (12 by default). This keeps coincident macOS
and iOS version numbers distinct. Compare-URL footers and generator HTML
comments are stripped. Notes for a build that has not been released yet are
absent by design; the app then opens on the newest bundled version and says so.
A build older than every bundled entry simply says it is showing the latest
notes.
