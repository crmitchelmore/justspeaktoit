# Owner manual QA

Some issues can close only after the owner checks them on a physical iPhone,
Apple Watch, Mac or Android phone, or makes a product decision. They are collected in one
checklist so the owner can work through them in a few device sessions and
submit every result with one click.

Human checks never block a pull request or merge. Add a check to the
catalogue in the same PR as the change it validates; after merge, the first
Alpha containing it lists it under **Please test** in its release notes and
TestFlight "What to Test" (see
[alpha-stable-release-trains.md](alpha-stable-release-trains.md#please-test-human-checks)).
Write `build` as the Alpha that includes the change, for example "Alpha build
that includes #123". Ids starting `owner-` and decisions are owner-only and are
left out of Alpha notes.

- **Checklist:** <https://justspeaktoit.com/qa> (noindex). Answers are saved in
  the browser's local storage, so the owner can stop and resume.
- **Catalogue:** [`Docs/manual-checks.yml`](manual-checks.yml) is the single
  source of truth. The website build renders it, and the results workflow
  validates submissions against it.
- **Results:** Submit opens a prefilled GitHub issue labelled
  `manual-qa-results`. If the link would be too long, the results are copied to
  the clipboard and the issue opens with a placeholder to replace with them.
  [`manual-qa-results.yml`](../.github/workflows/manual-qa-results.yml) then
  processes the issue.

## How results are applied

The workflow runs only when both the issue author and the event sender are
`crmitchelmore` or `bravostation` and the issue has the `manual-qa-results`
label. It has `issues: write` and reads the issue body as data only:
[`.github/scripts/manual-qa-results.mjs`](../.github/scripts/manual-qa-results.mjs)
strictly parses the one fenced `manual-qa-results` JSON block. If an ID,
result, choice or note is unknown or malformed, the workflow comments with the
reason and changes nothing else.

For each linked issue it posts one comment:

- **Pass:** the check title, the build and the expected result as evidence.
- **Fail:** the expected result and the owner's note. In the note, mentions and
  `#123` references are neutralised.
- **Skip:** no comment.
- **Decision:** the question and the chosen option.

A linked issue closes only when every catalogue check with `final_gate: true`
that lists it passed in the same submission and none of its checks failed.
Other passes add evidence but never close an issue on their own. The
workflow then posts a summary on the results issue and closes it. It skips a
results issue it has already processed.

## Maintaining the catalogue

- Every item must close or materially unblock an issue. Mark it `core: true`
  when it should be done in the owner's next session, or `core: false` to
  collapse it under Optional. Keep core time within about 40 minutes for the
  iPhone and Android, 15 each for the Watch and Mac, and 10 for decisions. The page shows
  core minutes by device at the top.
- Prefer one end-to-end scenario that verifies several issues (`issues:` takes
  up to 8 numbers) over separate checks. Drop checks for behaviour already
  covered by tests.
- Group items by device session and order them to minimise setup changes. Give
  each check 3–7 imperative steps that use the app's exact labels, a single
  observable expected result, the build to use and a realistic `minutes`
  estimate.
- Set `final_gate: true` only when passing it, together with the other final
  gates for the same issues, leaves nothing else to do before closing them.
- Decisions need 2–4 options, exactly one of them `recommended: true`, and a
  one-line consequence for each option.
- After a submission closes an issue, remove that issue's checks. Keep IDs
  stable while an issue is open, because saved answers and submitted results
  refer to them.
- The parser accepts a strict YAML subset: 2-space indentation, double-quoted
  JSON-escaped strings, integers and booleans, with no flow collections or
  block scalars. `node --test scripts/tests/manual-qa-results.test.mjs` and
  `cd landing-page && npm test` validate the committed catalogue.
- Never include secrets, keys, billing details or personal data. The
  repository and the page are public.
