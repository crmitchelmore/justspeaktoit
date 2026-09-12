---
name: Action Button device matrix
about: Record a physical-device run of the hardware-trigger capture matrix
title: "Action Button device matrix: <release or PR>"
labels: ["ios-capture", "status: verification"]
assignees: ""
---

<!--
Model: issue #661. This exists because the two things the capture path depends
on most — ActivityKit and AVAudioSession — are not simulator-faithful, so CI
cannot close any of the rows below. Every row here is a claim only a physical
device can settle.

Fill in one table per device. Record the OS build, not just the major version:
Live Activity start policy and audio-session behaviour have both changed in
point releases.
-->

## What is being verified

- Build: <!-- commit SHA, TestFlight build number, or PR number -->
- Signing: <!-- development / TestFlight; App Group `group.com.justspeaktoit.ios` must be in the entitlement -->
- Settings at the start of the run: <!-- transcription model, destination, Live Activities on/off, hands-free on/off -->

## Device

| | |
| --- | --- |
| Model | <!-- e.g. iPhone 17 Pro --> |
| OS build | <!-- e.g. iOS 26.1 (23B74) --> |
| Action Button bound to | <!-- Shortcut / Control / not present --> |
| Tester | |
| Date | |

## Trigger matrix

Record pass / fail / not applicable, and for any failure the observed behaviour.

| # | Journey | Result | Notes |
| --- | --- | --- | --- |
| 1 | Unlocked, app closed: one Action Button press starts recording | | |
| 2 | Unlocked, app closed: a second press stops and the transcript lands at the chosen destination | | |
| 3 | **Locked** device: one press starts recording | | Presses count: a "Continue in app" prompt or an unlock is a fail for one-press |
| 4 | **Locked** device: the cloud model is used, not a silent fall back to Apple Speech | | Issue #930 — check the model named on the Live Activity |
| 5 | First press of the day / after 8h with no live activity | | The ActivityKit cap is the case this row exists for |
| 6 | After the user swipes the primed Live Activity away | | |
| 7 | After a crash or jetsam mid-recording, the next press still works | | Issue #931 — stale App Group `isRecording` flag |
| 8 | Two presses in fast succession during start-up do not start two sessions | | Issue #943 — listen for a mic indicator that never goes out |
| 9 | Control Centre toggle reports the true state and acts on it | | Issue #941 |
| 10 | Lock Screen control / Back Tap / Pencil squeeze, if bound | | |

## Live Activity truthfulness

The status order and its content cannot be asserted on the simulator; this is
the only place these get checked.

| # | Claim | Result | Notes |
| --- | --- | --- | --- |
| 11 | Status order across one capture is idle/armed → recording → finalising → completed | | Write down the order actually seen |
| 12 | "Recording" does not appear before the microphone is actually live | | Issue #983 — watch the orange mic indicator against the label |
| 13 | The completion row names the real destination, not "copied to clipboard" for a destination that never touched the clipboard | | Issue #945 |
| 14 | The provider named is the provider that ran | | |
| 15 | Dynamic Island compact and expanded presentations are both legible | | |

## Audio session behaviour

| # | Journey | Result | Notes |
| --- | --- | --- | --- |
| 16 | Incoming call mid-recording | | Does the utterance survive? Issue #936 |
| 17 | Siri invoked mid-recording | | Issue #946 |
| 18 | Locking the phone mid-recording | | Issue #942 |
| 19 | Control Centre pulled down mid-recording | | Issue #942 |
| 20 | Bluetooth earbuds connect / disconnect mid-recording | | Issue #935 |
| 21 | Recording starts while music is playing | | |
| 22 | First word is not clipped, on each of Bluetooth, wired and built-in mic | | Issues #641, #947, #949 |

## Outcome

- [ ] Every row above is filled in with a result
- [ ] Failures are filed as their own issues, linked here
- [ ] The build and OS build are recorded, so a later regression can be bisected against them

<!--
If a row cannot be run (no Bluetooth device to hand, Action Button absent on
the model), mark it N/A explicitly rather than leaving it blank — a blank row
reads as untested-and-forgotten, which is exactly what this template exists to
stop.
-->
