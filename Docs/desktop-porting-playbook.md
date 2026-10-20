# Porting a native app to Windows and Linux

Lessons from JustSpeakToIt's Swift/macOS-to-Windows and Linux work, reviewed
15 October 2026. This is a reusable engineering playbook, not a declaration of
feature parity or a Windows/Linux release. "Migration" here means porting an
application; transferring user data is one part of that work.

## Review scope and current result

The review covered the build graph, shared desktop host, recording and shutdown
contracts, capability projection, native text output, packaging, platform
acceptance matrices and the current integration PR. It was a source/document
and existing-CI review, not a new hardware walkthrough or exhaustive code audit.

Two revisions must be kept distinct:

| Snapshot | What it establishes |
|---|---|
| Main checkout `9b9938221bcb81d91c6d1a14dba174d3e9fd97a4` | The existing portable kernel, shared Windows/Linux host and native adapters. The platform guides include historical receipts and explicitly pending acceptance work. |
| Open integration [#1218](https://github.com/crmitchelmore/justspeaktoit/pull/1218), head `1e978f3680f42d703e53daf49744763da53a94f5` | Composition of the desktop settings, icons, History management, streaming, vocabulary, comparison and Voice work from #1211-#1217, plus integration corrections. This work is not merged into the reviewed main checkout. |

GitHub reported successful workflows for that exact integration head:
[native Windows](https://github.com/crmitchelmore/justspeaktoit/actions/runs/38718442908),
[Linux](https://github.com/crmitchelmore/justspeaktoit/actions/runs/38718442823),
[Apple CI](https://github.com/crmitchelmore/justspeaktoit/actions/runs/38718442855)
and [cross-build/Windows bundle execution](https://github.com/crmitchelmore/justspeaktoit/actions/runs/38718442866).
Its PR checks also reported successful native ARM64, ARM64 bundle and developer
MSIX lifecycle jobs. These are automated receipts, not physical-device or
real-service acceptance. Recheck the head and checks before using them for a
later revision; component receipts alone do not qualify a composed branch.

**What worked:** sharing policy and orchestration while keeping OS effects
native made the second desktop host reuse much more than domain models.
**What still costs work:** lifecycle seams, native UI, real desktop permissions,
distribution and exact-head integration. A portable language and a green build
do not remove those costs.

## 1. Inventory user journeys before choosing a UI toolkit

Start with the source app's observable behaviour, not its settings labels or
screenshots. For each journey, record the initial state, user action, state
changes, durable output, cancellation and failure behaviour. Include less visible
surfaces: shortcuts, tray, startup, automation, export, recovery and accessibility.

Use one capability/evidence ledger:

| Journey | Shared policy | Native effect | Fallback | Evidence still needed |
|---|---|---|---|---|
| Dictate into another app | Session ownership, transcript, output choice | Capture, focus identity, insertion | Saved transcript and explicit Copy | Real microphone, service and destination app |
| Local processing | Catalogue, install/verification, job lifetime | Runtime loading and acceleration | Explicit unavailable state | Supported CPU/GPU and packaged execution |
| Start at login | State and presentation | Registry/startup task or XDG/portal | Explain OS refusal | Actual sign-in in each package mode |

Track states separately: **catalogued**, **wired**, **fake-tested**,
**native-tested**, **real-service/device accepted**, **distributable**.
Do not collapse them into a single "supported" checkbox.

The existing [Windows](windows-development.md#feature-parity-matrix) and
[Linux](linux-development.md#parity-matrix) matrices show why: a fake portal is
useful protocol evidence but does not prove GNOME's consent experience; a
provider passing on Apple does not qualify WinHTTP or Linux TLS.

## 2. Extract behaviour; do not translate the whole app

Use this dependency direction, with names appropriate to the next app:

```text
Domain and protocol policies
    -> portable application workflows
        -> shared desktop host
            -> native platform services and presenters
```

In this repository those layers are `SpeakCore`, `SpeakDesktop`/
`SpeakDesktopSync`, `SpeakDesktopHost`, then Windows/Linux adapters. See
[Architecture](Architecture.md#portable-windows-and-linux-graph) and
[DesktopHostPlatform](../Sources/SpeakDesktopHost/DesktopHostPlatform.swift).

Keep identifiers, catalogues, defaults, parsing, transcript reconciliation,
pricing, persistence formats and session rules canonical. Expose only the
subset a host can actually execute. The
[desktop live projection](../Sources/SpeakDesktop/DesktopLiveTranscription.swift)
admits xAI speech-to-text by its specific route, not everything sharing the
provider prefix. New catalogue entries must not accidentally imply support.

Keep capture, resampling, playback, permissions, credential storage, focus and
insertion native and in process. Use narrow C-compatible boundaries where
Swift cannot conveniently reach an OS library. Specify ABI string ownership,
callback thread, handle lifetime, error reporting and destruction guarantees;
a header that compiles is not a lifecycle contract.

Do not generalise the entire UI framework in advance. Extract workflows when
their behaviour is genuinely shared; keep presentation native. Do not assume
the original host already consumes every newly extracted policy: the
[architecture map](Architecture.md#macos-runtime) records remaining parallel
Apple implementations that changes must still inspect.

## 3. Make portability the default build boundary

Admit new domain files automatically and explicitly exclude only native
adapters. An allow-list of portable files makes every new feature Apple-only
until somebody remembers to copy it into the other graph.

[Package.swift](../Package.swift) and
[the boundary verifier](../scripts/verify-portable-core-boundary.py) enforce
this source-discovery rule and reject native imports in shared desktop layers.
The verifier is structural; native compilation is still necessary.

Separate the dependency-light portability check from the actual desktop build.
Linux's GTK packages should not be prerequisites for testing domain rules.
Preserve the source platform's lockfile: the portable resolver can delete it,
and the Linux app's NIO graph differs from the Apple graph. Use isolated
intermediates and graph-specific pins rather than committing resolver churn.

Cross-compilation has an additional trap: manifest `#if os(...)` evaluates on
the build host, not the target. Select the target graph explicitly. Pin compiler,
SDK, C/C++ compiler, runtime and architecture as a compatible set. This port
needed a separate compatible Clang for Microsoft's C++ headers and the matching
Swift compiler for Windows Foundation modules; bypassing version checks was not
a fix. See [the cross-build guide](../scripts/windows-cross/README.md).

## 4. Design ownership, cancellation and recovery before adding features

Write the contracts before implementing the native workers:

| Boundary | Required invariant |
|---|---|
| Recording start | Freeze device, model, profile, output settings and destination identity for that run. Save a pending record before network work. |
| Audio callback | Bound memory and backpressure; keep blocking file/network work off the real-time callback. Overflow is an explicit failure, not lost samples. |
| Stop | Stop admission, quiesce the producer, flush final samples, drain owned work, then finalise the file/protocol. Define each acknowledgement. |
| Replacement run | Late callbacks, timers and cleanup can affect only their own run identity, never the current replacement. |
| Failure/cancel | Retain audio and useful text, distinguish drafts from confirmed results, and suppress automatic insertion of a failed result. |
| Close | Reject new work, cancel owned tasks, use one bounded shutdown budget and prevent late work from reaching the closed UI. |

Examples: [recording](../Sources/SpeakDesktopHost/DesktopHostRecording.swift),
[capture effects](../Sources/SpeakDesktopHost/DesktopHostEffects.swift),
[WAV recovery](../Sources/SpeakDesktop/PCMRecordingFile.swift),
[shutdown](../Sources/SpeakDesktopHost/DesktopHostShutdown.swift) and
[stubborn-operation tests](../Tests/SpeakDesktopHostTests/DesktopHostShutdownTests.swift).
The current host's five-second close budget is a repository choice, not a
universal timeout for another app.

**Cancellation requested is not producer quiescence.** An async timeout does
not stop a blocked native thread or prove callbacks have ended. Retain its state
until destruction is safe, count retired-but-live resources toward a finite
admission limit, and report exhaustion. The
[WinHTTP release queue](../Sources/SpeakWindowsPlatform/WinHTTPReleaseQueue.swift)
owns queued, running and failed destruction attempts and retries with capped
backoff instead of freeing callback state early.

**An event queue must admit work, not wait for its entire lifetime.** Settings
queues drain before controller close on both hosts. A long import, deletion or
cloud request awaited inside that queue can prevent shutdown from reaching the
code that cancels it. In the integration snapshot,
[`beginHistoryDeletion`](https://github.com/crmitchelmore/justspeaktoit/blob/1e978f3680f42d703e53daf49744763da53a94f5/Sources/SpeakDesktopHost/DesktopHostHistoryManagement.swift)
performs admission and gives the operation its own cancellable task.

## 5. Port platform capabilities, not Apple API names

| Concern | Windows mechanism | Linux mechanism / limitation |
|---|---|---|
| Capture/playback | WASAPI; Media Foundation decoding | PulseAudio API through PipeWire; GStreamer conversion |
| Secrets | Credential Manager | Secret Service; keyring availability and sandbox integration need acceptance |
| Shortcut | Native registration and observed release | X11 grab or GlobalShortcuts portal; desktop binding fallback |
| Output | Captured native control/UI Automation/guarded paste | X11 clipboard/XTest; Wayland RemoteDesktop and Clipboard portals or Copy |
| Startup | Unpackaged registry or MSIX startup task | XDG autostart or Flatpak Background portal |
| Local inference | Verified native runtime/backend libraries | Verified shared objects/backend libraries; package inclusion is separate |

Wayland is a different permission and focus model, not an X11 implementation
detail. Clients cannot generally inspect the focused external app, place a HUD,
or inject keys freely. Communicate that weaker guarantee, use portals only for
the capabilities actually granted, and preserve a usable Copy fallback.
Test GNOME and KDE on real compositors and from the sandbox; headless Weston
and a fake portal do not cover those interactions.

Treat text output as an ownership transaction. Capture the target before an
actor/UI hop, revalidate it immediately before mutation, avoid password/read-only
fields and never use whole-field replacement to imitate caret insertion.
See [Windows text insertion](windows-text-insertion.md).

Clipboard restoration requires ownership identity, not text equality or a fixed
sleep. A user may copy identical text after the app's paste. The integration
[`LinuxClipboard.c`](https://github.com/crmitchelmore/justspeaktoit/blob/1e978f3680f42d703e53daf49744763da53a94f5/Sources/CLinuxSupport/LinuxClipboard.c)
checks receipt/provider identity and the X11 server selection owner in the same
protected operation; delayed GDK ownership notifications cannot authorise a
stale restore.

## 6. Preserve settings and data without inventing support

Separate **stored**, **editable here** and **executable here**. Preserve unsupported
settings and unknown portable values where the format allows, but show the
limitation instead of silently substituting a different device, model or engine.
Do not rewrite the original user's defaults as a side effect of a profile.

Choose one authoritative persisted model per setting. Settings UI, session
snapshots, archive import/export and feature editors should project from it.
The integration
[`DesktopHostVoiceConfiguration`](https://github.com/crmitchelmore/justspeaktoit/blob/1e978f3680f42d703e53daf49744763da53a94f5/Sources/SpeakDesktopHost/DesktopHostVoiceConfiguration.swift)
imports Voice preferences into the Voice settings model and removes duplicate
configuration mirrors, preventing later export or Apply from reviving stale values.

Data transfer needs a versioned archive, independent category selection,
validation before mutation, an explicit conflict policy, preview freshness,
rollback/recovery and idempotent identities. Missing or damaged data must not
mean "replace the destination with empty." Keep credentials opt-in and redacted
in previews; do not migrate permission grants, device identities, sync cursors,
caches or executable runtimes. The [migration guide](data-migration.md) documents
Windows/Linux History backups, optional saved audio and app profiles, and read-only
inspection. Full native category collection and transactional import remain
unfinished; the macOS import contract is not evidence of equivalent desktop support.

## 7. Qualify the real native surfaces, not just the model

Use this evidence ladder; each rung answers a different question:

| Evidence | Proves | Does not prove |
|---|---|---|
| Portable tests / fake platform | Rules, ordering, recovery and cancellation under controlled races | OS implementation correctness |
| Cross-build / type-check | Source/ABI compatibility with the selected SDK | Native runtime correctness |
| Native unit/self-tests and loopback peers | Actual runtime, transport framing and adapter behaviour | Live service/TLS/proxy compatibility or physical devices |
| Headless UI and desktop integration | Widgets, event wiring, virtual capture, fake portals, test clipboard clients | Real consent, accessibility, scaling or third-party-app behaviour |
| Real-device/service journeys | The specified machine, desktop, provider, destination and failure cases | Other environments or the final packaged artifact |
| Isolated package lifecycle | Exact artifact installs, launches, upgrades and retains data without dev tooling | Signed release readiness or all interactive journeys |

Use deterministic delayed callbacks and blocked-worker fixtures, not longer
sleeps, to exercise failure. Test rapid selection/version changes, model refresh,
replacement sessions, cancellation during every suspension and close during
stubborn I/O. Copy/export/delete must use the confirmed record IDs and displayed
text snapshot, never whatever is selected after an asynchronous dialog returns.

Test infrastructure is itself platform code. At the integration snapshot,
[`RecordingWriteGate`](https://github.com/crmitchelmore/justspeaktoit/blob/1e978f3680f42d703e53daf49744763da53a94f5/Tests/SpeakDesktopHostTests/DesktopHostRecordingWriteGateTests.swift)
replaced `NSConditionLock` reuse that traps on the pinned Windows Foundation
with `NSCondition`, a protected predicate and a bounded wait. Preserve a minimal
reproducer and run it natively; an Apple-only pass can hide a test-runtime defect.
This is a pinned-runtime finding, not a claim that all Foundation locks are broken.

Native layout needs assertions over actual control rectangles, not just requested
layout values. #1218 fixed a zero-height Windows History transcript at minimum
size; its geometry receipt distinguishes requested outer size from measured
client size and checks visibility, positive area and overlap. Include minimum
size, scrolling, long/localised labels, DPI, keyboard navigation and screen-reader
behaviour. Screenshots complement those checks; they do not replace them.

## 8. Treat distribution as an early engineering workstream

Build the production executable separately from test-enabled binaries.
Package resources and the runtime dependency closure, not a copy of a developer
machine's SDK. Pin upstream sources and hashes, include licences, reject unknown
dependencies and record what modules actually loaded.

The [Windows bundle](windows-runtime-bundle.md) verifies the exact extracted app
without Swift on PATH and uses missing-DLL/resource negative controls. Paths with
spaces and Unicode and an empty working directory expose hidden assumptions.
Test both static imports and dynamically loaded inference libraries. On ARM64,
compilation is not native-execution evidence.

For [MSIX](windows-installer.md), installation, upgrade, cancelled/failed upgrade,
uninstall, data retention, identity and signing are separate gates. For
[Flatpak](linux-development.md#flatpak), a build inside the SDK is not an installed
desktop run; offline sources, portals, keyring, runtime inclusion and sandboxed
paths need their own proof. Fix application identity early because it also keys
data directories, shortcuts, startup registration and permissions.

## 9. Integrate continuously and keep evidence immutable

Split independent features only after agreeing the shared seams: C ABI and event
IDs, preference ownership, capability filtering, file publication, cancellation
and resource layout. Compose early in an isolated branch; a green set of feature
branches can still disagree about these contracts. Do not solve collisions by
copying a second catalogue, persisting a second setting or excluding shared code.

Record each receipt with source SHA, artifact hash, OS/architecture, toolchain,
command, input fixture, relevant device/service, result and skips. Keep earlier
failures visible and identify exactly which later receipt supersedes them.
Never silently promote local experiments, held components or component-level
checks into proof that a composed production path is enabled or accepted.

Maintain a concise current matrix separately from historical receipts. The
platform guides contain valuable history, but some paragraphs describe earlier
checkpoints: for example, Windows' earlier no-MSIX-receipt statement must not be
read as the status of #1218's later green lifecycle jobs. Conversely, those jobs
must not erase unverified physical microphone, external-app insertion, Linux
compositor consent or real-provider requirements.

## Recommended sequence for the next app

1. Inventory journeys, durable data, permission requirements and the source
   platform's baseline performance. Create the capability/evidence ledger.
2. Extract the portable domain and protocols, preserve source-host behaviour,
   and enforce a default-inclusion source boundary in CI.
3. Port one vertical journey end to end: native input, durable pending record,
   one implemented backend, visible result, explicit output and failure recovery.
4. Prove cancellation, final flush, replacement-run isolation and bounded close
   before adding more backends or background work.
5. Build a minimal distributable artifact now and execute it without developer
   tooling. Resolve identity, runtime closure, licences and sandbox constraints.
6. Add the second host against the same workflows; expose real platform
   differences rather than reproducing the first host's assumptions.
7. Expand features with canonical catalogues and one settings authority, composing
   branches frequently and running the original-host regression gates.
8. Accept the final artifact on real supported machines/desktops and services.
   Measure cold/warm start, first useful result, finalisation and completed output
   at p50/p95, plus CPU/memory and long-run backpressure, against the same fixtures.

The reusable assets are the contracts, evidence ledger, native test harnesses
and packaging checks. Copy those patterns first; copy app-specific catalogue
entries, UI, timeouts and platform assumptions only after re-evaluating them.
