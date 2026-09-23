# Vendored whisper.cpp headers

These five headers are unmodified copies from
[ggml-org/whisper.cpp](https://github.com/ggml-org/whisper.cpp) tag `v1.9.4`,
commit `927cfce34f31707e17f2bff35c349632fb9e2c3a`, under the MIT licence in
`LICENSE` beside them.

| File | Upstream path | SHA-256 |
|---|---|---|
| `whisper.h` | `include/whisper.h` | `a7d19f7feb5be52426628ff07e0602de28a30dc4312d0d0603e1e536753f76dd` |
| `ggml.h` | `ggml/include/ggml.h` | `34192eac913444df9dc1d23025a618448cdee1ee7d78597af4979d8edc77b695` |
| `ggml-cpu.h` | `ggml/include/ggml-cpu.h` | `316279e004cdeb8e6ef78599acb602bf79a8abdf897fed9fd1914808c1518c6e` |
| `ggml-backend.h` | `ggml/include/ggml-backend.h` | `46d84cb998105f871240864fd0f55446939a2fe86c5c281afa63a010fb1f65a2` |
| `ggml-alloc.h` | `ggml/include/ggml-alloc.h` | `94e4cd069b9313b2ceb35dacec901981e0bb478d8bb31035b7126be091998c23` |
| `LICENSE` | `LICENSE` | `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d` |

`WindowsWhisper.cpp` uses them only for declarations and struct layouts. It
links nothing from whisper.cpp at build time: it loads `whisper.dll` from the
application directory at run time, refuses any library whose
`whisper_version()` differs from `1.9.4`, and resolves each function by name.
The DLLs themselves are built from the same commit by
`scripts/windows-local-runtime/build-whisper-runtime.py`, pinned in
`scripts/windows-local-runtime/dependencies.json`.

Updating whisper.cpp means replacing these headers, their hashes, the expected
version in `WindowsWhisper.cpp` and the runtime pin together.
`scripts/windows-local-runtime/test_whisper_runtime.py` checks that the header
hashes, this file and the runtime pin agree.
