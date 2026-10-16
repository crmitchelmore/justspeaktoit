# Downloaded local LLM cleanup on Windows and Linux

This is an **uncompiled, unqualified source candidate**, not a shipping-runtime
or feature-parity acceptance receipt. Native runtime acquisition, compilation,
model downloads and execution have not been performed for this candidate.

## Native controls and privacy

Post-processing has a native Local/Remote source selector and a Batch-only mode
description: there is no invented streaming cleanup route. Windows uses a native
resizable model-management dialog and its multiline system-instruction editor.
Linux uses libadwaita preference rows, an inline model manager, a multiline
accessible instruction editor and GTK-confirmed weight removal.

Local recommendations come only from `ModelCatalog.localPostProcessing`.
Imported models keep the canonical Mac `LocalPostProcessingModel` identity.
Explicit metadata import pins one public Hugging Face repository, immutable
40-character revision, unsplit GGUF filename, LFS byte count, SHA-256 and declared
license. Metadata import is not a weight download or proof of compatibility.
Transferring a Mac identity does not grant execution authority on another device.
Downloaded-model metadata is private, bounded and device-local; the canonical
settings object still owns selection, instructions, output language and temperature.

Download/resume/removal reuse the shared installer, digest providers, receipts and
ownership mechanism. Weights with the same digest share a single `model.gguf`
and lease, even when imported through different public references. Removing weights
retains references, selection and friendly History names. Model integrity is
checked again against an immutable snapshot before each native execution.

The configured instruction is passed as the SYSTEM role. Transcript data is
passed separately as the shared cleanup policy's USER message. Output-language
and lexicon layers use that same shared policy; temperature is finite in 0...1,
with zero selecting greedy sampling. Empty, whitespace-only and `[BLANK_AUDIO]`
input stay empty without invoking a model.

There is no Python, subprocess, local HTTP server, IPC inference or remote/rules
fallback. Missing metadata, missing/mismatched runtime, missing weights, malformed
GGUF, unsupported architecture/template, cancellation and incomplete output are
explicit errors. History retains the original transcript and reports the failure.
Built-in rules are a separate mode, not a substitute language model.

## Pinned offline native-runtime provisioning

The adapter is compiled against unmodified public llama.cpp **b6500**, commit
`a7a98e0fffed794396b3fbad4dcdbbc184963645`, under its MIT license. Header and license
provenance are in `Sources/CLlamaCpp/upstream/PROVENANCE.md`. Function pointers use
the actual header declarations; no guessed C structs or fabricated SDK headers
are used.

`scripts/local-llm-runtime/build-native-runtime.py` and the adjacent CMake project
provide a concrete source-build path on Windows x86_64/arm64 and Linux
x86_64/arm64. **Only execute after a coordinator grants a native build slot.**
They require Python 3.11+, CMake 3.24+, Ninja, the intended platform's existing
native C/C++ toolchain and an already-present, clean upstream checkout at the
exact commit. They do not clone, download, install tools or acquire models.

Example arguments (use native paths for the host):

```text
python scripts\local-llm-runtime\build-native-runtime.py --source C:\sources\llama.cpp --build-directory C:\build\jsti-llama-b6500 --output C:\stage\LocalLLMRuntime
```

The CMake wrapper statically links upstream llama/ggml into one CPU-only shared
library, disables dynamic backend discovery, OpenMP, build-machine-specific CPU
features and accelerator backends, and explicitly exports the adapter's real
public C functions on Windows. Windows uses the static MSVC runtime so the
confined loader does not need to discover Visual C++ DLLs outside its directory.
It installs only `llama.dll` or `libllama.so`,
then writes the binary's **actual** SHA-256, exact commit, platform and architecture
to `provisioning.json` and copies the MIT license. Existing outputs/build
directories are never overwritten. This manifest records provenance and bytes,
not successful native inference or model quality.

Pass the resulting **whole** `LocalLLMRuntime` folder through the platform's
existing packager with its additive `--local-llm-runtime` argument.
`scripts/windows-bundle/build-windows-bundle.py` retains the nested folder beside
`SpeakWindows.exe`; `scripts/stage-linux-desktop.py` retains it beside the staged
`justspeaktoit` executable. Omitting the argument preserves the existing bundle
behavior and does not install or advertise an available runtime.
Runtime resolution does not read PATH, LD_LIBRARY_PATH or
transferred preferences. Windows uses an absolute DLL path with DLL-directory
and System32-only dependency search. Linux uses an absolute SO path with local
symbol visibility. No process-global loader settings are changed.

## Distribution integration and remaining acceptance boundaries

The offline builder is authored but has not been run. Its CMake/link/export
behavior, Windows compiler compatibility, x86_64/arm64 CPU baseline and Linux
system-library dependencies still need native evidence.

The source wrappers now consume this runtime through that explicit argument.
One bounded shared reader authenticates the exact pin, architecture, library,
actual SHA-256, exact MIT notice and three-file folder before staging verified
bytes. Extra files, links/reparse points, duplicate manifest keys and oversized
metadata are rejected. This authenticates declared content, not an independently
attested compiler run.

Windows adds the native DLL as a runtime-loaded root to its existing static and
delay-load dependency walk. Its nested absolute-loader policy requires only
approved Windows/System32 imports; a dynamic Visual C++ runtime, accelerator or
ggml DLL dependency is rejected rather than relying on preloaded app modules.
Other app/Swift/whisper Visual C++ dependencies retain their existing pinned
redistributable policy. Bundle hashes and notices cover all three nested files.
`windows_msix.py` independently rechecks the nested manifest/license/PE imports,
source attribution and full dependency closure before preserving the folder in
the MSIX layout. Whisper's source record and root DLL layout remain distinct.

Linux checks the application's ELF architecture against the manifest, reads the
SO's bounded program/dynamic/string tables without executing it, and admits only
explicit glibc/system C/C++ SONAME dependencies. External backend libraries,
foreign loaders, filter/audit libraries and search paths other than absent or
exactly `$ORIGIN` are rejected. It preserves the authenticated SO, manifest and
license bytes together. This is not a recursive inspection of the target OS's
installed system libraries, a minimum-glibc/GLIBCXX receipt, or native evidence.

Release automation must still supply a freshly built, owner-qualified runtime
to these opt-in inputs; no unqualified runtime is enabled by default. The
wrapper/fixture source changes themselves have not been executed.

An owner-granted gate must compile the Apple and portable graphs, run the new
regressions alongside the unchanged baseline tests, build and inspect the
pinned native runtime on each shipped platform/architecture, exercise Windows
and GTK controls, and execute real model fixtures. Required physical acceptance
includes exact custom SYSTEM prompts (including formatting-only instructions),
output-language behavior, silence, clean error recovery, stop/close/removal
lifetime, cancellation during model load/prefill/generation, Unicode paths,
malformed/unsupported models, performance and memory pressure. The conservative
`LocalModelHostSupport` aggregate is deliberately not promoted by catalogue
membership or source-only fixtures.

The current native adapter supports decoder-only instruction models with a
recognized upstream chat template, a 4096-token context and at most 2048 output
tokens / 256 KiB. Exhausting a budget without end-of-generation is an error, not
partial success. Runs have a cooperative two-minute native budget; blocking OS
I/O and model loading still need cancellation-latency qualification. Linux uses
a sealed anonymous model snapshot and therefore needs memory/headroom for that
snapshot; no disk-polling or audio-path IPC is introduced.

## Composition with the rules/settings successor

This delta is relative to accepted tree `e0c059234b3ce41b877314798d85d2af4e5a2b01`;
no frozen profiles, capture, rules, Soniox, registry or API-repair successor was
imported. Preserve the original five-label/defaulted `DesktopPostProcessing.Options`
initializer and original `process(...session:)` overload. The new overload has
a required `localLLM:` parameter. Its `.localLLM` case must remain separate from
R6's `.local` built-in rules.

When composing R6, retain both its required additive context flags
`includeLexiconDirectives` and `includeContextTags`, Codable defaults/type errors,
`lastRemoteModelIdentifier` and dormant remote recall. Extend its `mode(for:)`
to distinguish downloaded identities, and send the context layers to the local
engine only when their corresponding flags permit them. Merge the two profile
resolution changes and Local-source model lists; do not replace either canonical
settings store, restore a second catalogue or send local selections through the
remote effects/credential path.
