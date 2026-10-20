# llama.cpp ABI declarations

Unmodified public headers and MIT LICENSE from ggml-org/llama.cpp tag **b6500**,
commit **a7a98e0fffed794396b3fbad4dcdbbc184963645**.

Source: `https://github.com/ggml-org/llama.cpp/tree/a7a98e0fffed794396b3fbad4dcdbbc184963645`

Only declarations are vendored. No runtime, executable, model, or binary
qualification receipt is included. `LlamaCpp.cpp` resolves symbols using
`decltype(&upstream_function)` and uses the actual upstream parameter layouts.
Do not replace these headers independently of the runtime provisioning ABI.

The runtime must be a CPU-only, monolithic shared library with ggml statically
linked, `GGML_BACKEND_DL=OFF`, and no runtime backend discovery. Windows loads
only an absolute verified DLL path plus system dependencies; Linux uses an
absolute SO with local symbol visibility. No PATH/LD_LIBRARY_PATH mutation or
subprocess is used.
