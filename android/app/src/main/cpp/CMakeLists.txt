# On-device model runtimes for Android, built from pinned upstream source (no prebuilt binaries).
#
# One shared library, libjsti_local_models.so, holds the JNI bridges and links every runtime
# statically. ggml is added once by cmake/ggml.cmake so whisper.cpp (#1658) and llama.cpp (#1660)
# share a single copy. See Docs/android-on-device-models.md, "Native build".
cmake_minimum_required(VERSION 3.24)
project(jsti_local_models C CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(BUILD_SHARED_LIBS OFF)

# Inference is unusably slow unoptimised, so debug builds optimise the runtimes too; only the
# bridge keeps the build type's flags.
set(JSTI_RUNTIME_COMPILE_OPTIONS -O3 -DNDEBUG -ffunction-sections -fdata-sections)

list(APPEND CMAKE_MODULE_PATH "${CMAKE_CURRENT_LIST_DIR}/cmake")
include(whisper)
include(llama)
include(ggml)
jsti_add_whisper()
jsti_add_llama()

add_library(jsti_local_models SHARED whisper_jni.cpp llama_jni.cpp)
target_link_libraries(jsti_local_models PRIVATE jsti_whisper jsti_llama android log)
target_compile_options(jsti_local_models PRIVATE -Wall -Wextra -Werror -fvisibility=hidden)
# Keep only the JNI entry points exported; drop unused runtime code. 16 KB pages are required on
# Android 15+ devices that use them (AGP passes the matching max-page-size).
target_link_options(jsti_local_models PRIVATE
    -Wl,--gc-sections
    -Wl,--exclude-libs,ALL
    -Wl,-z,max-page-size=16384)
