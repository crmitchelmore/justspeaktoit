# Recent Decisions

## 2026-04-01 — Plan-link enforcement is advisory
PRs #186/#188/#189/#191 were blocked for missing plan links but merged anyway. Enforcement is advisory, not a hard gate.

## 2026-04-08 — Issue #271 (landing page mobile nav)
Approved quickly. Conversion surface bug, single-file scope. Pattern: conversion surface bugs warrant fast approval.

## 2026-04-08 — Issue #283 (iOS missing SpeakCore import)
Approved immediately. One-line critical fix blocking TestFlight 13+ days. Pattern: evidenced one-liners blocking production pipelines bypass normal deliberation.

## 2026-04-09 — Issue #246 (DeepgramLiveController perf)
Bot issue; approved per principles. Code-confirmed O(N) pattern. Pattern: perf-bot issues with evidence + bounded scope get immediate product approval.

## 2026-04-09 — Issue #270: Product approval posted (deferred from initial intake)
Initial intake approved issue in memory but labels/comment weren't applied. Posted formal approval on workflow_dispatch re-run. Lesson: always verify labels were applied after approval decision.
