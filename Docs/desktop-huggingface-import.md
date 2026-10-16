# Hugging Face imports on Windows and Linux

The native Local models controls accept an explicit public Hugging Face
`owner/repository` and a root-level GGML filename. This is a whisper.cpp batch
workflow, not the Mac's WhisperKit/Core ML importer. The four pinned built-in
models and their existing identifiers/defaults are unchanged.

## Workflow

1. Open **Local models** on Windows, or **Settings > Transcription > Local
   models** on Linux. Enter the exact repository and a compatible filename,
   such as `ggml-tiny.bin`, and choose **Import reference**.
2. Import discovers the immutable commit, byte size and LFS SHA-256, rereads that
   exact commit and saves the reference. It neither selects the model nor
   downloads weights. The status and model description disclose the source.
3. Choose **Download** for that row. Download uses the existing private,
   resumable installer, checks the entire SHA-256 and GGML header, then atomically
   installs weights with a receipt. **Cancel download** retains partial bytes;
   **Resume download** continues the same immutable artifact.
4. Choose **Source: Local**, then **Batch**, and select the imported model.
   Installed weights and the bundled whisper.cpp runtime are both required.
   There is no provider key or remote fallback. Recorded/file-import/retry audio
   follows the existing native recognizer, language snapshot and History paths.

**Cancel import** cancels metadata discovery, not a separate weight download.
If metadata was already atomically saved, cancellation does not undo that commit;
it still does not install weights. App shutdown cancels and joins owned import
and download work. Import or persistence errors remain visible rather than being
replaced by a generic runtime-ready status.

**Remove** deletes the selected model's weights, partial bytes and installation
receipt, not its saved reference or History. A model held by a recording or
recognition cannot be removed until that use ends. The reference remains listed
for later redownload and retains its friendly name. Up to 64 distinct imported
content identities are retained; this slice has no forget-reference control.

## Supported artifacts and trust boundary

- Public, unauthenticated repositories only; no Hugging Face token, provider
  credentials, browser cookies or credential store is consulted.
- Standard Whisper `tiny`, `base`, `small`, `medium` (including `.en`), and
  `large-v1`, `large-v2`, `large-v3`, `large-v3-turbo`. Root basenames must be
  `ggml-<name>.bin`, optionally suffixed with `-q4_0`, `-q4_1`, `-q5_0`,
  `-q5_1` or `-q8_0` before `.bin`.
- Core ML, ONNX, GGUF, distilled checkpoints, renamed/unqualified `.bin` files,
  repository URLs, nested paths, traversal, NULs and encoded separators are
  rejected. A Mac imported reference never becomes GGML authority by sharing a
  model name or identifier prefix.
- Discovery makes two HTTPS JSON requests to `huggingface.co`: the repository's
  `main` metadata, then its exact 40-hex commit. Repository, revision, filename,
  LFS SHA-256 and size must agree. Each response is capped at 2 MiB and 20 seconds,
  with at most 4,096 siblings; API redirects and non-JSON/non-200 responses fail.
- Weights must be 48 bytes through 8 GiB, with a lowercase 64-hex digest. The
  small lower bound permits synthetic fixtures; it is not a claim that a header
  alone is a runnable model. The existing streaming downloader limits bytes,
  validates ranges and admits HTTPS redirects only within its pinned Hugging
  Face host allowlist. Its existing request/resource budgets remain 60 seconds
  and six hours.
- Header checks bind architecture, vocabulary, mel bins and supported tensor
  type to the filename. They do not parse all tensors or prove speech accuracy.
  The in-process native loader still validates the model and hashes the bytes
  actually loaded before recognition. No IPC or audio-path disk polling is added.
- Repository-declared licence text is bounded and displayed as provenance,
  not independently certified licensing or a publisher-signature guarantee.

## Persistence and platform boundaries

`HuggingFaceWhisperModel` in SpeakCore owns the validated portable identity and
GGML projection. The content-addressed identifier is
`local/whispercpp/huggingface/<sha256>`: new bytes get a new identity, while
identical bytes retain the first imported reference. Existing native callback
slots never get reassigned when models arrive.

The device-local `LocalModels/imported-whispercpp-models.json` registry is
versioned, bounded and atomically written inside the native private model
directory. It is loaded before selection migration, so imported selections,
readiness and friendly names survive restart. Symlink/nonregular registry files,
duplicates and malformed records are refused. This registry is distinct from
Mac's Core ML import file; it is not added to settings transfer or cloud sync.
History transferred without that metadata shows a digest-qualified imported
Whisper label, not a fabricated repository name or execution capability.

Windows retains its native model dialog and Remote/Local, Batch/Live pickers.
Linux uses native libadwaita entry rows and the same source/mode grouping; Local
is batch-only and the disabled Live control cannot activate it. Existing remote
model identities, shortcuts and recording paths remain separate.

## Evidence boundary

This source candidate includes synthetic portable/host regressions and native
control fixtures for metadata, trust rejection, HTTP bounds/cancellation,
installation/resume/removal, restart, actual shared-host inference dispatch and
native import/filter callbacks. **All new tests and fixtures are unexecuted.**
No compiler, lint, build, dependency graph, native UI, real model download or
runtime/provider qualification was run for this slice. Existing pinned-model
evidence does not qualify imported models or these new controls.
