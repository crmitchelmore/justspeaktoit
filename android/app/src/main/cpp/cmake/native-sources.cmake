# Verified third-party source archives for the native runtimes.
#
# Every archive is pinned by URL and SHA-256 and checked before CMake extracts it; a mismatch fails
# the configure. JSTI_NATIVE_SOURCE_CACHE keeps one verified copy for every ABI and build type, so
# a Gradle build downloads each archive once. A per-runtime local override (for offline builds) is
# checked the same way.
include_guard(GLOBAL)
include(FetchContent)

set(JSTI_NATIVE_SOURCE_CACHE "" CACHE PATH "Directory that keeps verified third-party source archives")

# jsti_pinned_archive(<out_var> <cache_file_name> <url> <sha256> <local_override>)
# Sets <out_var> to the local override, a verified cached copy, or the URL for FetchContent to
# download and verify itself.
function(jsti_pinned_archive out_var file_name url sha256 local_override)
    if (local_override)
        set(${out_var} "${local_override}" PARENT_SCOPE)
        return()
    endif()
    if (NOT JSTI_NATIVE_SOURCE_CACHE)
        set(${out_var} "${url}" PARENT_SCOPE)
        return()
    endif()
    set(archive "${JSTI_NATIVE_SOURCE_CACHE}/${file_name}")
    file(MAKE_DIRECTORY "${JSTI_NATIVE_SOURCE_CACHE}")
    # ABIs configure in parallel; the lock keeps them from writing the same file.
    file(LOCK "${JSTI_NATIVE_SOURCE_CACHE}/.lock" GUARD FUNCTION TIMEOUT 600)
    set(have_archive FALSE)
    if (EXISTS "${archive}")
        file(SHA256 "${archive}" existing)
        if (existing STREQUAL sha256)
            set(have_archive TRUE)
        endif()
    endif()
    if (NOT have_archive)
        file(DOWNLOAD "${url}" "${archive}.part"
            EXPECTED_HASH SHA256=${sha256}
            TLS_VERIFY ON
            STATUS status)
        list(GET status 0 code)
        if (NOT code EQUAL 0)
            file(REMOVE "${archive}.part")
            message(FATAL_ERROR "Could not download ${file_name}: ${status}")
        endif()
        file(RENAME "${archive}.part" "${archive}")
    endif()
    set(${out_var} "${archive}" PARENT_SCOPE)
endfunction()

# jsti_extract_pinned_source(<name> <source> <sha256>)
# SOURCE_SUBDIR names a directory without a CMakeLists.txt, so MakeAvailable only extracts the
# source: an upstream root project would add its own ggml, examples and tools.
macro(jsti_extract_pinned_source name source sha256)
    FetchContent_Declare(${name}
        URL "${source}"
        URL_HASH SHA256=${sha256}
        DOWNLOAD_EXTRACT_TIMESTAMP TRUE
        SOURCE_SUBDIR jsti-extract-only)
    FetchContent_MakeAvailable(${name})
endmacro()
