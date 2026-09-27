# Builds jsti-llama-runner against a pinned llama.cpp checkout.
# build-llama-runtime.py passes LLAMA_SOURCE_DIR and JSTI_LLAMA_BUILD; the
# llama.cpp and ggml options come from scripts/windows-local-runtime/dependencies.json.
cmake_minimum_required(VERSION 3.21)
project(jsti_llama_runner C CXX)

if(NOT LLAMA_SOURCE_DIR)
    message(FATAL_ERROR "Set LLAMA_SOURCE_DIR to the pinned llama.cpp checkout.")
endif()
if(NOT JSTI_LLAMA_BUILD)
    message(FATAL_ERROR "Set JSTI_LLAMA_BUILD to the pinned llama.cpp tag and commit.")
endif()

# As a subproject llama.cpp builds only its libraries: no common, tools,
# examples, server or tests.
add_subdirectory(${LLAMA_SOURCE_DIR} llama.cpp)

add_executable(jsti-llama-runner jsti-llama-runner.cpp)
target_link_libraries(jsti-llama-runner PRIVATE llama)
target_compile_features(jsti-llama-runner PRIVATE cxx_std_17)
target_compile_definitions(jsti-llama-runner PRIVATE JSTI_LLAMA_BUILD="${JSTI_LLAMA_BUILD}")
if(MSVC)
    # MSVC starts a console program defining wmain through wmainCRTStartup,
    # so non-ASCII model paths arrive intact.
    target_compile_definitions(jsti-llama-runner PRIVATE UNICODE _UNICODE)
elseif(MINGW)
    target_link_options(jsti-llama-runner PRIVATE -municode)
endif()
# Everything lands beside the executable, where the app runs it from.
set_target_properties(jsti-llama-runner PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
    RUNTIME_OUTPUT_DIRECTORY_RELEASE ${CMAKE_BINARY_DIR}/bin)
