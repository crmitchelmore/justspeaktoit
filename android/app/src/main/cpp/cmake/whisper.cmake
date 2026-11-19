# Pinned whisper.cpp source and the static `jsti_whisper` library.
#
# The release archive is fetched by URL and checked against its SHA-256 before CMake extracts it;
# a mismatch fails the configure. Offline builds pass a local copy of the same archive with
# -DJSTI_WHISPER_CPP_ARCHIVE=/path/whisper.cpp-v1.9.5.tar.gz (Gradle: -Pjsti.whisperCppArchive=...);
# its hash is checked the same way (cmake/native-sources.cmake).
include_guard(GLOBAL)
include(native-sources)

set(JSTI_WHISPER_CPP_VERSION "1.9.5")
# Tag v1.9.5 is commit d2a764c648779feb36d44363f212a29b00aad1af.
set(JSTI_WHISPER_CPP_URL
    "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${JSTI_WHISPER_CPP_VERSION}.tar.gz")
set(JSTI_WHISPER_CPP_SHA256 "ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720")

set(JSTI_WHISPER_CPP_ARCHIVE "" CACHE FILEPATH "Local copy of the pinned whisper.cpp release archive")

jsti_pinned_archive(JSTI_WHISPER_CPP_SOURCE "whisper.cpp-v${JSTI_WHISPER_CPP_VERSION}.tar.gz"
    "${JSTI_WHISPER_CPP_URL}" "${JSTI_WHISPER_CPP_SHA256}" "${JSTI_WHISPER_CPP_ARCHIVE}")
jsti_extract_pinned_source(whispercpp "${JSTI_WHISPER_CPP_SOURCE}" "${JSTI_WHISPER_CPP_SHA256}")

# ggml.cmake builds ggml from this tree unless JSTI_GGML_SOURCE_DIR names another one.
if (NOT JSTI_GGML_SOURCE_DIR)
    set(JSTI_GGML_SOURCE_DIR "${whispercpp_SOURCE_DIR}/ggml")
endif()

function(jsti_add_whisper)
    add_library(jsti_whisper STATIC
        "${whispercpp_SOURCE_DIR}/src/whisper.cpp"
        # A no-op stub off Apple Silicon, but whisper.cpp calls into it.
        "${whispercpp_SOURCE_DIR}/src/aneforge/whisper-aneforge.cpp")
    target_include_directories(jsti_whisper
        PUBLIC "${whispercpp_SOURCE_DIR}/include"
        PRIVATE "${whispercpp_SOURCE_DIR}/src")
    target_compile_definitions(jsti_whisper PRIVATE WHISPER_VERSION="${JSTI_WHISPER_CPP_VERSION}")
    target_compile_options(jsti_whisper PRIVATE ${JSTI_RUNTIME_COMPILE_OPTIONS} -w)
    target_link_libraries(jsti_whisper PUBLIC ggml)
endfunction()
