# Adds ggml once for every native runtime. whisper.cpp uses it now; llama.cpp (#1660) must link
# this same `ggml` target rather than its own copy, so both runtimes stay one library. The source
# defaults to the ggml bundled with the pinned whisper.cpp (cmake/whisper.cmake); point
# JSTI_GGML_SOURCE_DIR elsewhere only for a ggml that both runtimes are pinned against.
include_guard(GLOBAL)

if (NOT JSTI_GGML_SOURCE_DIR)
    message(FATAL_ERROR "JSTI_GGML_SOURCE_DIR is not set; include whisper.cmake first")
endif()

# CPU only, portable across every phone the ABI covers. GGML_NATIVE would tune for the build
# machine, KleidiAI fetches more source at configure time, and OpenMP is replaced by ggml's own
# thread pool.
set(GGML_NATIVE OFF CACHE BOOL "" FORCE)
set(GGML_CCACHE OFF CACHE BOOL "" FORCE)
set(GGML_OPENMP OFF CACHE BOOL "" FORCE)
set(GGML_BACKEND_DL OFF CACHE BOOL "" FORCE)
set(GGML_CPU_KLEIDIAI OFF CACHE BOOL "" FORCE)
set(GGML_BLAS OFF CACHE BOOL "" FORCE)
set(GGML_METAL OFF CACHE BOOL "" FORCE)
set(GGML_VULKAN OFF CACHE BOOL "" FORCE)
set(GGML_OPENCL OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_TESTS OFF CACHE BOOL "" FORCE)
set(GGML_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(GGML_ALL_WARNINGS OFF CACHE BOOL "" FORCE)
# arm64-v8a: the armv8.0-a baseline every arm64 Android phone has. dotprod/fp16 kernels need a
# runtime-selected variant (follow-up in Docs/android-on-device-models.md) to avoid SIGILL on
# older cores.
set(GGML_CPU_ARM_ARCH "" CACHE STRING "" FORCE)
# x86_64 is the emulator: SSE4.2 only, since AVX is not guaranteed in emulator guests.
set(GGML_SSE42 ON CACHE BOOL "" FORCE)
foreach(feature AVX AVX2 AVX_VNNI AVX512 FMA F16C BMI2)
    set(GGML_${feature} OFF CACHE BOOL "" FORCE)
endforeach()

add_subdirectory("${JSTI_GGML_SOURCE_DIR}" "${CMAKE_BINARY_DIR}/ggml" EXCLUDE_FROM_ALL)

foreach(target ggml ggml-base ggml-cpu)
    if (TARGET ${target})
        target_compile_options(${target} PRIVATE ${JSTI_RUNTIME_COMPILE_OPTIONS} -w)
    endif()
endforeach()
