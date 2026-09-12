# AuK local text-to-speech qualification dossier

Status on 12 September 2026: **present 16 GiB host no-go; alternative host or
runtime unqualified**. This is a pinned source, licence, dependency, decoder,
and resource preflight plus a conditional native benchmark protocol. No model
asset or dependency was downloaded, resolved, built, or loaded, and no speech
was generated.

AuK is not the app's first offline speech option. The current macOS system
provider uses installed system voices without an API key or provider charge.
Any new local runtime must demonstrate useful quality, language, or latency
value over that baseline while meeting an agreed resource and lifecycle budget.

## Pinned provenance

| Component | Pinned source | Files or contract | Licence/checksum status |
| --- | --- | --- | --- |
| AuK base checkpoint | [`tencent/AuK`](https://huggingface.co/tencent/AuK/tree/790742b71a4430120daf2b2099192abae449eb9f), revision `790742b71a4430120daf2b2099192abae449eb9f` | `config.yaml`, `auk_base.safetensors`, `vae.safetensors`, `LICENSE` | Repository metadata and `LICENSE` identify MIT. Exact local SHA-256 values were not computed because no assets were downloaded. |
| AuK-Flash checkpoint | [`tencent/AuK-Flash`](https://huggingface.co/tencent/AuK-Flash/tree/575b92f0895f75180bf2cbd35f2e176c5732b8ed), revision `575b92f0895f75180bf2cbd35f2e176c5732b8ed` | `config.yaml`, `auk_flash.safetensors`, `vae.safetensors`, `LICENSE` | Repository metadata and `LICENSE` identify MIT. Exact local SHA-256 values were not computed. Flash needs its own parameter, memory, decoder, and Apple runtime accounting. |
| AuK runtime | [`Tencent-Hunyuan/AuK`](https://github.com/Tencent-Hunyuan/AuK/tree/d9f30ffe4231dbc90b48cc83a35d310fece0b060), commit `d9f30ffe4231dbc90b48cc83a35d310fece0b060` | [`infer_auk.py`](https://github.com/Tencent-Hunyuan/AuK/blob/d9f30ffe4231dbc90b48cc83a35d310fece0b060/src/auk/infer/infer_auk.py) and [`pyproject.toml`](https://github.com/Tencent-Hunyuan/AuK/blob/d9f30ffe4231dbc90b48cc83a35d310fece0b060/pyproject.toml) are the implementation/dependency authorities | Top-level code is MIT. Resolve exact transitive versions and licences in a future isolated lock; a nonexistent root `requirements.txt` is not evidence. |
| Text processor/encoder | Qwen2.5-Omni Thinker loaded by the pinned runtime; the vision tower is then removed | Processor/tokenizer plus retained 4,034,780,160-parameter Thinker | The runtime's convenience acquisition is not a reproducible pin. Exact repository revision, files, sizes, checksums, licence, tokenizer/processor provenance, and notices are **NOT ESTABLISHED** for execution. |
| Speech decoder | BigVGANFlow VAE loaded from `vae.safetensors` at the selected AuK checkpoint revision | Required to turn generated representation into playable audio | Covered by the selected checkpoint's top-level MIT metadata, subject to confirming file provenance/notices and a local hash. A text-only LLM runtime without this decoder is not an AuK TTS pipeline. |

Model-card or repository-level MIT labels do not clear every processor,
dependency, downloaded component, or distribution obligation. Before execution,
record exact URLs, revisions, byte sizes, SHA-256 values, licence texts, notices,
and modification status for every local file. Before product integration, review
those records for both distribution channels.

## Runtime and dependency contract

The pinned runtime declares Python 3.10 or later and these ranges in
`pyproject.toml`:

| Dependency | Required range | Qualification status |
| --- | --- | --- |
| `torch` | `>=2.7,<2.8` | Range only; exact build/backend unresolved |
| `torchaudio` | `>=2.7,<2.8` | Range only; audio codec/decoder availability on target Mac unresolved |
| `torchvision` | `>=0.22,<0.23` | Range only; exact build unresolved |
| `transformers` | `>=4.52,<5` | Range only; exact processor/model behavior unresolved |

Optional Gradio and ComfyUI extras add cloud ASR and prompt dependencies and are
excluded from the text-only offline probe. The dependency ranges are not a
reproducible lock and must not be resolved incidentally in this documentation
change.

The inspected inference path chooses CUDA when available and otherwise CPU. It
does not automatically select Apple's MPS backend. It loads the Qwen2.5-Omni
Thinker, removes its vision tower, loads the BigVGANFlow VAE, builds the combined
pipeline, converts it to float32, and then moves it to the chosen device. A bf16
constructor argument does not establish bf16 resident weights in that path.

The bounded upstream source pass found no complete, supported Apple MPS or
lower-memory AuK pipeline covering both the text processor/encoder and speech
decoder. A dtype edit, quantised Qwen encoder, generic Llama wrapper, ASR
encoder/decoder/joiner bundle, or tensor-producing demo is not sufficient.
Unsupported operations, CPU fallback, conversion-time double allocation, model
assembly, VAE state, activations, audio decode, and transient output buffers all
remain risks.

## Present-host resource disposition

The supplied 10 September checkpoint-header accounting is inherited pinned
evidence, not a benchmark:

| Component | Parameters | Float32 weight estimate |
| --- | ---: | ---: |
| AuK base | 1,530,538,629 | about 5.70 GiB |
| Retained Qwen Thinker | 4,034,780,160 | about 15.03 GiB |
| Combined before VAE/activations | 5,565,318,789 | over 20.7 GiB |

The estimate multiplies parameter counts by four bytes. It excludes VAE,
processor state, activations, framework/runtime allocations, intermediate copies,
audio buffers, and other process/system memory. It is not measured resident,
peak, GPU, or unified memory.

Supplied acquisition metadata lists 6,759,531,696 bytes for the full AuK
checkpoint and 11,972,663,208 bytes for the required Qwen checkpoint before
other assets, dependency environments, caches, temporary files, or output. These
are download/on-disk figures, not RAM figures.

The previously reported shared Mac has 16 GiB unified memory and approximately
25 GiB free disk. Those host figures are historical until rechecked on the exact
authorised machine. Even taking them at face value, the upstream full-precision
path's greater-than-20.7-GiB weight estimate exceeds physical memory before the
remaining allocations. The two checkpoint downloads also leave little of the
reported disk for dependencies, build/cache duplication, and safe operating
headroom.

Therefore the inspected full AuK path is **NO-GO on the stated 16 GiB host**.
Do not attempt an unconstrained load or rely on swap. This is a resource gate,
not a measured crash, universal AuK rejection, or access failure: the public
metadata and checkpoints exist.

AuK-Flash is separately **UNQUALIFIED**. Its four-step claim concerns inference
steps, not demonstrated Apple memory. Do not transfer the base parameter estimate
or assume Flash fits until its exact text encoder, weights, VAE, dtype,
allocations, backend, and end-to-end peak are independently established.

## Existing offline system TTS baseline

`SystemTTSClient` is the honest product baseline. `TTSProvider.system` requires
no API key, costs no provider credits, and lists installed English system voices
through `AVSpeechSynthesisVoice`. Synthesis chooses an installed voice, creates an
`AVSpeechUtterance`, and uses `NSSpeechSynthesizer` to write a temporary file.

The current implementation resumes after an estimated delay of
`text.count / 15 + 1` seconds, then asks `AVURLAsset` for duration. API return
time is therefore not established file-completion or audible-completion latency.
The qualification must independently observe file readiness, decodability,
playback start, and audible last-word completion. No baseline rewrite belongs in
this issue.

System voice availability and language quality depend on voices installed on the
test Mac. Record the exact voice identifier/language and do not claim AuK wins a
language comparison that the chosen installed baseline does not support.

## Preconditions for any native probe

| Precondition | Result |
| --- | --- |
| Authorised Apple Silicon host with sufficient RAM and free disk | NOT RUN — `<model/RAM/free bytes>` |
| macOS, Xcode/Swift, Python, and power/thermal state recorded | NOT RUN — `<exact versions/state>` |
| Pre-agreed peak unified-memory, residual-memory, latency, energy, and disk budget | NOT RUN — `<budget>` |
| Complete supported CPU/MPS execution path for encoder and VAE | NOT ESTABLISHED |
| Exact runtime/dependency lock and Apple backend support | NOT ESTABLISHED |
| Exact model/Qwen/VAE/processor assets, hashes, licences, and notices | NOT ESTABLISHED |
| Explicit asset acquisition authorisation or supplied verified local assets | NOT AUTHORISED |
| Installed system baseline voice selected and recorded | NOT RUN |

An appropriately larger host or a verified complete lower-memory implementation
may reopen qualification. Missing evidence is inconclusive, not permission to
download or modify the runtime.

## Conditional controlled native protocol

Run only after every precondition passes, in an isolated experiment outside the
app and root package/project dependencies. Never let a convenience loader fetch
an unpinned Qwen, processor, or VAE. Prefer verified local paths, capture the
resolved lock, and repeat synthesis with networking unavailable after setup to
prove the chosen pipeline is local.

### Inputs and repetitions

Use identical text and the best honest installed system voice for both engines,
with no reference-speaker audio:

1. short neutral sentence: `Please place the blue notebook beside the window.`
2. punctuation/numbers: `At 9:45, send 12 invoices—then call room 307.`
3. one fixed neutral paragraph of 60–100 words, stored with the result record.

Run at least one cold process/model-load synthesis and three warm syntheses per
candidate/input, alternating order with the system baseline. Add a small repeated
run to expose growth and cleanup. Record random seeds and generation parameters
where applicable; do not select only the best output.

### Timing, decoding, and playback

Capture monotonic timestamps for process start, model-load start/end, generation
start, first decodable audio, complete playable file, native playback start,
audible first word, audible last word, and API return. Record total audio duration
and real-time factor.

Record actual output container, codec/sample encoding, sample rate, bit depth,
channels, frame count, and file bytes. Open the output with AVFoundation, verify
duration/frame metadata, and play it through the native app path. A `.wav`
filename, nonempty tensor, or nonzero file size is not proof of decodable speech.

Have a human listener record intelligibility, exact first/last words, truncation,
unwanted sounds, punctuation/number rendering, and useful quality relative to the
installed system voice. A single artifact cannot establish a general voice-
quality improvement.

### Resources and lifecycle

Measure peak process and system unified memory, post-unload residual allocation,
CPU/GPU use, disk footprint, sustained growth, swap, memory pressure, thermals,
and energy observations. Keep checkpoint/download, installed, temporary, and
output disk bytes distinct from memory.

Test empty-text refusal, cancellation during load, cancellation during
generation, stopped playback, unload, and an immediate independent next run.
Record actual cancellation latency and when memory is released. Swift `Task`
cancellation does not prove that a synchronous model operation stops.

A crash, swap pressure, unbounded stop, persistent large allocation, corrupt
audio, missing opening/final words, or stale result in the next run is a failed
qualification row—not authorisation for app watchdogs or a broader runtime port.

## Go/no-go record

| Gate | Result | Required evidence |
| --- | --- | --- |
| Pinned assets, licences, notices, and offline local loading | NOT RUN | `<hash/notice/network-disabled record>` |
| Complete encoder plus BigVGANFlow VAE Apple backend | NOT ESTABLISHED | `<supported runtime evidence>` |
| Native AVFoundation-decodable speech and playback | NOT RUN | `<format/probe/playback record>` |
| First and last words preserved across all fixed inputs | NOT RUN | `<listener/transcript record>` |
| Cold/warm latency and real-time factor fit agreed budget | NOT RUN | `<distribution, not best sample>` |
| Peak/residual memory, disk, swap, thermals, and energy fit agreed budget | NOT RUN | `<measured values>` |
| Empty input, cancellation, unload, and next run are bounded | NOT RUN | `<worst-case timings/state>` |
| Useful quality/language/latency benefit over installed system voice | NOT RUN | `<honest comparison>` |
| Full AuK on stated 16 GiB host | NO-GO | >20.7 GiB float32 weights estimated before VAE/activations; not executed |
| AuK-Flash | UNQUALIFIED | Four-step claim is not end-to-end Apple resource evidence |
| Alternative runtime/host | UNQUALIFIED | No complete supported path or authorised larger host measured |

A qualification pass requires real local speech, native playback, reproducible
assets/licences, acceptable measured host resources, bounded cancellation and
cleanup, and a concrete user benefit over system TTS. Otherwise retain the
no-go/unqualified record without an app adapter.

Only an owner-reviewed pass may lead to a separate integration proposal using
`TextToSpeechClient`, canonical SpeakCore metadata, and existing readiness and
selection conventions. Defaults stay unchanged. A macOS result does not imply
iOS support. This dossier makes no #1121 runtime choice and authorises no picker,
dependency, cloning/editor feature, account, purchase, release, or automation.

## Actual limits of this record

The pinned revisions, upstream source shape, dependency ranges, supplied header
accounting, supplied download sizes, and current app baseline were inspected.
No local checkpoint bytes or checksums were produced, no Qwen revision was
resolved, no Python environment or Apple backend was built, and no CPU/MPS load,
inference, output decode, playback, quality, latency, memory, GPU, swap, thermal,
energy, cancellation, cleanup, or device behavior was measured. The present-host
no-go is a preflight resource decision, not a benchmark result.
