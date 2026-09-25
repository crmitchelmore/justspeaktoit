#include "include/CWindowsSupport.h"
#include "WindowsSupportInternal.hpp"
#include "whisper-cpp/whisper.h"
#include <atomic>
#include <cctype>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <mutex>
#include <new>
#include <thread>
#include <vector>

// whisper.cpp is loaded at run time, never linked. The declarations above come
// from headers vendored at the pinned commit (see whisper-cpp/PROVENANCE.md);
// the struct layouts they describe are only valid for that exact release, so
// open() refuses any other whisper_version().
namespace {
constexpr const char *expectedVersion = "1.9.4";

struct Api {
    decltype(&whisper_version) version = nullptr;
    decltype(&whisper_context_default_params) contextDefaults = nullptr;
    decltype(&whisper_init_with_params) initWithParams = nullptr;
    decltype(&whisper_full_default_params) fullDefaults = nullptr;
    decltype(&whisper_full) full = nullptr;
    decltype(&whisper_full_n_segments) segmentCount = nullptr;
    decltype(&whisper_full_get_segment_text) segmentText = nullptr;
    decltype(&whisper_free) free = nullptr;
    decltype(&whisper_lang_id) languageID = nullptr;
    decltype(&whisper_log_set) logSet = nullptr;
    decltype(&ggml_backend_load_all_from_path) loadBackends = nullptr;
    decltype(&ggml_backend_dev_count) deviceCount = nullptr;
    decltype(&ggml_backend_dev_get) device = nullptr;
    decltype(&ggml_backend_dev_type) deviceType = nullptr;
    decltype(&ggml_backend_dev_name) deviceName = nullptr;
    decltype(&ggml_backend_dev_description) deviceDescription = nullptr;
};

// Recent runtime log lines explain a failed model load without exposing
// transcript text: whisper.cpp logs no audio or decoded text at these levels.
struct LogRing {
    std::mutex mutex;
    std::deque<std::string> lines;
    std::string partial;
    void append(const char *text) {
        if (!text) return;
        std::lock_guard<std::mutex> lock(mutex);
        partial += text;
        size_t newline;
        while ((newline = partial.find('\n')) != std::string::npos) {
            if (newline) lines.push_back(partial.substr(0, newline));
            partial.erase(0, newline + 1);
            while (lines.size() > 8) lines.pop_front();
        }
    }
    std::string last() {
        std::lock_guard<std::mutex> lock(mutex);
        for (auto line = lines.rbegin(); line != lines.rend(); ++line) {
            if (line->find("error") != std::string::npos || line->find("failed") != std::string::npos) return *line;
        }
        return lines.empty() ? std::string() : lines.back();
    }
};
LogRing logRing;

void logCallback(enum ggml_log_level level, const char *text, void *) {
    if (level == GGML_LOG_LEVEL_ERROR || level == GGML_LOG_LEVEL_WARN || level == GGML_LOG_LEVEL_INFO) logRing.append(text);
}
}

struct JSTIWhisperRuntime {
    std::wstring directory;
    HMODULE whisper = nullptr;
    Api api;
    bool allowGPU = false;
    bool hasGPU = false;
    std::string description;
    std::mutex mutex; // Serialises model use; whisper_full is not reentrant per context.
    whisper_context *context = nullptr;
    std::wstring contextPath;
    std::string contextSHA256; // Lowercase SHA-256 of the bytes context was loaded from.
};

struct JSTIWhisperJob {
    std::atomic<bool> cancelled{false};
};

namespace {
std::mutex openMutex;
JSTIWhisperRuntime *sharedRuntime = nullptr;

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

bool fileExists(const std::wstring &path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

// Hands whisper.cpp the model file's bytes through one open file and hashes
// each byte as it is handed over, so the digest describes exactly the bytes
// the runtime loaded, whatever happens to the file on disk meanwhile.
struct FileLoader {
    FILE *file = nullptr;
    JSTISHA256 *hasher = nullptr;
    bool failed = false;

    ~FileLoader() {
        if (hasher) jsti_sha256_destroy(hasher);
        if (file) std::fclose(file);
    }

    void hash(const void *bytes, size_t count) {
        char ignored[8];
        if (count && jsti_sha256_update(hasher, bytes, count, ignored, sizeof ignored) != 0) failed = true;
    }
    static size_t read(void *context, void *output, size_t size) {
        auto *loader = static_cast<FileLoader *>(context);
        const size_t count = std::fread(output, 1, size, loader->file);
        loader->hash(output, count);
        return count;
    }
    static bool eof(void *context) { return std::feof(static_cast<FileLoader *>(context)->file) != 0; }
    // whisper.cpp closes its loader when it finishes; the file stays open so
    // any bytes it did not read are hashed too.
    static void close(void *) {}

    // Hashes what the runtime left unread, then compares the whole file's
    // digest with expected. Only a match returns true.
    bool matches(const char *expected) {
        std::vector<unsigned char> buffer(1 << 16);
        size_t count;
        while ((count = std::fread(buffer.data(), 1, buffer.size(), file)) > 0) hash(buffer.data(), count);
        char digest[65] = {};
        char ignored[8];
        if (std::ferror(file) || failed || jsti_sha256_finish(hasher, digest, sizeof digest, ignored, sizeof ignored)) {
            return false;
        }
        return _stricmp(digest, expected) == 0;
    }
};

bool isSHA256Hex(const char *text) {
    if (!text || std::strlen(text) != 64) return false;
    for (const char *cursor = text; *cursor; ++cursor) {
        if (!std::isxdigit(static_cast<unsigned char>(*cursor))) return false;
    }
    return true;
}

std::string lowercase(const char *text) {
    std::string result(text);
    for (char &character : result) character = static_cast<char>(std::tolower(static_cast<unsigned char>(character)));
    return result;
}

bool abortRequested(void *data) {
    return static_cast<JSTIWhisperJob *>(data)->cancelled.load(std::memory_order_relaxed);
}

void describeDevices(JSTIWhisperRuntime &runtime) {
    std::string gpus, others;
    bool gpu = false;
    const size_t count = runtime.api.deviceCount();
    for (size_t index = 0; index < count; ++index) {
        ggml_backend_dev_t device = runtime.api.device(index);
        if (!device) continue;
        const char *name = runtime.api.deviceName(device);
        const char *description = runtime.api.deviceDescription(device);
        std::string label = std::string(name ? name : "device") +
            (description && *description ? std::string(" (") + description + ")" : std::string());
        const enum ggml_backend_dev_type type = runtime.api.deviceType(device);
        if (type == GGML_BACKEND_DEVICE_TYPE_GPU || type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
            gpu = true;
            gpus += (gpus.empty() ? "" : ", ") + label;
        } else if (type == GGML_BACKEND_DEVICE_TYPE_CPU) {
            others += (others.empty() ? "" : ", ") + std::string("CPU");
        }
    }
    runtime.hasGPU = gpu && runtime.allowGPU;
    runtime.description = std::string("whisper.cpp ") + expectedVersion;
    if (!gpus.empty()) runtime.description += std::string(runtime.allowGPU ? "; GPU: " : "; GPU off: ") + gpus;
    runtime.description += "; " + (others.empty() ? std::string("no CPU backend") : others);
}

// Foundation may spell a Windows path "/C:/dir"; the loader needs "C:\\dir".
void normalisePath(std::wstring &path) {
    std::replace(path.begin(), path.end(), L'/', L'\\');
    if (path.size() > 3 && path[0] == L'\\' && path[2] == L':') path.erase(0, 1);
}

void releaseContext(JSTIWhisperRuntime &runtime) {
    if (runtime.context) runtime.api.free(runtime.context);
    runtime.context = nullptr;
    runtime.contextPath.clear();
    runtime.contextSHA256.clear();
}
}

extern "C" JSTIWhisperRuntime *jsti_whisper_runtime_open(const char *directory, int allowGPU, char *error,
                                                         size_t capacity) {
    std::wstring folder;
    if (directory && jsti::wide(directory, folder)) normalisePath(folder);
    if (!directory || folder.size() < 3 || folder.size() > 32000 ||
        !(folder[1] == L':' || (folder[0] == L'\\' && folder[1] == L'\\'))) {
        jsti::fail("The speech runtime directory must be an absolute path.", error, capacity);
        return nullptr;
    }
    while (folder.size() > 3 && folder.back() == L'\\') folder.pop_back();
    std::lock_guard<std::mutex> lock(openMutex);
    if (sharedRuntime) {
        if (_wcsicmp(sharedRuntime->directory.c_str(), folder.c_str()) != 0) {
            jsti::fail("The speech runtime is already loaded from another directory.", error, capacity);
            return nullptr;
        }
        return sharedRuntime;
    }
    const std::wstring library = folder + L"\\whisper.dll";
    if (!fileExists(library)) {
        jsti::fail("The on-device speech runtime (whisper.dll) is not installed beside the app.", error, capacity);
        return nullptr;
    }
    // Implicit layers (overlays, capture tools) have crashed Vulkan inference in
    // other dictation apps. Respect an explicit user choice.
    if (allowGPU && GetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", nullptr, 0) == 0) {
        SetEnvironmentVariableW(L"VK_LOADER_LAYERS_DISABLE", L"~implicit~");
    }
    DWORD previousMode = 0;
    SetThreadErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX, &previousMode);
    // Dependencies (ggml, ggml-base, the Visual C++ runtime) resolve from the
    // runtime directory or System32 only, never the current directory or PATH.
    HMODULE whisper = LoadLibraryExW(library.c_str(), nullptr,
                                     LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
    const DWORD loadError = GetLastError();
    if (!whisper) {
        SetThreadErrorMode(previousMode, nullptr);
        jsti::fail(jsti::systemError("Loading the on-device speech runtime", loadError), error, capacity);
        return nullptr;
    }
    auto *runtime = new (std::nothrow) JSTIWhisperRuntime();
    if (!runtime) {
        SetThreadErrorMode(previousMode, nullptr);
        jsti::fail("Could not allocate the speech runtime.", error, capacity);
        return nullptr;
    }
    runtime->directory = folder;
    runtime->whisper = whisper;
    runtime->allowGPU = allowGPU != 0;
    const std::vector<HMODULE> modules = {whisper, GetModuleHandleW(L"ggml.dll"), GetModuleHandleW(L"ggml-base.dll")};
    Api &api = runtime->api;
    const bool complete = resolve(api.version, "whisper_version", modules) &&
        resolve(api.contextDefaults, "whisper_context_default_params", modules) &&
        resolve(api.initWithParams, "whisper_init_with_params", modules) &&
        resolve(api.fullDefaults, "whisper_full_default_params", modules) &&
        resolve(api.full, "whisper_full", modules) &&
        resolve(api.segmentCount, "whisper_full_n_segments", modules) &&
        resolve(api.segmentText, "whisper_full_get_segment_text", modules) &&
        resolve(api.free, "whisper_free", modules) &&
        resolve(api.languageID, "whisper_lang_id", modules) &&
        resolve(api.logSet, "whisper_log_set", modules) &&
        resolve(api.loadBackends, "ggml_backend_load_all_from_path", modules) &&
        resolve(api.deviceCount, "ggml_backend_dev_count", modules) &&
        resolve(api.device, "ggml_backend_dev_get", modules) &&
        resolve(api.deviceType, "ggml_backend_dev_type", modules) &&
        resolve(api.deviceName, "ggml_backend_dev_name", modules) &&
        resolve(api.deviceDescription, "ggml_backend_dev_description", modules);
    const char *version = complete ? api.version() : nullptr;
    if (!complete || !version || std::strcmp(version, expectedVersion) != 0) {
        SetThreadErrorMode(previousMode, nullptr);
        // The library stays mapped: unloading ggml after partial use is unsafe.
        const std::string found = version ? version : "an incomplete API";
        delete runtime;
        jsti::fail("The on-device speech runtime is whisper.cpp " + found + "; this app needs " + expectedVersion +
                   ". Reinstall the app.", error, capacity);
        return nullptr;
    }
    api.logSet(logCallback, nullptr);
    // ggml's loader also loads whatever GGML_BACKEND_PATH names, so an inherited
    // variable could put another DLL into the app. Removing it from the shared
    // UCRT environment keeps registration to this directory.
    _putenv_s("GGML_BACKEND_PATH", "");
    // Registers the best CPU variant and, when its loader and a driver exist,
    // Vulkan, from this directory only.
    const std::string backendDirectory = jsti::utf8(folder);
    try { api.loadBackends(backendDirectory.c_str()); } catch (...) {}
    SetThreadErrorMode(previousMode, nullptr);
    describeDevices(*runtime);
    if (runtime->description.find("CPU") == std::string::npos) {
        delete runtime;
        jsti::fail("The on-device speech runtime found no usable CPU backend. " + logRing.last(), error, capacity);
        return nullptr;
    }
    sharedRuntime = runtime;
    return runtime;
}

extern "C" int jsti_whisper_runtime_describe(JSTIWhisperRuntime *runtime, char *text, size_t capacity) {
    if (!runtime || !text || !capacity) return -1;
    jsti::fail(runtime->description, text, capacity);
    return 0;
}

extern "C" int jsti_whisper_runtime_uses_gpu(JSTIWhisperRuntime *runtime) {
    return runtime && runtime->hasGPU ? 1 : 0;
}

extern "C" JSTIWhisperJob *jsti_whisper_job_create(void) { return new (std::nothrow) JSTIWhisperJob(); }

extern "C" void jsti_whisper_job_cancel(JSTIWhisperJob *job) {
    if (job) job->cancelled.store(true, std::memory_order_relaxed);
}

extern "C" void jsti_whisper_job_destroy(JSTIWhisperJob *job) { delete job; }

extern "C" void jsti_whisper_free_text(char *text) { std::free(text); }

extern "C" void jsti_whisper_runtime_release_model(JSTIWhisperRuntime *runtime) {
    if (!runtime) return;
    std::lock_guard<std::mutex> lock(runtime->mutex);
    releaseContext(*runtime);
}

// Checked under the lock transcribe loads under, with its path comparison, so
// a model that replaced this one in the cache is never freed in its place.
extern "C" int jsti_whisper_runtime_release_model_at(JSTIWhisperRuntime *runtime, const char *modelPath) {
    std::wstring path;
    if (!runtime || !modelPath || !jsti::wide(modelPath, path) || path.empty()) return -1;
    normalisePath(path);
    std::lock_guard<std::mutex> lock(runtime->mutex);
    if (!runtime->context || _wcsicmp(runtime->contextPath.c_str(), path.c_str()) != 0) return 0;
    releaseContext(*runtime);
    return 1;
}

extern "C" int jsti_whisper_transcribe(JSTIWhisperRuntime *runtime, const char *modelPath, const char *modelSHA256,
                                       const float *samples, size_t sampleCount, const char *language, int threads,
                                       JSTIWhisperJob *job, char **text, char *error, size_t capacity) {
    if (!runtime || !modelPath || !isSHA256Hex(modelSHA256) || !job || !text || (sampleCount && !samples) ||
        sampleCount > static_cast<size_t>((std::numeric_limits<int>::max)())) {
        jsti::fail("Invalid on-device transcription request.", error, capacity);
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
    try {
        // Loads unless the cache already holds this path's bytes with this
        // digest. A model whose bytes do not match is freed, never cached or used.
        const std::string sha256 = lowercase(modelSHA256);
        if (!runtime->context || _wcsicmp(runtime->contextPath.c_str(), path.c_str()) != 0 ||
            runtime->contextSHA256 != sha256) {
            releaseContext(*runtime);
            FileLoader file;
            if (_wfopen_s(&file.file, path.c_str(), L"rb") != 0 || !file.file) {
                file.file = nullptr;
                jsti::fail("The downloaded model file could not be opened.", error, capacity);
                return JSTI_WHISPER_FAILED;
            }
            file.hasher = jsti_sha256_create(error, capacity);
            if (!file.hasher) return JSTI_WHISPER_FAILED;
            whisper_model_loader loader{};
            loader.context = &file;
            loader.read = FileLoader::read;
            loader.eof = FileLoader::eof;
            loader.close = FileLoader::close;
            whisper_context_params parameters = runtime->api.contextDefaults();
            parameters.use_gpu = runtime->hasGPU;
            parameters.gpu_device = 0;
            whisper_context *context = runtime->api.initWithParams(&loader, parameters);
            if (!file.matches(sha256.c_str())) {
                if (context) runtime->api.free(context);
                jsti::fail("The downloaded model file does not match its pinned SHA-256.", error, capacity);
                return JSTI_WHISPER_MODEL_MISMATCH;
            }
            if (!context) {
                const std::string detail = logRing.last();
                jsti::fail("The model could not be loaded" + (detail.empty() ? std::string(".") : ": " + detail),
                           error, capacity);
                return JSTI_WHISPER_FAILED;
            }
            runtime->context = context;
            runtime->contextPath = path;
            runtime->contextSHA256 = sha256;
        }
        if (job->cancelled.load()) return JSTI_WHISPER_CANCELLED;
        whisper_full_params parameters = runtime->api.fullDefaults(WHISPER_SAMPLING_GREEDY);
        const unsigned hardware = std::max(1u, std::thread::hardware_concurrency());
        parameters.n_threads = threads > 0 ? threads : static_cast<int>(std::min(8u, hardware));
        parameters.translate = false;
        parameters.no_timestamps = true;
        parameters.single_segment = false;
        parameters.print_special = false;
        parameters.print_progress = false;
        parameters.print_realtime = false;
        parameters.print_timestamps = false;
        parameters.suppress_blank = true;
        parameters.suppress_nst = true;
        const bool knownLanguage = language && *language && runtime->api.languageID(language) >= 0;
        parameters.language = knownLanguage ? language : "auto";
        parameters.detect_language = false;
        parameters.abort_callback = abortRequested;
        parameters.abort_callback_user_data = job;
        parameters.encoder_begin_callback = [](whisper_context *, whisper_state *, void *data) {
            return !abortRequested(data);
        };
        parameters.encoder_begin_callback_user_data = job;
        const int status = runtime->api.full(runtime->context, parameters, samples, static_cast<int>(sampleCount));
        if (job->cancelled.load()) return JSTI_WHISPER_CANCELLED;
        if (status != 0) {
            jsti::fail("On-device transcription failed (whisper.cpp status " + std::to_string(status) + ").", error,
                       capacity);
            return JSTI_WHISPER_FAILED;
        }
        std::string result;
        const int segments = runtime->api.segmentCount(runtime->context);
        for (int index = 0; index < segments; ++index) {
            if (const char *segment = runtime->api.segmentText(runtime->context, index)) result += segment;
        }
        char *copy = static_cast<char *>(std::malloc(result.size() + 1));
        if (!copy) {
            jsti::fail("Could not allocate the transcript.", error, capacity);
            return JSTI_WHISPER_FAILED;
        }
        std::memcpy(copy, result.c_str(), result.size() + 1);
        *text = copy;
        return JSTI_WHISPER_OK;
    } catch (const std::exception &exception) {
        releaseContext(*runtime);
        jsti::fail(std::string("On-device transcription failed: ") + exception.what(), error, capacity);
    } catch (...) {
        releaseContext(*runtime);
        jsti::fail("On-device transcription failed in the speech runtime.", error, capacity);
    }
    return JSTI_WHISPER_FAILED;
}
