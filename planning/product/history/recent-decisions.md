# Recent Decisions

<!-- Graduated decisions are recorded in principles.md. Only non-graduated recent learnings kept here. -->

## 2026-04-01 — Post-merge review: PRs #186, #188, #189, #191
All four PRs were product-blocked for missing `Plan issue: #<n>`. All four were merged anyway by maintainer (2026-03-26). The plan-link enforcement is advisory, not a hard merge gate. The principle remains the correct Product stance but blocks can be overridden. May need reframing as "request" vs "block".

## 2026-04-08 — Issue #256 (re-check)
Confirmed: bot-authored Daily Test Improver issue. Out of scope for product validation. No action taken.

## 2026-04-08 — PR #128 docs review (initial)
`docs:` only PR by owner — no plan link. Blocked per protocol. Clear path to yes: add any issue reference. Content itself is unambiguous and appropriate. Same advisory dynamic as PRs #186/#188/#189/#191 likely applies.

## 2026-04-08 — Issue #271 (landing page mobile nav bug)
Approved quickly. Static HTML landing page bug on primary conversion surface. Code-confirmed: `nav__cta` has no mobile-specific styling, hamburger overlay z-index stack is suspect. Scope bounded to one file. Product principle: conversion surface bugs warrant fast approval.

## 2026-04-08 — Issue #283 (missing SpeakCore import, iOS TestFlight broken)
Textbook fast approval. One-line compile fix, verified in file. All iOS TestFlight releases blocked since March 26. No scope questions needed — evidenced bug, bounded fix, zero product ambiguity.
