# Local Voxtral step/finish qualification

This isolated experiment follows the bounded [#485 research plan](https://github.com/crmitchelmore/justspeaktoit/blob/decbdc1e9420ea666f8c70169f892fd583c40235/Docs/issue-value-review-2026-09-12.md). It does not change the app package, model picker, credentials or user defaults.

## Current result

On 26 October 2026, Apple Swift 6.2.3 compiled this executable and its pinned Swift/C++ dependencies. A plain SwiftPM executable could not initialize MLX because it lacked `default.metallib`. The documented Xcode build then reached `CompileMetalFile` and failed because the optional Apple Metal Toolchain was uninstalled (`17C7003j`). **No model inference or transcription acceptance has run.** This is a host-toolchain qualification blocker, not a model no-go or app support claim.

The current SDK head `8b410674` requires MLX versions declaring Swift 6.3. This experiment instead pins an unmodified earlier upstream revision that retains `fromDirectory`, `step` and `finish`, with compatible official dependency versions:

| Component | Pin |
| --- | --- |
| mlx-audio-swift | `8d86630ade569728aaea3dc1a29fc44e2efa719b` |
| mlx-swift | `0.31.4`, `dc43e62d7055353c7f99fa071a4e71d29dfddc44` |
| mlx-swift-lm | `3.31.3`, `1c05248bb0899e2a7a4962b84d319cf12f4e12aa` |
| Model | `mlx-community/Voxtral-Mini-4B-Realtime-2602-4bit` |
| Model revision | `fdebf7b2af834a1db4b8a3c99ab7480b333adf9e` |

The committed `Package.resolved` records the complete dependency graph. Source/package compatibility does not establish measured inference, memory use or iOS support. The compilation described above tested source `9a7c200a43df399d5b9c0adb137f2cb5571304fe`; the later provenance-label and JSON-scalar correction has parse-only validation.

## Reproduce on a qualified Apple host

Use an external working directory for model files, temporary files, caches and DerivedData. Preflight memory and disk before acquiring artifacts. The six pinned model files total **3,148,833,321 bytes**; the safetensors file is 3,133,798,126 bytes. Do not commit weights, audio, caches or results. The model checkpoint declares Apache-2.0; review applicable runtime/dependency notices before any integration.

Acquire the following files from the pinned model revision, then verify SHA-256:

```text
a1533fad1fb49e1230aff61a60028ea63bc924b4cc4501447351b50b9c840683  .gitattributes
022af0f470bbb2036d1d8fea62118d1d14f64b9cbb38415004544990e653f99e  README.md
02060864a4f33df5e4944684fc17f3026af4011830cac4def6e9e025315b10c5  config.json
6f59b425d8a1ceb2de795454558be63937cf75b59f9c9bc77accd85aaf32af05  model.safetensors
80f68b80cf4b1638d864d1504061a266f59e37a8d90d7b20f2e1f30c2d034c2e  model.safetensors.index.json
8434af1d39eba99f0ef46cf1450bf1a63fa941a26933a1ef5dbbf4adf0d00e44  tekken.json
```

Use an installed system voice to synthesize the canonical fixture phrase, rather than recording personal audio:

```sh
say -v Samantha -r 150 -o "$QUALIFICATION_ROOT/quick-brown-fox.wav" \
  --data-format=LEI16@16000 --file-format=WAVE \
  'The quick brown fox jumps over the lazy dog.'
```

The observed fixture was 2.934375 seconds, mono PCM16 at 16 kHz. The executable rejects empty, non-mono, non-16-kHz or over-15-second input.

[Pinned MLX instructions](https://github.com/ml-explore/mlx-swift/blob/dc43e62d7055353c7f99fa071a4e71d29dfddc44/README.md#xcodebuild) require Xcode to build the Metal library. First verify that the optional Metal Toolchain is installed; [Apple documents its component management](https://developer.apple.com/documentation/xcode/downloading-and-installing-additional-xcode-components). Do not change dependency tools-version declarations or substitute an unrelated Metal library to bypass a failed preflight.

From this directory, build with external scratch/cache locations and one job:

```sh
xcodebuild build -scheme VoxtralLocalQualification \
  -destination 'platform=macOS,arch=arm64' -configuration Debug \
  -derivedDataPath "$QUALIFICATION_ROOT/xcode" \
  -clonedSourcePackagesDirPath "$QUALIFICATION_ROOT/source-packages" \
  -resultBundlePath "$QUALIFICATION_ROOT/build.xcresult" \
  -jobs 1 CODE_SIGNING_ALLOWED=NO
```

Set `TMPDIR`, `XDG_CACHE_HOME`, `CLANG_MODULE_CACHE_PATH` and `SWIFT_MODULECACHE_PATH` to owned external directories for the build and run. Keep its process and memory budget bounded. Run the resulting executable with three arguments: the verified model directory, the fixture WAV and the JSON report path. It loads only the supplied directory; it never invokes the model downloader. For offline proof, run under a profile denying network access, for example `sandbox-exec -p '(version 1)(allow default)(deny network*)'` on hosts supporting that tool.

## Interpreting a future result

The probe feeds 100 ms chunks without wall-clock pacing, calls `finish`, checks post-finish behavior, releases the session and repeats against the loaded model. Its JSON records per-step deltas, pre-finish/final text, load/first-partial/finish/total timing, process RSS peak and MLX allocator counters. Revision fields are explicitly expected pins: the probe accepts a supplied directory and does not verify its hashes or the executing dependency graph. Retain an external receipt verifying all six model hashes and the resolved build dependencies before attributing results to these revisions. Report the exact build configuration: unoptimized Debug timing is not a production performance benchmark. Verify the complete known phrase and first/last words from actual output rather than assuming a successful exit means correct transcription.

A positive step/finish result still needs offline quality and resource comparison with an existing local option, cancellation/unload/recovery, and a measured go/no-go before an app adapter or shipping dependency. A synthetic file probe does not qualify microphone capture, long-running memory, interruption handling, thermal behavior, background execution or iPhone support.
