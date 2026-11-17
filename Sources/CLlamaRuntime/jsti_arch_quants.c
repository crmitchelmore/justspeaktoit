// Compiles ggml's CPU quantisation kernels for the architecture being built, as ggml's CMake does.
#if defined(__aarch64__) || defined(__arm64__)
#include "upstream/ggml/src/ggml-cpu/arch/arm/quants.c"
#elif defined(__x86_64__)
#include "upstream/ggml/src/ggml-cpu/arch/x86/quants.c"
#endif
