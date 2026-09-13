# Streaming insertion verification

This runbook qualifies progressive Accessibility insertion in the two apps in
the current allowlist: TextEdit (`com.apple.TextEdit`) and Notes
(`com.apple.Notes`). All other apps retain one-shot final delivery. Issue
[#611](https://github.com/crmitchelmore/justspeaktoit/issues/611) owns any
allowlist expansion; do not temporarily allowlist another app for this run.

The source of truth for that scope is
[`StreamingInsertionAllowlist`](../Sources/SpeakApp/StreamingInsertionAllowlist.swift).
Unit tests support the policy and reconciliation rules, but only an unlocked,
interactive Mac can qualify actual app Accessibility behavior.

## Historical evidence status

The primary historical evidence is Chris's detailed
[13 August run](https://github.com/crmitchelmore/justspeaktoit/issues/664#issuecomment-5286541336):
signed/notarised `mac-v2.49.0`, build `202608131906`, source
`c1c747528ce7964f75d8aa02b96adf7d303a7387`. Its reported environment was
`macOS 26.5.2 (25F84); TextEdit 1.20; Notes 4.13`. These rows apply only to that
build and those scenarios; they are not evidence for an unrelated current
build.

| Surface and scenario | Exact transcript equality | Unrelated-text preservation | Historical result |
| --- | --- | --- | --- |
| TextEdit append, including a genuine provider revision | PASS: field suffix and History matched exactly | PASS: `café`, `☕`, and duplicate surrounding phrases were unchanged | PASS; Accessibility, `firstInsertMs=2674` |
| TextEdit selected-text replacement | PASS: first selected `REPLACE_ME` became `Selection replacement works safely.` and matched History | PASS: second `REPLACE_ME`, `café`, and `☕` were unchanged | PASS; Accessibility, `firstInsertMs=1461` |
| TextEdit edits before and after the streamed region | PASS: provider region matched History | PASS: both user edits and surrounding Unicode/duplicate text remained | PASS; Accessibility, `firstInsertMs=1484` |
| TextEdit edit inside the streamed region | FAIL: History held the provider final, while delivery reported unable to verify insertion | PASS: the user's edit and unrelated following text were preserved; incremental writes paused | PASS for safety only; not an exact-delivery pass |
| TextEdit focus change | PASS: original document matched History exactly | PASS: new document remained byte-for-byte unchanged | PASS; Accessibility, `firstInsertMs=2501` |
| Notes | Not observed | Not observed | BLOCKED: Mac locked; Notes exposed zero Accessibility windows |
| Experimental setting off | Not observed | Not observed | BLOCKED: locked session prevented operation and observation |
| Non-allowlisted Sublime Text | Not observed | Not observed | BLOCKED: locked session; no one-shot result claimed |

A later
[bravostation summary](https://github.com/crmitchelmore/justspeaktoit/issues/664#issuecomment-5379274639)
said both allowlisted apps had passed. That conflicts with the detailed primary
run above: Notes was blocked and remains unqualified. Do not close #664 from
the later summary.

## Fixed test configuration

Record every value rather than assuming it from the installed app:

- Use a signed direct-distribution build on an unlocked interactive Mac with
  Accessibility granted. Record the tag, build number, source SHA, macOS
  build, app version, and the named editor field.
- Select Remote Streaming or Local Streaming with a named model. Use existing
  authorised credentials and synthetic, non-sensitive text.
- Select Smart or Accessibility output and **Insert at Cursor**. Replace Field
  is outside this qualification.
- Record whether experimental streaming insertion and post-processing are on
  or off. Start with post-processing off to match the historical run, then add
  one bounded post-processing-on run if the build still promises a polished
  final delivery.
- Back up changed settings before the run and restore them afterwards.

Before rerunning TextEdit, compare the current insertion, reconciler, and output
code with source `c1c747528ce7964f75d8aa02b96adf7d303a7387`. Retain the historical
rows when behavior is materially unchanged. If it changed, identify the change
and rerun only the affected rows. Notes and both baselines require new
observations regardless.

## Interactive scenarios

In a named Notes editor field, exercise all of the following:

1. Append visible partials, including a genuine provider correction or
   retraction. A run with no observed revision does not qualify this row.
2. Replace selected text incrementally.
3. Preserve emoji, diacritics, pre-existing duplicate phrases, and text outside
   the streamed region.
4. Make user edits before, inside, and after the active region. An inside-region
   edit must be preserved even when that prevents exact final equality.
5. Move focus after the first partial to another clean field or app. Confirm
   the new target stays unchanged and inspect the original target separately.

For exactness, compare the expected streamed region—not an entire pre-populated
field—with the appropriate final History text, accounting for expected prefix
and suffix. Separately record preservation of all unrelated text. Confirm
History's observed delivery method and `firstInsertMs`; that timestamp is not
independent proof that text painted on screen.

Then run these one-shot baselines:

1. Turn experimental streaming insertion off in an otherwise supported field.
   Verify no partial insertion and exactly one final delivery.
2. Turn it on and use a named Sublime Text field, or document the equivalent
   non-allowlisted app used. Verify no partial insertion and exactly one final
   delivery.

A reconnect, HUD message, or return value is not sufficient evidence. Inspect
the actual field and History.

## Result template

Use `BLOCKED`, `PENDING`, or `NOT APPLICABLE` with a reason when a cell cannot
be observed. Never leave an unobserved row looking like an inferred pass.

| Source / build | macOS | App / version | Named field | Scenario | Toggle / post-process | Pause or fallback observed | Exact final text match | Unrelated text preserved | History delivery / `firstInsertMs` | Result | Evidence link |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
|  |  |  |  |  |  |  |  |  |  | PENDING —  |  |
|  |  |  |  |  |  |  |  |  |  | PENDING —  |  |

## Interpreting finalization safely

[`LiveTextInserter.streamingFinalize(with:)`](../Sources/SpeakApp/LiveTextInserter.swift)
can return `.applied` after focus is lost or a final patch fails, provided
verified partials already landed. This prevents a duplicate one-shot insertion;
it does **not** prove that the field equals the final or polished History text.
An `.unknown` streamed region fails because it may contain only an early
partial. An `.absent` region can safely defer to one-shot delivery.

Therefore, record exact equality and preservation independently. “Delivered,”
`.applied`, or a safety pass cannot substitute for an exact-match pass, and a
user edit inside the active region must not be overwritten merely to obtain
equality.

If a supported field fails, retain its exact build and reproduction evidence
and propose a narrow fix or disablement separately. Keep the experimental
default off and #664 open while Notes, the setting-off baseline, the
non-allowlisted baseline, or required exactness evidence remains blocked.
