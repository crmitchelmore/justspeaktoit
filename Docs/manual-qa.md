# Owner manual QA

Some issues can close only after the owner checks them on a physical iPhone,
Apple Watch or Mac, or makes a product decision. They are collected in one
checklist so the owner can work through them in a few device sessions and
submit every result with one click.

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

A linked issue closes only when every catalogue check for that issue passed in
the same submission and at least one of them has `final_gate: true`. The
workflow then posts a summary on the results issue and closes it. It skips a
results issue it has already processed.

## Maintaining the catalogue

- Group items by device session and order them to minimise setup changes. Give
  each check 3–7 imperative steps that use the app's exact labels, a single
  observable expected result, the build to use and a realistic `minutes`
  estimate.
- Set `final_gate: true` only when passing every check for that issue leaves
  nothing else to do before closing it.
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
