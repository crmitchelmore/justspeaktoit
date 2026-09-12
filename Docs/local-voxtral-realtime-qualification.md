# Local Voxtral Realtime qualification dossier

Status: **metadata qualified; native experiment NOT RUN**. This dossier records
the candidate inspected on 12 September 2026 and a controlled Apple Silicon
protocol. It does not add a model to the app, resolve or build a runtime,
download assets, run inference, or make a production runtime decision.

Cloud-hosted Voxtral is a separate capability. The question here is whether a
local candidate provides enough privacy, language, accuracy, or latency value to
justify its download, memory, integration, and maintenance costs relative to the
shipping local streaming baseline.

## Pinned candidate and provenance

| Item | Pinned evidence | Licence status |
| --- | --- | --- |
| Upstream model | [`mistralai/Voxtral-Mini-4B-Realtime-2602`](https://huggingface.co/mistralai/Voxtral-Mini-4B-Realtime-2602/tree/2769294da9567371363522aac9bbcfdd19447add), revision `2769294da9567371363522aac9bbcfdd19447add` | Model metadata labels it Apache-2.0. Preserve the upstream licence and any notices when evaluating redistribution. |
| Candidate conversion | [`mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit`](https://huggingface.co/mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit/tree/fdebf7b2af834a1db4b8a3c99ab7480b333adf9e), revision `fdebf7b2af834a1db4b8a3c99ab7480b333adf9e` | Repository metadata labels it Apache-2.0, but the inspected listing had no separate licence file. Conversion attribution and the upstream notice chain remain unresolved before packaging. |
| Quantised weights | `model.safetensors`, 3,133,798,126 bytes; Hugging Face LFS SHA-256 `6f59b425d8a1ceb2de795454558be63937cf75b59f9c9bc77accd85aaf32af05` | Weight provenance follows the two model repositories above; an authorised download must verify the bytes and complete the notice audit. |
| Tokenizer | `tekken.json`, 14,910,348 bytes; SHA-256 `8434af1d39eba99f0ef46cf1450bf1a63fa941a26933a1ef5dbbf4adf0d00e44` | No independent tokenizer licence conclusion was established by this source-only audit. Resolve its origin and applicable notices before redistribution. |
| Other model files | `config.json`, 1,513 bytes; `model.safetensors.index.json`, 118,632 bytes | Record SHA-256 values from verified local bytes before execution; metadata sizes alone are not integrity verification. |
| Candidate Swift runtime | [`Blaizzy/mlx-audio-swift`](https://github.com/Blaizzy/mlx-audio-swift/tree/bf14ae0c26e4e85553dd989571cae29d70fa6735), commit `bf14ae0c26e4e85553dd989571cae29d70fa6735` | [MIT licence](https://github.com/Blaizzy/mlx-audio-swift/blob/bf14ae0c26e4e85553dd989571cae29d70fa6735/LICENSE); retain its copyright and permission notice. This does not cover model files or every dependency. |

The runtime manifest at the pinned commit uses Swift tools 6.2, declares macOS
14 and iOS 17, and requires these dependency ranges:

| Dependency | Manifest requirement |
| --- | --- |
| `mlx-swift` | 0.30.6 or later within major version 0 |
| `mlx-swift-lm` | 3.31.3 or later within major version 3 |
| `swift-transformers` | 1.1.6 or later within major version 1 |
| `swift-huggingface` | 0.8.1 or later within major version 0 |

These are requirements, not resolved transitive pins. A future isolated package
must capture the exact resolution, licences, toolchain, and Metal build
requirements. Apache-2.0 and MIT metadata make the candidate plausible for
research; they are not completed distribution clearance. [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0)
obligations include applicable licence/notice preservation and notices of
modifications.

## Advertised properties versus measurements

The inspected model cards advertise a natively causal realtime architecture,
13 languages, and a recommended 480 ms delay. The runtime's
[Voxtral session implementation](https://github.com/Blaizzy/mlx-audio-swift/blob/bf14ae0c26e4e85553dd989571cae29d70fa6735/Sources/MLXAudioSTT/Models/VoxtralRealtime/VoxtralRealtimeStreamSession.swift)
uses 16 kHz audio and exposes synchronous `step([Float]) -> Delta` and
`finish() -> Delta` operations. The inspected session exposes no explicit cancel
method and defaults to a 4,096-token cap.

None of these statements is a device result:

- 480 ms is the upstream comparison setting, not measured first-partial latency.
- 3,133,798,126 bytes is the quantised weight file's disk footprint, not
  resident, peak, GPU, or total system memory.
- A `step` API suggests incremental admission; a full-audio `generateStream`
  example does not prove real-time chunk handling.
- A synchronous call does not become promptly cancellable merely because it is
  wrapped in a Swift `Task`.
- A package deployment target does not prove useful or safe macOS/iOS runtime
  behavior. No macOS go or iOS no-go has been measured.
- The model cards' incidental component-size descriptions disagree, so they are
  not a resource budget.

The experiment must test the 4,096-token boundary, cancellation during
`step`/`finish`, and worker retirement. If compute cannot be bounded or ownership
cannot be retired before the next session, record a no-go or a separate process
isolation requirement.

## Existing app baseline

The current comparison baseline is `FluidAudioParakeetModel.id`:
`local/streaming/fluidaudio/parakeet-realtime-eou-120m`. It is the shipping
English-only EOU streaming path implemented by
`FluidAudioParakeetLiveController`, using 160 ms chunks through FluidAudio/Core
ML. It is not the separate multilingual Parakeet 0.6B model or a sherpa source.

The root manifest pins FluidAudio 0.15.5; `Package.resolved` currently resolves
it to commit `19600a485baa4998812e4654b70d2bab8f2c9949`. Before comparison, record
the installed FluidAudio model artifact identifiers, byte sizes, checksums, and
the runtime resolution actually used on the experiment host.

`LocalModelManager.isSupportedStreamingSource` accepts specific sherpa-backed
sources. It cannot execute Voxtral merely by adding a repository string. No
catalogue, picker, package manifest, project manifest, saved identifier, or
runtime-linking change belongs in this qualification.

## Preconditions for a native experiment

Do not start until every row is satisfied:

| Precondition | Result |
| --- | --- |
| Authorised Apple Silicon Mac and operator | NOT RUN — `<owner/host>` |
| Mac model/RAM, macOS, Xcode/Swift, power state | NOT RUN — `<exact values>` |
| Agreed interactive RAM/GPU/latency/energy/storage budget for that host | NOT RUN — `<budget>` |
| Explicit permission for the approximately 3.13 GB weight download, or supplied existing assets | NOT RUN — `<source and consent>` |
| Sufficient free disk for assets, isolated builds, and measurements | NOT RUN — `<free bytes>` |
| Model/tokenizer/runtime/dependency licence and notice review | NOT RUN — `<record>` |
| Consented/licensed corpus with human-verified references | NOT RUN — `<manifest revision>` |

Missing evidence means **inconclusive**, not a platform pass or failure. Do not
purchase access, download another baseline by default, or use private recordings.

## Controlled Apple Silicon protocol

### Isolation and assets

1. Create an experimental Swift package outside root `Package.swift` and
   `Project.swift`. Pin only `MLXAudioSTT` and its required dependencies at exact
   resolved commits. Keep it outside the app and the separate #1121
   runtime/distribution decision.
2. Verify every supplied/downloaded model file against recorded byte size and
   SHA-256 before loading. Record all small-file hashes, licences, notices, and
   conversion attribution.
3. Load from an explicit local directory after inspecting the runtime path for
   implicit network resolution. Run inference with networking disabled and
   record success or attempted access. A warm Hugging Face cache alone is not
   offline proof.
4. Produce the existing local benchmark result schema plus a versioned streaming
   timing section. Existing WhisperKit/CTranscribe runners do not exercise
   FluidAudio or Voxtral realtime, so use small adapters rather than relabelling
   batch results or rewriting the benchmark framework.

### Input and scheduling

Feed identical consented 16 kHz PCM to both engines at real-time cadence. Do not
call a full-file API and label it live. Use a bounded serial worker away from the
real-time audio callback, monotonic chunk sequence/count accounting, and a
generation fence so callbacks from a retired run cannot affect its successor.
Start Voxtral with the advertised 480 ms delay, clearly labelled as a configured
input rather than an observed latency.

Use this initial corpus:

- 20 short English dictation clips covering punctuation, names, and numbers;
- five 2–5 minute English clips;
- a short silence/noise set; and
- a small, explicitly supported non-English set to assess incremental language
  value.

Mark Parakeet EOU unsupported-language cases not applicable; do not turn them
into extreme WER values. An already installed multilingual local model may be an
optional secondary baseline, but this protocol does not authorise another
download.

Alternate engine and clip order. Perform five cold process/model-load runs and
at least 20 warm clip runs per engine. Add one ten-minute sustained run, unload
and reload, immediate next-session recovery, and cancellation during load,
`step`, and `finish`.

### Measurements

For each run retain raw per-clip results and report distributions, not only
averages:

| Area | Required evidence |
| --- | --- |
| Provenance | Host, runtime/dependency commits, model/tokenizer hashes, corpus revision |
| Input | Duration, sample format, first admitted audio time, chunk sequence/count, dropped/duplicated samples |
| Latency | Cold load, first partial from first admitted audio, final input to final transcript, real-time factor |
| Accuracy | WER, CER, first-word error, last-word error, partial revisions, silence/noise output |
| Resources | On-disk bytes, resident and peak process memory, GPU memory, sustained growth, thermals and energy observations |
| Lifecycle | Cancellation latency during load/step/finalisation, unload/release time, stale callback/text, immediate restart result |
| Reliability | Failures, 4,096-token-cap behavior, ten-minute completion, recovery steps |

Never hide dropped/duplicated opening or final samples, failed runs, or stale
text in averages. Replayed PCM supplies the fair model comparison; a later,
separate real-microphone row is required to qualify capture/tap integration.

## Go/no-go record

| Gate | Result | Evidence |
| --- | --- | --- |
| Exact local assets verified and offline load/inference succeeds | NOT RUN | `<hashes and network-disabled log>` |
| Licence/notice/conversion chain is complete for the proposed use | NOT RUN | `<review record>` |
| Worker ownership, cancellation, unload, and immediate restart are bounded | NOT RUN | `<worst observed timings and failures>` |
| Opening/final audio and transcript content are preserved without stale output | NOT RUN | `<per-run evidence>` |
| Accuracy/latency/language benefit over FluidAudio EOU is useful | NOT RUN | `<WER/CER/latency/language comparison>` |
| Disk, RAM, GPU, thermal, and energy costs fit the pre-agreed host budget | NOT RUN | `<measured values; keep disk and memory separate>` |
| Ten-minute run and 4,096-token boundary are understood and acceptable | NOT RUN | `<result>` |
| macOS research decision | INCONCLUSIVE | No native execution performed |
| iOS research decision | INCONCLUSIVE | Requires separate real-device memory, thermal, foreground/background, interruption, and system-termination evidence |

A conditional engineering **go** requires verified provenance and offline local
loading, bounded lifecycle ownership, and a demonstrated dictation benefit worth
the candidate's measured costs. A model that runs but is consistently slower and
larger without meaningful accuracy or language benefit is a valid **no-go**.
Choose neither result retrospectively from an arbitrary universal memory limit.

A research go authorises only a separate production-integration proposal. That
proposal must address `LiveTranscriptionController`/delegate behavior,
`LocalModelPipelineLease` ownership, honest download/readiness UI, shared
catalogue and platform filtering, public runtime API compatibility, both macOS
distribution builds, and the unresolved #1121 owner decision. It does not itself
authorise an app dependency, catalogue entry, model download, runtime removal,
iOS support claim, or release.

## Current result and limits

On 12 September 2026, source and metadata inspection established the pinned
candidate, advertised API shape, file metadata, top-level licence labels, runtime
requirements, and existing app baseline above. No asset bytes were downloaded or
hashed locally; the listed weight/tokenizer hashes are repository LFS metadata,
not independently recomputed values. No dependency graph was resolved, no Apple
toolchain build or Metal load occurred, and no inference, offline, accuracy,
latency, memory, GPU, thermal, energy, cancellation, microphone, or iOS device
claim was tested. The result remains **INCONCLUSIVE** pending authorised native
qualification.
