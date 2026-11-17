# llama.cpp runtime for iOS cleanup

`upstream/` holds an unmodified subset of ggml-org/llama.cpp tag **b11425**,
commit **e117148a41d8e9bedb72e4c6c3f003ab0fe7f857**, the same pin Android
builds from (`android/app/src/main/cpp/cmake/llama.cmake`).

- Archive: `https://github.com/ggml-org/llama.cpp/archive/refs/tags/b11425.tar.gz`
- Archive SHA-256: `3bf5a64c06ecfac21fcf3d44b180177a1ced2b170a9d9a98dfe435d71c83c92a`
- Licence: MIT (`upstream/LICENSE`)

App Store guideline 2.5.2 forbids downloading or loading executable code, so
iOS compiles llama.cpp into the app from this source (CPU backend only, no
Metal, no dynamic backend loading). GGUF weights are data: the app downloads
the pinned files from `LlamaCppModels` and verifies their size and SHA-256
before loading them.

The subset is ggml's base, CPU backend and registry sources, the CPU kernels
for arm64 and x86_64 (compiled through `jsti_arch_quants.c` and
`jsti_arch_repack.cpp`, as ggml's CMake selects them), `include/llama.h` and
`src/`. `upstream/generated/` holds the two version headers CMake would
configure from `ggml-version.h.in` and `llama-version.h.in`.
`jsti_llama_runtime.cpp` is the only first-party C++ and exposes the narrow C
API in `include/jsti_llama_runtime.h`.

To update the pin, change Android's pin and this one together, copy the same
files from the new archive and run `scripts/ios/verify-llama-runtime-source.sh`,
which checks every vendored file against the pinned archive.
