# Batch merging (`scripts/merge-batch`)

Hosted macOS capacity is the bottleneck for landing PRs. Each PR's full CI
takes 30–90 minutes, mostly queueing. `scripts/merge-batch` works like bors:
it lands several ready PRs on one CI run, so the cost is one CI cycle per
batch rather than one per PR. It works for user-owned repositories, which
can't use GitHub's merge queue.

## How a batch lands

1. **Create.** `scripts/merge-batch create <name> <pr>...` starts from
   `origin/main` and squashes each PR's current head onto it, in order, as one
   commit titled `<PR title> (#N)`. A PR is skipped, and named in the batch
   PR body, if any of these hold:
   - it's a draft;
   - it targets a branch other than `main`;
   - GitHub reports it as conflicting;
   - its head moved during batching;
   - it conflicts with an earlier member.

   The command pushes `merge-batch/<name>` and opens or updates one batch PR.
   It records each member's head SHA in a hidden
   `<!-- merge-batch-member PR SHA -->` line, and copies each member's closing
   issue references as `Fixes #N` lines.

   The body also carries a `pre-pr-summary` record for the combined head SHA,
   so `Pre-PR evidence` accepts the batch. It is built from each member's own
   `scripts/pre-pr` record, and is `fail` if any non-bot member has none or a
   failing one. The combined tree itself is tested by the required checks.
2. **Test.** The batch PR is an ordinary same-repository PR, so the ruleset's
   required checks run once on the combined tree. Other path-triggered
   workflows (Windows, Linux, Flatpak, CodeQL and similar) skip their jobs on
   `merge-batch/*` heads: each member already ran them, and they run again on
   main after landing. `scripts/merge-batch status <name>` shows the gate; add
   `--wait` to block until it settles (exit 0 green, 1 red or timed out).
3. **Land.** `scripts/merge-batch land <name>` waits for the gate, then merges
   only if it is green and the batch PR is `CLEAN`. The gate is green when:
   - every status check the `main` ruleset requires (currently `CI Gate`) is
     reported on the batch head and passed (success, skipped or neutral). A
     required check that has not registered yet counts as pending, never as a
     pass, so a batch can't land in the seconds after a push;
   - every other workflow run on the head has finished green or skipped.
     Advisory workflows (Pre-PR evidence) and external ones (Tessl, OpenAI API
     Review) don't count; override the list with `MERGE_BATCH_IGNORED_WORKFLOWS`.

   `--no-wait` checks once instead. `MERGE_BATCH_TIMEOUT_MINUTES` (default
   150) and `MERGE_BATCH_POLL_SECONDS` (default 60) tune the wait, and
   `MERGE_BATCH_REQUIRED_CONTEXTS` (comma-separated) overrides the ruleset
   lookup. Once the gate is green, the command:
   - squash-merges the batch with `--match-head-commit`;
   - names the batch commit after the most user-visible member type
     (`feat` > `fix` > `perf` > others);
   - lists every member's title in the batch commit body, so release notes
     still see each change;
   - closes each member PR with a link to the batch commit, provided its head
     still matches the recorded SHA. A member whose branch moved stays open,
     with a comment.

   GitHub closes issues referenced as `Fixes #N` in the batch PR body.
4. **Bisect on failure.** `scripts/merge-batch split <name>` closes a failing
   batch and opens `<name>a` and `<name>b` from its two halves. Repeat until
   the failure is down to one PR, then return that PR to its author. A
   failure caused by infrastructure (runner timeout, download error,
   cancellation) is rerun instead of split.

## Constraints

- The `main` ruleset (squash only, linear history, required checks) is
  unchanged. Nothing is pushed to `main` directly: a batch lands only through
  its own PR, after its required checks pass.
- Review each member's diff for public-repository risks before batching it, as
  for a direct merge: secrets, `pull_request_target`, and unpinned or
  untrusted actions.
- Batching doesn't rebase or update member branches. Members don't need to be
  up to date with `main`.
- Self-hosted routing is unchanged. A batch runs on hosted runners unless the
  owner approves its head SHA through `JSTI_NATIVE_APPROVED_SHA`.
- Pushing and opening PRs needs `gh` authentication with `contents` and
  `pull_requests` write access. Set `MERGE_BATCH_REPO` and
  `MERGE_BATCH_REMOTE` to use another repository or remote.
