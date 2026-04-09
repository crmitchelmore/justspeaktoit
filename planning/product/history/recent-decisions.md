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

## 2026-04-08 — Issue #283: one-line import fix, instant approval
Critical bug (missing `import SpeakCore`) blocked all iOS TestFlight releases for 13+ days. Approved immediately — evidenced root cause, zero risk, one-line fix. Principle reinforced: well-evidenced one-line bug fixes blocking production pipelines should bypass normal deliberation.

## 2026-04-09 — Issue #246: Fast-track approved perf-bot issue

Approved automated perf improvement (O(N)→O(1) transcript append in DeepgramLiveController) immediately per principles. Code confirmed O(N) pattern at TranscriptionManager.swift:653. No user-facing changes; internal allocation reduction. Pattern: agentic perf-bot issues with code evidence + bounded scope get product approval without discussion.

## 2026-04-09 — Issue #283: re-approved after label reset
Labels were reset between runs (planning:needs-product re-appeared despite prior approval on 2026-04-08). Re-approved same day — issue and fix unchanged. Pattern: label resets can happen; always check live label state, not just memory.
