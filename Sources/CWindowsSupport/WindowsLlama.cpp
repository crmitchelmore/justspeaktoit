#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "llama-cpp/llama.h"
#include <cstdio>
#include <cstdlib>
#include <deque>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

// llama.cpp is loaded at run time, never linked. The declarations above come
// from headers vendored at the pinned build (see llama-cpp/PROVENANCE.md),
// whose ggml is byte for byte the ggml whisper.cpp 1.9.4 ships; the struct
// layouts are valid only for that build, so open() refuses any ggml other
// than the pinned version. llama.dll imports ggml.dll and ggml-base.dll by
// name, and Windows binds those imports to the copies already loaded from
// the same directory for whisper.cpp, so both runtimes share one ggml.
namespace {
constexpr const char *expectedGgmlVersion = "0.23.0";

struct LlamaApi {
    decltype(&ggml_version) ggmlVersion = nullptr;
    decltype(&ggml_backend_load_all_from_path) loadBackends = nullptr;
    decltype(&ggml_backend_dev_count) deviceCount = nullptr;
    decltype(&ggml_backend_dev_get) device = nullptr;
    decltype(&ggml_backend_dev_type) deviceType = nullptr;
    decltype(&ggml_backend_dev_name) deviceName = nullptr;
    decltype(&llama_backend_init) backendInit = nullptr;
    decltype(&llama_log_set) logSet = nullptr;
    decltype(&llama_model_default_params) modelDefaults = nullptr;
    decltype(&llama_context_default_params) contextDefaults = nullptr;
    decltype(&llama_sampler_chain_default_params) chainDefaults = nullptr;
    decltype(&llama_model_load_from_file) loadModel = nullptr;
    decltype(&llama_model_free) freeModel = nullptr;
    decltype(&llama_init_from_model) initContext = nullptr;
    decltype(&llama_free) freeContext = nullptr;
    decltype(&llama_model_get_vocab) vocab = nullptr;
    decltype(&llama_model_chat_template) chatTemplate = nullptr;
    decltype(&llama_chat_apply_template) applyTemplate = nullptr;
    decltype(&llama_tokenize) tokenize = nullptr;
    decltype(&llama_token_to_piece) tokenToPiece = nullptr;
    decltype(&llama_vocab_is_eog) isEndOfGeneration = nullptr;
    decltype(&llama_batch_get_one) batchOne = nullptr;
    decltype(&llama_decode) decode = nullptr;
    decltype(&llama_n_ctx) contextSize = nullptr;
    decltype(&llama_sampler_chain_init) chainInit = nullptr;
    decltype(&llama_sampler_chain_add) chainAdd = nullptr;
    decltype(&llama_sampler_init_greedy) greedy = nullptr;
    decltype(&llama_sampler_init_top_k) topK = nullptr;
    decltype(&llama_sampler_init_top_p) topP = nullptr;
    decltype(&llama_sampler_init_min_p) minP = nullptr;
    decltype(&llama_sampler_init_temp) temperature = nullptr;
    decltype(&llama_sampler_init_dist) distribution = nullptr;
    decltype(&llama_sampler_sample) sample = nullptr;
    decltype(&llama_sampler_free) freeSampler = nullptr;
};

// Recent log lines explain a failed load without exposing prompts or output:
// llama.cpp logs neither at these levels.
std::mutex logMutex;
std::deque<std::string> logLines;
std::string logPartial;

void logCallback(enum ggml_log_level level, const char *text, void *) {
    if (!text || (level != GGML_LOG_LEVEL_ERROR && level != GGML_LOG_LEVEL_WARN)) return;
    std::lock_guard<std::mutex> lock(logMutex);
    logPartial += text;
    size_t newline;
    while ((newline = logPartial.find('\n')) != std::string::npos) {
        if (newline) logLines.push_back(logPartial.substr(0, newline));
        logPartial.erase(0, newline + 1);
        while (logLines.size() > 8) logLines.pop_front();
    }
}

std::string lastLog() {
    std::lock_guard<std::mutex> lock(logMutex);
    return logLines.empty() ? std::string() : logLines.back();
}

template<class T> bool resolve(T &target, const char *name, const std::vector<HMODULE> &modules) {
    for (HMODULE module : modules) {
        if (!module) continue;
        if (FARPROC address = GetProcAddress(module, name)) {
            target = reinterpret_cast<T>(reinterpret_cast<void *>(address));
            return true;
        }
    }
    return false;
}

void normalisePath(std::wstring &path) {
    std::replace(path.begin(), path.end(), L'/', L'\\');
    if (path.size() > 3 && path[0] == L'\\' && path[2] == L':') path.erase(0, 1);
}

bool abortRequested(void *data) {
    return static_cast<JSTIWhisperJob *>(data)->cancelled.load(std::memory_order_relaxed);
}
} // namespace

struct JSTILlamaRuntime {
    std::wstring directory;
    HMODULE llama = nullptr;
    LlamaApi api;
    bool allowGPU = false;
    bool hasGPU = false;
    std::string description;
    std::mutex mutex; // Serialises model use and generation.
    llama_model *model = nullptr;
    std::wstring modelPath;
};

namespace {
std::mutex openMutex;
JSTILlamaRuntime *sharedRuntime = nullptr;

void releaseModel(JSTILlamaRuntime &runtime) {
    if (runtime.model) runtime.api.freeModel(runtime.model);
    runtime.model = nullptr;
    runtime.modelPath.clear();
}

void describe(JSTILlamaRuntime &runtime) {
    std::string gpus;
    bool cpu = false;
    const size_t count = runtime.api.deviceCount();
    for (size_t index = 0; index < count; ++index) {
        ggml_backend_dev_t device = runtime.api.device(index);
        if (!device) continue;
        const enum ggml_backend_dev_type type = runtime.api.deviceType(device);
        if (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
            const char *name = runtime.api.deviceName(device);
            gpus += (gpus.empty() ? "" : ", ") + std::string(name ? name : "GPU");
        } else if (type == GGML_BACKEND_DEVICE_TYPE_CPU) {
            cpu = true;
        }
    }
    runtime.hasGPU = !gpus.empty() && runtime.allowGPU;
    runtime.description = std::string("llama.cpp (ggml ") + expectedGgmlVersion + ")";
    if (!gpus.empty()) runtime.description += std::string(runtime.allowGPU ? "; GPU: " : "; GPU off: ") + gpus;
    runtime.description += cpu ? "; CPU" : "; no CPU backend";
}

// A chat template the model's metadata names, applied through llama.cpp's
// built-in template matcher; ChatML when the model has none it recognises.
bool formatPrompt(JSTILlamaRuntime &runtime, const char *systemPrompt, const char *userMessage, std::string &prompt) {
    const llama_chat_message messages[] = {{"system", systemPrompt}, {"user", userMessage}};
    const char *modelTemplate = runtime.api.chatTemplate(runtime.model, nullptr);
    for (const char *candidate : {modelTemplate, static_cast<const char *>("chatml")}) {
        if (!candidate) continue;
        std::vector<char> buffer(4096);
        int32_t length = runtime.api.applyTemplate(candidate, messages, 2, true, buffer.data(),
                                                   static_cast<int32_t>(buffer.size()));
        if (length > static_cast<int32_t>(buffer.size())) {
            buffer.resize(static_cast<size_t>(length) + 1);
            length = runtime.api.applyTemplate(candidate, messages, 2, true, buffer.data(),
                                               static_cast<int32_t>(buffer.size()));
        }
        if (length <= 0 || length > static_cast<int32_t>(buffer.size())) continue;
        prompt.assign(buffer.data(), static_cast<size_t>(length));
        // Reasoning models such as Qwen3 honour an empty thinking block as
        // "do not think"; this is what their template emits when thinking is off.
        if (candidate == modelTemplate && std::strstr(modelTemplate, "enable_thinking")) {
            prompt += "<think>\n\n</think>\n\n";
        }
        return true;
    }
    return false;
}
} // namespace

extern "C" JSTILlamaRuntime *jsti_llama_runtime_open(const char *directory, int allowGPU, char *error,
                                                     size_t capacity) {
    std::wstring folder;
    if (directory && jsti::wide(directory, folder)) normalisePath(folder);
    if (!directory || folder.size() < 3 || folder.size() > 32000 ||
        !(folder[1] == L':' || (folder[0] == L'\\' && folder[1] == L'\\'))) {
        jsti::fail("The language model runtime directory must be an absolute path.", error, capacity);
        return nullptr;
    }
    while (folder.size() > 3 && folder.back() == L'\\') folder.pop_back();
    std::lock_guard<std::mutex> lock(openMutex);
    if (sharedRuntime) {
        if (_wcsicmp(sharedRuntime->directory.c_str(), folder.c_str()) != 0) {
            jsti::fail("The language model runtime is already loaded from another directory.", error, capacity);
            return nullptr;
        }
        return sharedRuntime;
    }
    const std::wstring library = folder + L"\\llama.dll";
    const DWORD attributes = GetFileAttributesW(library.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES || (attributes & FILE_ATTRIBUTE_DIRECTORY)) {
        jsti::fail("The on-device language model runtime (llama.dll) is not installed beside the app.", error,
                   capacity);
        return nullptr;
    }
    if (allowGPU && GetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", nullptr, 0) == 0) {
        SetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", L"~implicit~");
    }
    DWORD previousMode = 0;
    SetThreadErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX, &previousMode);
    HMODULE llama = LoadLibraryExW(library.c_str(), nullptr,
                                   LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    const DWORD loadError = GetLastError();
    if (!llama) {
        SetThreadErrorMode(previousMode, nullptr);
        jsti::fail(jsti::systemError("Loading the on-device language model runtime", loadError), error, capacity);
        return nullptr;
    }
    auto *runtime = new (std::nothrow) JSTILlamaRuntime();
    if (!runtime) {
        SetThreadErrorMode(previousMode, nullptr);
        jsti::fail("Could not allocate the language model runtime.", error, capacity);
        return nullptr;
    }
    runtime->directory = folder;
    runtime->llama = llama;
    runtime->allowGPU = allowGPU != 0;
    const std::vector<HMODULE> modules = {llama, GetModuleHandleW(L"ggml.dll"), GetModuleHandleW(L"ggml-base.dll")};
    LlamaApi &api = runtime->api;
    const bool complete = resolve(api.ggmlVersion, "ggml_version", modules) &&
        resolve(api.loadBackends, "ggml_backend_load_all_from_path", modules) &&
        resolve(api.deviceCount, "ggml_backend_dev_count", modules) &&
        resolve(api.device, "ggml_backend_dev_get", modules) &&
        resolve(api.deviceType, "ggml_backend_dev_type", modules) &&
        resolve(api.deviceName, "ggml_backend_dev_name", modules) &&
        resolve(api.backendInit, "llama_backend_init", modules) &&
        resolve(api.logSet, "llama_log_set", modules) &&
        resolve(api.modelDefaults, "llama_model_default_params", modules) &&
        resolve(api.contextDefaults, "llama_context_default_params", modules) &&
        resolve(api.chainDefaults, "llama_sampler_chain_default_params", modules) &&
        resolve(api.loadModel, "llama_model_load_from_file", modules) &&
        resolve(api.freeModel, "llama_model_free", modules) &&
        resolve(api.initContext, "llama_init_from_model", modules) &&
        resolve(api.freeContext, "llama_free", modules) &&
        resolve(api.vocab, "llama_model_get_vocab", modules) &&
        resolve(api.chatTemplate, "llama_model_chat_template", modules) &&
        resolve(api.applyTemplate, "llama_chat_apply_template", modules) &&
        resolve(api.tokenize, "llama_tokenize", modules) &&
        resolve(api.tokenToPiece, "llama_token_to_piece", modules) &&
        resolve(api.isEndOfGeneration, "llama_vocab_is_eog", modules) &&
        resolve(api.batchOne, "llama_batch_get_one", modules) &&
        resolve(api.decode, "llama_decode", modules) &&
        resolve(api.contextSize, "llama_n_ctx", modules) &&
        resolve(api.chainInit, "llama_sampler_chain_init", modules) &&
        resolve(api.chainAdd, "llama_sampler_chain_add", modules) &&
        resolve(api.greedy, "llama_sampler_init_greedy", modules) &&
        resolve(api.topK, "llama_sampler_init_top_k", modules) &&
        resolve(api.topP, "llama_sampler_init_top_p", modules) &&
        resolve(api.minP, "llama_sampler_init_min_p", modules) &&
        resolve(api.temperature, "llama_sampler_init_temp", modules) &&
        resolve(api.distribution, "llama_sampler_init_dist", modules) &&
        resolve(api.sample, "llama_sampler_sample", modules) &&
        resolve(api.freeSampler, "llama_sampler_free", modules);
    const char *version = complete ? api.ggmlVersion() : nullptr;
    if (!complete || !version || std::strcmp(version, expectedGgmlVersion) != 0) {
        SetThreadErrorMode(previousMode, nullptr);
        const std::string found = version ? std::string("ggml ") + version : "an incomplete API";
        delete runtime; // The library stays mapped: unloading ggml after partial use is unsafe.
        jsti::fail("The on-device language model runtime uses " + found + "; this app needs ggml " +
                   expectedGgmlVersion + ". Reinstall the app.", error, capacity);
        return nullptr;
    }
    api.logSet(logCallback, nullptr);
    jsti::loadGgmlBackendsOnce(api.loadBackends, jsti::utf8(folder));
    try { api.backendInit(); } catch (...) {}
    SetThreadErrorMode(previousMode, nullptr);
    describe(*runtime);
    if (runtime->description.find("; CPU") == std::string::npos) {
        delete runtime;
        jsti::fail("The on-device language model runtime found no usable CPU backend. " + lastLog(), error,
                   capacity);
        return nullptr;
    }
    sharedRuntime = runtime;
    return runtime;
}

extern "C" int jsti_llama_runtime_describe(JSTILlamaRuntime *runtime, char *text, size_t capacity) {
    if (!runtime || !text || !capacity) return -1;
    jsti::fail(runtime->description, text, capacity);
    return 0;
}

extern "C" void jsti_llama_runtime_release_model(JSTILlamaRuntime *runtime) {
    if (!runtime) return;
    std::lock_guard<std::mutex> lock(runtime->mutex);
    releaseModel(*runtime);
}

extern "C" int jsti_llama_runtime_release_model_at(JSTILlamaRuntime *runtime, const char *modelPath) {
    std::wstring path;
    if (!runtime || !modelPath || !jsti::wide(modelPath, path) || path.empty()) return -1;
    normalisePath(path);
    std::lock_guard<std::mutex> lock(runtime->mutex);
    if (!runtime->model || _wcsicmp(runtime->modelPath.c_str(), path.c_str()) != 0) return 0;
    releaseModel(*runtime);
    return 1;
}

extern "C" int jsti_llama_generate(JSTILlamaRuntime *runtime, const char *modelPath, const char *systemPrompt,
                                   const char *userMessage, double temperature, int maximumTokens, int threads,
                                   JSTIWhisperJob *job, char **text, char *error, size_t capacity) {
    if (!runtime || !modelPath || !systemPrompt || !userMessage || !job || !text || maximumTokens <= 0 ||
        maximumTokens > 32768 || !(temperature >= 0 && temperature <= 2)) {
        jsti::fail("Invalid on-device language model request.", error, capacity);
        return JSTI_WHISPER_FAILED;
    }
    *text = nullptr;
    std::wstring path;
    if (!jsti::wide(modelPath, path) || path.empty()) {
        jsti::fail("The model path is not valid UTF-8.", error, capacity);
        return JSTI_WHISPER_FAILED;
    }
    normalisePath(path);
    std::lock_guard<std::mutex> lock(runtime->mutex);
    if (job->cancelled.load()) return JSTI_WHISPER_CANCELLED;
    LlamaApi &api = runtime->api;
    llama_context *context = nullptr;
    llama_sampler *sampler = nullptr;
    auto cleanup = [&] {
        if (sampler) api.freeSampler(sampler);
        if (context) api.freeContext(context);
        sampler = nullptr;
        context = nullptr;
    };
    try {
        if (!runtime->model || _wcsicmp(runtime->modelPath.c_str(), path.c_str()) != 0) {
            releaseModel(*runtime);
            llama_model_params parameters = api.modelDefaults();
            parameters.n_gpu_layers = runtime->hasGPU ? -1 : 0;
            // Read into memory rather than mapped, so the file is closed once
            // loaded and Remove can delete it like a Whisper model.
            parameters.load_mode = LLAMA_LOAD_MODE_NONE;
            // ggml opens the UTF-8 path through a wide-character call.
            const std::string utf8Path = jsti::utf8(path);
            runtime->model = api.loadModel(utf8Path.c_str(), parameters);
            if (!runtime->model) {
                const std::string detail = lastLog();
                jsti::fail("The language model could not be loaded" +
                           (detail.empty() ? std::string(".") : ": " + detail), error, capacity);
                return JSTI_WHISPER_FAILED;
            }
            runtime->modelPath = path;
        }
        if (job->cancelled.load()) return JSTI_WHISPER_CANCELLED;
        std::string prompt;
        if (!formatPrompt(*runtime, systemPrompt, userMessage, prompt)) {
            jsti::fail("The language model's chat template could not be applied.", error, capacity);
            return JSTI_WHISPER_FAILED;
        }
        const llama_vocab *vocab = api.vocab(runtime->model);
        const int32_t needed = -api.tokenize(vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()), nullptr, 0,
                                             true, true);
        if (needed <= 0) {
            jsti::fail("The prompt could not be tokenised.", error, capacity);
            return JSTI_WHISPER_FAILED;
        }
        std::vector<llama_token> tokens(static_cast<size_t>(needed));
        if (api.tokenize(vocab, prompt.c_str(), static_cast<int32_t>(prompt.size()), tokens.data(), needed, true,
                         true) < 0) {
            jsti::fail("The prompt could not be tokenised.", error, capacity);
            return JSTI_WHISPER_FAILED;
        }
        llama_context_params parameters = api.contextDefaults();
        const uint32_t window = static_cast<uint32_t>(tokens.size()) + static_cast<uint32_t>(maximumTokens) + 16;
        parameters.n_ctx = std::min<uint32_t>(32768, window);
        parameters.n_batch = std::min<uint32_t>(parameters.n_ctx, 2048);
        parameters.n_ubatch = std::min<uint32_t>(parameters.n_batch, 512);
        const unsigned hardware = std::max(1u, std::thread::hardware_concurrency());
        parameters.n_threads = threads > 0 ? threads : static_cast<int32_t>(std::min(8u, hardware));
        parameters.n_threads_batch = parameters.n_threads;
        parameters.abort_callback = abortRequested;
        parameters.abort_callback_data = job;
        parameters.no_perf = true;
        context = api.initContext(runtime->model, parameters);
        if (!context) {
            jsti::fail("The language model context could not be created: " + lastLog(), error, capacity);
            return JSTI_WHISPER_FAILED;
        }
        if (tokens.size() + 8 > api.contextSize(context)) {
            cleanup();
            jsti::fail("The transcript is too long for this language model.", error, capacity);
            return JSTI_WHISPER_FAILED;
        }
        for (size_t offset = 0; offset < tokens.size(); offset += parameters.n_batch) {
            const int32_t count = static_cast<int32_t>(std::min<size_t>(parameters.n_batch, tokens.size() - offset));
            const int32_t status = api.decode(context, api.batchOne(tokens.data() + offset, count));
            if (job->cancelled.load()) { cleanup(); return JSTI_WHISPER_CANCELLED; }
            if (status != 0) {
                cleanup();
                jsti::fail("The language model could not read the prompt (status " + std::to_string(status) + ").",
                           error, capacity);
                return JSTI_WHISPER_FAILED;
            }
        }
        sampler = api.chainInit(api.chainDefaults());
        if (temperature <= 0) {
            api.chainAdd(sampler, api.greedy());
        } else {
            // llama-cpp-python's defaults, which the Mac's local runtime uses.
            api.chainAdd(sampler, api.topK(40));
            api.chainAdd(sampler, api.topP(0.95f, 1));
            api.chainAdd(sampler, api.minP(0.05f, 1));
            api.chainAdd(sampler, api.temperature(static_cast<float>(temperature)));
            api.chainAdd(sampler, api.distribution(0x5EED));
        }
        std::string result;
        for (int generated = 0; generated < maximumTokens; ++generated) {
            if (job->cancelled.load()) { cleanup(); return JSTI_WHISPER_CANCELLED; }
            llama_token token = api.sample(sampler, context, -1);
            if (api.isEndOfGeneration(vocab, token)) break;
            char piece[256];
            const int32_t length = api.tokenToPiece(vocab, token, piece, sizeof(piece), 0, false);
            if (length > 0) result.append(piece, static_cast<size_t>(length));
            if (tokens.size() + static_cast<size_t>(generated) + 2 >= api.contextSize(context)) break;
            const int32_t status = api.decode(context, api.batchOne(&token, 1));
            if (job->cancelled.load()) { cleanup(); return JSTI_WHISPER_CANCELLED; }
            if (status != 0) {
                cleanup();
                jsti::fail("On-device generation failed (status " + std::to_string(status) + ").", error, capacity);
                return JSTI_WHISPER_FAILED;
            }
        }
        cleanup();
        char *copy = static_cast<char *>(std::malloc(result.size() + 1));
        if (!copy) {
            jsti::fail("Could not allocate the reply.", error, capacity);
            return JSTI_WHISPER_FAILED;
        }
        std::memcpy(copy, result.c_str(), result.size() + 1);
        *text = copy;
        return JSTI_WHISPER_OK;
    } catch (const std::exception &exception) {
        cleanup();
        releaseModel(*runtime);
        jsti::fail(std::string("On-device generation failed: ") + exception.what(), error, capacity);
    } catch (...) {
        cleanup();
        releaseModel(*runtime);
        jsti::fail("On-device generation failed in the language model runtime.", error, capacity);
    }
    return JSTI_WHISPER_FAILED;
}
