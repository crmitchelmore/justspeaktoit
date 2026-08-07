# Release notes

macOS releases use `scripts/generate-release-notes.mjs` to turn the commits and
changed-file summary between adjacent `mac-v*` tags into detailed, user-facing
notes. The generator calls the OpenAI Responses API with `gpt-5.6-luna` and
medium reasoning effort.

The release workflow writes two formats from the same source:

- Markdown for the GitHub release description.
- Escaped HTML for Sparkle's in-app update interface.

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
