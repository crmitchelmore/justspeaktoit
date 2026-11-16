# Pinned whisper.cpp source and the static `jsti_whisper` library.
#
# The release archive is fetched by URL and checked against its SHA-256 before CMake extracts it;
# a mismatch fails the configure. Offline builds pass a local copy of the same archive with
# -DJSTI_WHISPER_CPP_ARCHIVE=/path/whisper.cpp-v1.9.5.tar.gz (Gradle: -Pjsti.whisperCppArchive=...);
# its hash is checked the same way. JSTI_NATIVE_SOURCE_CACHE keeps one verified copy for every
# ABI and build type, so a Gradle build downloads it once.
include_guard(GLOBAL)
include(FetchContent)

set(JSTI_WHISPER_CPP_VERSION "1.9.5")
# Tag v1.9.5 is commit d2a764c648779feb36d44363f212a29b00aad1af.
set(JSTI_WHISPER_CPP_URL
    "https://github.com/ggml-org/whisper.cpp/archive/refs/tags/v${JSTI_WHISPER_CPP_VERSION}.tar.gz")
set(JSTI_WHISPER_CPP_SHA256 "ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720")

set(JSTI_WHISPER_CPP_ARCHIVE "" CACHE FILEPATH "Local copy of the pinned whisper.cpp release archive")
set(JSTI_NATIVE_SOURCE_CACHE "" CACHE PATH "Directory that keeps verified third-party source archives")

function(jsti_whisper_cpp_archive out_var)
    if (JSTI_WHISPER_CPP_ARCHIVE)
        set(${out_var} "${JSTI_WHISPER_CPP_ARCHIVE}" PARENT_SCOPE)
        return()
    endif()
    if (NOT JSTI_NATIVE_SOURCE_CACHE)
        set(${out_var} "${JSTI_WHISPER_CPP_URL}" PARENT_SCOPE)
        return()
    endif()
    set(archive "${JSTI_NATIVE_SOURCE_CACHE}/whisper.cpp-v${JSTI_WHISPER_CPP_VERSION}.tar.gz")
    file(MAKE_DIRECTORY "${JSTI_NATIVE_SOURCE_CACHE}")
    # ABIs configure in parallel; the lock keeps them from writing the same file.
    file(LOCK "${JSTI_NATIVE_SOURCE_CACHE}/.lock" GUARD FUNCTION TIMEOUT 600)
    set(have_archive FALSE)
    if (EXISTS "${archive}")
        file(SHA256 "${archive}" existing)
        if (existing STREQUAL JSTI_WHISPER_CPP_SHA256)
            set(have_archive TRUE)
        endif()
    endif()
    if (NOT have_archive)
        file(DOWNLOAD "${JSTI_WHISPER_CPP_URL}" "${archive}.part"
            EXPECTED_HASH SHA256=${JSTI_WHISPER_CPP_SHA256}
            TLS_VERIFY ON
            STATUS status)
        list(GET status 0 code)
        if (NOT code EQUAL 0)
            file(REMOVE "${archive}.part")
            message(FATAL_ERROR "Could not download whisper.cpp ${JSTI_WHISPER_CPP_VERSION}: ${status}")
        endif()
        file(RENAME "${archive}.part" "${archive}")
    endif()
    set(${out_var} "${archive}" PARENT_SCOPE)
endfunction()

jsti_whisper_cpp_archive(JSTI_WHISPER_CPP_SOURCE)
# SOURCE_SUBDIR names a directory without a CMakeLists.txt, so MakeAvailable only extracts the
# source: upstream's root project would add its own ggml, examples and parakeet.
FetchContent_Declare(whispercpp
    URL "${JSTI_WHISPER_CPP_SOURCE}"
    URL_HASH SHA256=${JSTI_WHISPER_CPP_SHA256}
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE
    SOURCE_SUBDIR jsti-extract-only)
FetchContent_MakeAvailable(whispercpp)

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
