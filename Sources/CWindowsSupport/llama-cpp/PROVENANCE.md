# Vendored llama.cpp headers

These seven headers are unmodified copies from
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp) tag `b10809`,
commit `5266f24da75dc449bd56cbed7addb9c8e4a6a73e`, under the MIT licence in
`LICENSE` beside them.

| File | Upstream path | SHA-256 |
|---|---|---|
| `llama.h` | `include/llama.h` | `3d1b18eda626c1b9ecf5bda0798e65b974a8f70f30d56726610633a980cb4160` |
| `ggml.h` | `ggml/include/ggml.h` | `34192eac913444df9dc1d23025a618448cdee1ee7d78597af4979d8edc77b695` |
| `ggml-cpu.h` | `ggml/include/ggml-cpu.h` | `316279e004cdeb8e6ef78599acb602bf79a8abdf897fed9fd1914808c1518c6e` |
| `ggml-backend.h` | `ggml/include/ggml-backend.h` | `46d84cb998105f871240864fd0f55446939a2fe86c5c281afa63a010fb1f65a2` |
| `ggml-alloc.h` | `ggml/include/ggml-alloc.h` | `94e4cd069b9313b2ceb35dacec901981e0bb478d8bb31035b7126be091998c23` |
| `ggml-opt.h` | `ggml/include/ggml-opt.h` | `3586de1bc8a934b5c72339e2b6937b0641e8f149b512231e666f67de0736eea2` |
| `gguf.h` | `ggml/include/gguf.h` | `e56714aab702e5ce62ee587a409643c08f7e93e8fbb77f48ef7cc85075f96fa4` |
| `LICENSE` | `LICENSE` | `94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d` |

The `ggml/` tree at this llama.cpp commit is byte-identical to the one in
whisper.cpp `v1.9.4` (ggml 0.23.0; only `ggml/.gitignore` differs), so the
four ggml headers that `whisper-cpp/` also vendors are the same bytes in both
directories. The runtime build refuses to link llama.cpp unless the two
checked-out ggml trees match, and builds `llama.dll` against the ggml that
whisper.cpp built, so one set of ggml DLLs serves both runtimes.

The app uses these headers only for declarations and struct layouts. It links
nothing from llama.cpp at build time: it loads `llama.dll` from the application
directory at run time, refuses a ggml whose `ggml_version()` is not `0.23.0`,
and resolves each function by name. The DLL is built from the same commit by
`scripts/windows-local-runtime/build-whisper-runtime.py`, pinned under
`llamaCpp` in `scripts/windows-local-runtime/dependencies.json`.

Updating llama.cpp means replacing these headers, their hashes and the runtime
pin together, and choosing a commit whose ggml tree matches the pinned
whisper.cpp's. `scripts/windows-local-runtime/test_whisper_runtime.py` checks
that the header hashes, this file and the runtime pin agree.
