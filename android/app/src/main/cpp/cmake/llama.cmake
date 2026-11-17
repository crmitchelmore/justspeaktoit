# Pinned llama.cpp source and the static `jsti_llama` library for downloaded cleanup models.
#
# llama.cpp links the one shared `ggml` target that cmake/ggml.cmake adds from the pinned
# whisper.cpp, never its own copy. The pin is chosen so the two match: whisper.cpp v1.9.5 syncs
# ggml commit ffa4e8b8, whose scripts/sync-llama.last is llama.cpp e117148a (tag b11425). The
# ggml trees in the two archives are source-identical (only the version line in
# ggml/CMakeLists.txt differs), and the configure below fails if a future bump of either pin lets
# the public ggml headers drift apart. See Docs/android-on-device-models.md, "Native build".
#
# Offline builds pass a local copy of the same archive with
# -DJSTI_LLAMA_CPP_ARCHIVE=/path/llama.cpp-b11425.tar.gz (Gradle: -Pjsti.llamaCppArchive=...);
# its hash is checked the same way.
include_guard(GLOBAL)
include(native-sources)

set(JSTI_LLAMA_CPP_TAG "b11425")
set(JSTI_LLAMA_CPP_COMMIT "e117148a41d8e9bedb72e4c6c3f003ab0fe7f857")
set(JSTI_LLAMA_CPP_URL "https://github.com/ggml-org/llama.cpp/archive/refs/tags/${JSTI_LLAMA_CPP_TAG}.tar.gz")
set(JSTI_LLAMA_CPP_SHA256 "3bf5a64c06ecfac21fcf3d44b180177a1ced2b170a9d9a98dfe435d71c83c92a")

set(JSTI_LLAMA_CPP_ARCHIVE "" CACHE FILEPATH "Local copy of the pinned llama.cpp release archive")

jsti_pinned_archive(JSTI_LLAMA_CPP_SOURCE "llama.cpp-${JSTI_LLAMA_CPP_TAG}.tar.gz"
    "${JSTI_LLAMA_CPP_URL}" "${JSTI_LLAMA_CPP_SHA256}" "${JSTI_LLAMA_CPP_ARCHIVE}")
jsti_extract_pinned_source(llamacpp "${JSTI_LLAMA_CPP_SOURCE}" "${JSTI_LLAMA_CPP_SHA256}")

# llama.cpp compiles against the shared ggml's headers, so its own bundled ggml must expose the
# same API. Any difference means the two pins no longer agree.
function(jsti_require_matching_ggml shared_ggml_dir)
    file(GLOB_RECURSE llama_headers RELATIVE "${llamacpp_SOURCE_DIR}/ggml/include"
        "${llamacpp_SOURCE_DIR}/ggml/include/*.h")
    file(GLOB_RECURSE shared_headers RELATIVE "${shared_ggml_dir}/include" "${shared_ggml_dir}/include/*.h")
    list(SORT llama_headers)
    list(SORT shared_headers)
    if (NOT llama_headers STREQUAL shared_headers)
        message(FATAL_ERROR "llama.cpp ${JSTI_LLAMA_CPP_TAG} and the shared ggml list different headers")
    endif()
    foreach(header IN LISTS llama_headers)
        file(SHA256 "${llamacpp_SOURCE_DIR}/ggml/include/${header}" llama_hash)
        file(SHA256 "${shared_ggml_dir}/include/${header}" shared_hash)
        if (NOT llama_hash STREQUAL shared_hash)
            message(FATAL_ERROR
                "ggml/include/${header} differs between llama.cpp ${JSTI_LLAMA_CPP_TAG} and the shared ggml; "
                "pin a llama.cpp release whose ggml matches whisper.cpp's")
        endif()
    endforeach()
endfunction()

function(jsti_add_llama)
    if (NOT TARGET ggml)
        message(FATAL_ERROR "include ggml.cmake before calling jsti_add_llama")
    endif()
    jsti_require_matching_ggml("${JSTI_GGML_SOURCE_DIR}")

    set(src "${llamacpp_SOURCE_DIR}/src")
    file(GLOB llama_core_sources "${src}/*.cpp")
    file(GLOB llama_model_sources "${src}/models/*.cpp")
    add_library(jsti_llama STATIC ${llama_core_sources} ${llama_model_sources})

    set(LLAMA_VERSION "${JSTI_LLAMA_CPP_TAG}")
    set(LLAMA_BUILD_COMMIT "${JSTI_LLAMA_CPP_COMMIT}")
    configure_file("${src}/llama-version.h.in" "${CMAKE_CURRENT_BINARY_DIR}/llama/llama-version.h" @ONLY)

    # Upstream unity-builds the per-architecture model files; it cuts the build roughly in half.
    set_target_properties(jsti_llama PROPERTIES UNITY_BUILD ON UNITY_BUILD_BATCH_SIZE 16)
    set_source_files_properties(${llama_core_sources} PROPERTIES SKIP_UNITY_BUILD_INCLUSION ON)
    target_include_directories(jsti_llama
        PUBLIC "${llamacpp_SOURCE_DIR}/include"
        PRIVATE "${src}" "${CMAKE_CURRENT_BINARY_DIR}/llama")
    target_compile_options(jsti_llama PRIVATE ${JSTI_RUNTIME_COMPILE_OPTIONS} -w)
    target_link_libraries(jsti_llama PUBLIC ggml)
endfunction()
