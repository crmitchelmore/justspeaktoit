#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "include/CLlamaCpp.h"
#include "upstream/llama.h"
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#if defined(_WIN32)
#define NOMINMAX
#include <windows.h>
#elif defined(__linux__)
#include <dlfcn.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <unistd.h>
#endif

struct JSTILlamaRun {
    std::atomic<bool> cancelled{false};
    std::chrono::steady_clock::time_point deadline;
    bool stopped() const {
        return cancelled.load(std::memory_order_relaxed) || std::chrono::steady_clock::now() >= deadline;
    }
};

namespace {
void require(bool condition, const char *message) {
    if (!condition) throw std::runtime_error(message);
}
void message(char *out, size_t capacity, const char *value) {
    if (out && capacity) {
        const size_t count = std::min(capacity - 1, std::strlen(value));
        std::memcpy(out, value, count); out[count] = 0;
    }
}
bool abortRun(void *context) { return static_cast<JSTILlamaRun *>(context)->stopped(); }
bool loadProgress(float, void *context) { return !abortRun(context); }
std::timed_mutex inferenceMutex;

#if defined(_WIN32) || defined(__linux__)
#define JSTI_LLAMA_SYMBOLS(X) \
    X(llama_backend_init) X(llama_backend_free) \
    X(llama_model_default_params) X(llama_context_default_params) \
    X(llama_model_load_from_file) X(llama_model_free) X(llama_init_from_model) X(llama_free) \
    X(llama_model_get_vocab) X(llama_model_has_encoder) X(llama_model_has_decoder) \
    X(llama_model_chat_template) X(llama_model_meta_val_str) X(llama_chat_apply_template) \
    X(llama_tokenize) X(llama_token_to_piece) X(llama_vocab_is_eog) \
    X(llama_batch_get_one) X(llama_decode) X(llama_n_ctx) \
    X(llama_sampler_chain_default_params) X(llama_sampler_chain_init) X(llama_sampler_chain_add) \
    X(llama_sampler_init_greedy) X(llama_sampler_init_temp) X(llama_sampler_init_dist) \
    X(llama_sampler_sample) X(llama_sampler_free)

#if defined(_WIN32)
std::wstring wide(const char *text) {
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, nullptr, 0);
    require(length > 0, "Invalid UTF-8 path.");
    std::wstring result(static_cast<size_t>(length), 0);
    require(MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text, -1, &result[0], length) == length,
        "Invalid UTF-8 path.");
    result.pop_back(); return result;
}
#endif
struct Library {
#if defined(_WIN32)
    HMODULE handle = nullptr;
#else
    void *handle = nullptr;
#endif
    bool initialized = false;
#define DECLARE(name) decltype(&::name) name = nullptr;
    JSTI_LLAMA_SYMBOLS(DECLARE)
#undef DECLARE
    explicit Library(const char *path) {
#if defined(_WIN32)
        const auto full = wide(path);
        require(full.size() > 3 && full[1] == L':' && (full[2] == L'\\' || full[2] == L'/'),
            "The llama.cpp DLL path must be absolute.");
        handle = LoadLibraryExW(full.c_str(), nullptr, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
#else
        require(path[0] == '/', "The llama.cpp SO path must be absolute.");
        handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
#endif
        require(handle != nullptr, "The provisioned llama.cpp library or its private dependencies could not load.");
        try {
#if defined(_WIN32)
#define RESOLVE(name) name = reinterpret_cast<decltype(name)>(GetProcAddress(handle, #name)); \
    require(name != nullptr, "The pinned llama.cpp ABI is missing " #name ".");
#else
#define RESOLVE(name) name = reinterpret_cast<decltype(name)>(dlsym(handle, #name)); \
    require(name != nullptr, "The pinned llama.cpp ABI is missing " #name ".");
#endif
            JSTI_LLAMA_SYMBOLS(RESOLVE)
#undef RESOLVE
            llama_backend_init();
            initialized = true;
        } catch (...) { close(); throw; }
    }
    void close() {
        if (initialized) { llama_backend_free(); initialized = false; }
#if defined(_WIN32)
        if (handle) FreeLibrary(handle);
#else
        if (handle) dlclose(handle);
#endif
        handle = nullptr;
    }
    ~Library() { close(); }
};

/// Windows denies existing/new writers and deletion while the model is mapped.
/// Linux loads a sealed anonymous snapshot, not mutable source-file bytes.
struct ModelSnapshot {
    std::string path;
    const uint8_t *bytes = nullptr;
    size_t count = 0;
#if defined(_WIN32)
    HANDLE file = INVALID_HANDLE_VALUE, mapping = nullptr;
#else
    int sealed = -1;
#endif
    ModelSnapshot(const char *source, int64_t expected, JSTILlamaRun &run) {
        try {
            require(expected >= 24 && expected <= INT64_C(17179869184), "Invalid GGUF byte count.");
            count = static_cast<size_t>(expected);
#if defined(_WIN32)
            const auto full = wide(source);
            file = CreateFileW(full.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
            require(file != INVALID_HANDLE_VALUE, "GGUF cannot be opened without competing writers.");
            FILE_ATTRIBUTE_TAG_INFO attributes{};
            LARGE_INTEGER size{};
            require(GetFileInformationByHandleEx(file, FileAttributeTagInfo, &attributes, sizeof(attributes))
                && !(attributes.FileAttributes & (FILE_ATTRIBUTE_REPARSE_POINT | FILE_ATTRIBUTE_DIRECTORY))
                && GetFileSizeEx(file, &size) && size.QuadPart == expected, "Invalid GGUF file or size.");
            mapping = CreateFileMappingW(file, nullptr, PAGE_READONLY, 0, 0, nullptr);
            require(mapping != nullptr, "GGUF mapping failed.");
            bytes = static_cast<const uint8_t *>(MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, 0));
            require(bytes != nullptr, "GGUF mapping failed.");
            path = source;
#else
            const int input = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
            require(input >= 0, "GGUF file could not be opened.");
            struct Input { int fd; ~Input() { close(fd); } } inputOwner{input};
            struct stat info{};
            require(fstat(input, &info) == 0 && S_ISREG(info.st_mode) && info.st_size == expected,
                "Invalid GGUF file or size.");
            sealed = static_cast<int>(syscall(SYS_memfd_create, "jsti-gguf", MFD_CLOEXEC | MFD_ALLOW_SEALING));
            require(sealed >= 0, "A sealed in-process GGUF snapshot could not be created.");
            std::vector<uint8_t> buffer(4 * 1024 * 1024);
            size_t copied = 0;
            while (copied < count) {
                require(!run.stopped(), "GGUF snapshot cancelled.");
                const ssize_t n = read(input, buffer.data(), std::min(buffer.size(), count - copied));
                require(n > 0, "GGUF snapshot read failed.");
                ssize_t offset = 0;
                while (offset < n) {
                    const ssize_t written = write(sealed, buffer.data() + offset, static_cast<size_t>(n - offset));
                    require(written > 0, "GGUF snapshot write failed.");
                    offset += written;
                }
                copied += static_cast<size_t>(n);
            }
            require(fcntl(sealed, F_ADD_SEALS, F_SEAL_WRITE | F_SEAL_GROW | F_SEAL_SHRINK | F_SEAL_SEAL) == 0,
                "GGUF snapshot could not be sealed.");
            void *mapped = mmap(nullptr, count, PROT_READ, MAP_SHARED, sealed, 0);
            require(mapped != MAP_FAILED, "GGUF snapshot mapping failed.");
            bytes = static_cast<const uint8_t *>(mapped);
            path = "/proc/self/fd/" + std::to_string(sealed);
#endif
        } catch (...) { release(); throw; }
    }
    void release() {
#if defined(_WIN32)
        if (bytes) UnmapViewOfFile(bytes);
        if (mapping) CloseHandle(mapping);
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        mapping = nullptr; file = INVALID_HANDLE_VALUE;
#else
        if (bytes) munmap(const_cast<uint8_t *>(bytes), count);
        if (sealed >= 0) close(sealed);
        sealed = -1;
#endif
        bytes = nullptr;
    }
    ~ModelSnapshot() { release(); }
};

std::string complete(
    JSTILlamaRun &run, const char *library, const char *file, int64_t size,
    JSTILlamaVerify verify, void *verifyContext, const char *system, const char *user, double temperature) {
    ModelSnapshot snapshot(file, size, run);
    require(verify(snapshot.bytes, snapshot.count, verifyContext) == 0, "GGUF snapshot failed SHA-256 verification.");
    require(!run.stopped(), "Local cleanup cancelled.");
    Library api(library);
    auto mp = api.llama_model_default_params();
    mp.n_gpu_layers = 0;
    mp.use_mmap = true;
    mp.check_tensors = true;
    mp.progress_callback = loadProgress;
    mp.progress_callback_user_data = &run;
    auto modelDeleter = [&](llama_model *value) { api.llama_model_free(value); };
    std::unique_ptr<llama_model, decltype(modelDeleter)> model(
        api.llama_model_load_from_file(snapshot.path.c_str(), mp), modelDeleter);
    require(model != nullptr, "The native runtime could not load this GGUF model.");
    require(!api.llama_model_has_encoder(model.get()) && api.llama_model_has_decoder(model.get()),
        "Only decoder-only text instruction models are supported.");
    const auto *vocab = api.llama_model_get_vocab(model.get());
    require(vocab != nullptr, "The GGUF model has no text vocabulary.");
    const char *tmpl = api.llama_model_chat_template(model.get(), nullptr);
    require(tmpl != nullptr, "This GGUF has no supported chat template. No raw-prompt fallback was used.");
    const llama_chat_message messages[] = {{"system", system}, {"user", user}};
    const int32_t required = api.llama_chat_apply_template(tmpl, messages, 2, true, nullptr, 0);
    require(required > 0 && required <= 512 * 1024, "This GGUF chat template is unsupported or too large.");
    std::vector<char> rendered(static_cast<size_t>(required) + 1);
    require(api.llama_chat_apply_template(tmpl, messages, 2, true, rendered.data(),
        static_cast<int32_t>(rendered.size())) == required, "The GGUF chat template could not be rendered.");
    std::string prompt(rendered.data(), static_cast<size_t>(required));
    char architecture[64]{};
    if (api.llama_model_meta_val_str(model.get(), "general.architecture", architecture, sizeof(architecture)) > 0
        && std::string(architecture) == "qwen3") {
        // Qwen3's documented non-thinking assistant prefill; neither input role is rewritten.
        prompt += "<think>\n\n</think>\n\n";
    }
    const int32_t wanted = api.llama_tokenize(vocab, prompt.data(), static_cast<int32_t>(prompt.size()),
        nullptr, 0, true, true);
    require(wanted < 0 && wanted > -4096, "The transcript and instructions exceed the local model's context budget.");
    std::vector<llama_token> tokens(static_cast<size_t>(-wanted));
    require(api.llama_tokenize(vocab, prompt.data(), static_cast<int32_t>(prompt.size()),
        tokens.data(), static_cast<int32_t>(tokens.size()), true, true) == -wanted, "Tokenization failed.");
    auto cp = api.llama_context_default_params();
    cp.n_ctx = 4096; cp.n_batch = 256; cp.n_ubatch = 256;
    cp.n_threads = static_cast<int32_t>(std::max(1u, std::min(8u, std::thread::hardware_concurrency())));
    cp.n_threads_batch = cp.n_threads;
    cp.offload_kqv = false; cp.op_offload = false;
    cp.abort_callback = abortRun; cp.abort_callback_data = &run;
    auto contextDeleter = [&](llama_context *value) { api.llama_free(value); };
    std::unique_ptr<llama_context, decltype(contextDeleter)> context(
        api.llama_init_from_model(model.get(), cp), contextDeleter);
    require(context != nullptr, "The model context could not be created.");
    const size_t available = api.llama_n_ctx(context.get());
    require(tokens.size() < available, "The transcript leaves no room for a complete cleanup response.");
    auto samplerDeleter = [&](llama_sampler *value) { api.llama_sampler_free(value); };
    std::unique_ptr<llama_sampler, decltype(samplerDeleter)> sampler(
        api.llama_sampler_chain_init(api.llama_sampler_chain_default_params()), samplerDeleter);
    require(sampler != nullptr, "Sampler allocation failed.");
    auto addSampler = [&](llama_sampler *part) {
        require(part != nullptr, "Sampler allocation failed."); api.llama_sampler_chain_add(sampler.get(), part);
    };
    if (temperature == 0) addSampler(api.llama_sampler_init_greedy());
    else {
        addSampler(api.llama_sampler_init_temp(static_cast<float>(temperature)));
        addSampler(api.llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    }
    for (size_t offset = 0; offset < tokens.size(); offset += 256) {
        require(!run.stopped(), "Local cleanup cancelled.");
        const auto count = static_cast<int32_t>(std::min(size_t(256), tokens.size() - offset));
        require(api.llama_decode(context.get(), api.llama_batch_get_one(tokens.data() + offset, count)) == 0,
            "The model failed while reading the transcript.");
    }
    std::string output;
    const size_t budget = std::min(size_t(2048), available - tokens.size());
    for (size_t i = 0; i < budget; ++i) {
        require(!run.stopped(), "Local cleanup cancelled.");
        llama_token token = api.llama_sampler_sample(sampler.get(), context.get(), -1);
        if (api.llama_vocab_is_eog(vocab, token)) return output;
        std::vector<char> piece(256);
        int32_t count = api.llama_token_to_piece(vocab, token, piece.data(), 256, 0, false);
        if (count < 0 && count > -65536) {
            piece.resize(static_cast<size_t>(-count));
            count = api.llama_token_to_piece(vocab, token, piece.data(), static_cast<int32_t>(piece.size()), 0, false);
        }
        require(count >= 0 && static_cast<size_t>(count) <= piece.size(), "Model output decoding failed.");
        require(std::memchr(piece.data(), 0, static_cast<size_t>(count)) == nullptr,
            "The model returned an invalid NUL-containing text response.");
        output.append(piece.data(), static_cast<size_t>(count));
        require(output.size() <= 256 * 1024, "The model output exceeded the cleanup budget.");
        require(api.llama_decode(context.get(), api.llama_batch_get_one(&token, 1)) == 0,
            "The model failed while generating cleanup.");
    }
    throw std::runtime_error("The model did not finish within the context/output budget. No partial output was used.");
}
#endif
}

extern "C" JSTILlamaRun *jsti_llama_run_create(void) {
    try { return new JSTILlamaRun(); } catch (...) { return nullptr; }
}
extern "C" void jsti_llama_run_cancel(JSTILlamaRun *run) { if (run) run->cancelled.store(true); }
extern "C" int32_t jsti_llama_run_is_cancelled(JSTILlamaRun *run) {
    return run && run->cancelled.load() ? 1 : 0;
}
extern "C" void jsti_llama_run_destroy(JSTILlamaRun *run) { delete run; }
extern "C" void jsti_llama_string_free(char *value) { std::free(value); }
extern "C" int32_t jsti_llama_run_complete(
    JSTILlamaRun *run, const char *library, const char *file, int64_t bytes,
    JSTILlamaVerify verify, void *verifyContext, const char *system, const char *user,
    double temperature, char **output, char *error, size_t capacity) {
    if (output) *output = nullptr;
    if (!run || !library || !file || !verify || !system || !user || !output
        || !std::isfinite(temperature) || temperature < 0 || temperature > 1) {
        message(error, capacity, "Invalid local cleanup request."); return 1;
    }
    run->deadline = std::chrono::steady_clock::now() + std::chrono::minutes(2);
    try {
        std::unique_lock<std::timed_mutex> lock(inferenceMutex, std::defer_lock);
        while (!lock.try_lock_for(std::chrono::milliseconds(25))) {
            require(!run->stopped(), "Local cleanup cancelled while waiting for the native runtime.");
        }
        require(!run->stopped(), "Local cleanup cancelled.");
#if defined(_WIN32) || defined(__linux__)
        const std::string text = complete(*run, library, file, bytes, verify, verifyContext, system, user, temperature);
        require(!run->stopped(), "Local cleanup cancelled.");
        char *copy = static_cast<char *>(std::malloc(text.size() + 1));
        require(copy != nullptr, "Output allocation failed.");
        std::memcpy(copy, text.c_str(), text.size() + 1); *output = copy; return 0;
#else
        throw std::runtime_error("This host has no native desktop llama.cpp adapter.");
#endif
    } catch (const std::exception &failure) {
        message(error, capacity, failure.what());
        return run->cancelled.load() ? 2 : 1;
    } catch (...) {
        message(error, capacity, "Unexpected native llama.cpp failure."); return 1;
    }
}
