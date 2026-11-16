// JNI bridge between LlamaNative (LlamaCppCleaner.kt) and llama.cpp, for downloaded cleanup models. A
// session owns one llama_model; Kotlin opens it, runs one cleanup, then frees it. nativeAbort may run on
// another thread while nativeComplete is running; nativeFree runs only after nativeComplete has
// returned. The generation loop follows the desktop adapter (Sources/CLlamaCpp/LlamaCpp.cpp): the
// model's own chat template with SYSTEM and USER roles, Qwen3's non-thinking prefill, greedy sampling,
// bounded prompt and output, and no partial output when the budget runs out.
#include <android/log.h>
#include <jni.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "llama.h"

namespace {

constexpr const char *kTag = "JstiLlama";

constexpr uint32_t kContextTokens = 4096;
constexpr uint32_t kBatchTokens = 256;
constexpr int32_t kMaxTemplateBytes = 512 * 1024;
constexpr size_t kMaxOutputBytes = 256 * 1024;
constexpr int32_t kMaxPieceBytes = 64 * 1024;
// The Kotlin caller passes its own bound; this only keeps the deadline arithmetic in range.
constexpr jlong kMaxTimeoutMs = 10 * 60 * 1000;

// Kept in step with LocalCleanupFailure in LlamaCppCleaner.kt.
enum Failure : jint {
    kNone = 0,
    kAborted = 1,
    kNoChatTemplate = 2,
    kTooLong = 3,
    kDecode = 4,
    kNoEndOfTurn = 5,
    kInvalidOutput = 6,
    kContext = 7,
    kTimedOut = 8,
};

struct Session {
    llama_model *model = nullptr;
    std::atomic<bool> abort{false};
    std::atomic<jint> lastError{kNone};
    std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::time_point::max();
    std::atomic<bool> timedOut{false};

    // Called by ggml (possibly from its worker threads) and by the loops below. The deadline is set
    // before generation starts and not changed while it runs.
    bool stopped() {
        if (abort.load(std::memory_order_relaxed)) return true;
        if (std::chrono::steady_clock::now() >= deadline) {
            timedOut.store(true);
            return true;
        }
        return false;
    }
};

Session *fromHandle(jlong handle) { return reinterpret_cast<Session *>(handle); }

void logToAndroid(ggml_log_level level, const char *text, void *) {
    if (level == GGML_LOG_LEVEL_ERROR) {
        __android_log_write(ANDROID_LOG_ERROR, kTag, text);
    } else if (level == GGML_LOG_LEVEL_WARN) {
        __android_log_write(ANDROID_LOG_WARN, kTag, text);
    }
}

bool abortRun(void *userData) { return static_cast<Session *>(userData)->stopped(); }

bool loadProgress(float, void *) { return true; }

std::string utf8(JNIEnv *env, jstring value) {
    if (value == nullptr) return {};
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (chars == nullptr) return {};
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

// The caller's UTF-8 bytes, rejecting embedded NULs (the C API takes NUL-terminated strings).
bool bytes(JNIEnv *env, jbyteArray value, std::string &out) {
    if (value == nullptr) return false;
    const jsize count = env->GetArrayLength(value);
    out.resize(static_cast<size_t>(count));
    if (count > 0) env->GetByteArrayRegion(value, 0, count, reinterpret_cast<jbyte *>(out.data()));
    return out.find('\0') == std::string::npos;
}

struct ContextDeleter {
    void operator()(llama_context *value) const { llama_free(value); }
};
struct SamplerDeleter {
    void operator()(llama_sampler *value) const { llama_sampler_free(value); }
};

jint failed(Session *session, jint code) {
    if (session->timedOut.load()) code = kTimedOut;
    else if (session->abort.load()) code = kAborted;
    session->lastError.store(code);
    return code;
}

// Returns kNone with the reply in `output`, or a Failure.
jint complete(Session *session, const std::string &system, const std::string &user, int32_t maxTokens,
              int32_t threads, std::string &output) {
    llama_model *model = session->model;
    const llama_vocab *vocab = llama_model_get_vocab(model);
    if (vocab == nullptr) return kContext;

    const char *tmpl = llama_model_chat_template(model, nullptr);
    if (tmpl == nullptr) return kNoChatTemplate;
    const llama_chat_message messages[] = {{"system", system.c_str()}, {"user", user.c_str()}};
    const int32_t required = llama_chat_apply_template(tmpl, messages, 2, true, nullptr, 0);
    if (required <= 0 || required > kMaxTemplateBytes) return kNoChatTemplate;
    std::vector<char> rendered(static_cast<size_t>(required) + 1);
    if (llama_chat_apply_template(tmpl, messages, 2, true, rendered.data(),
                                  static_cast<int32_t>(rendered.size())) != required) {
        return kNoChatTemplate;
    }
    std::string prompt(rendered.data(), static_cast<size_t>(required));
    char architecture[64]{};
    if (llama_model_meta_val_str(model, "general.architecture", architecture, sizeof(architecture)) > 0 &&
        std::string(architecture) == "qwen3") {
        // Qwen3's documented non-thinking assistant prefill; neither input role is rewritten.
        prompt += "<think>\n\n</think>\n\n";
    }

    const int32_t wanted =
        llama_tokenize(vocab, prompt.data(), static_cast<int32_t>(prompt.size()), nullptr, 0, true, true);
    if (wanted >= 0 || wanted <= -static_cast<int32_t>(kContextTokens)) return kTooLong;
    std::vector<llama_token> tokens(static_cast<size_t>(-wanted));
    if (llama_tokenize(vocab, prompt.data(), static_cast<int32_t>(prompt.size()), tokens.data(),
                       static_cast<int32_t>(tokens.size()), true, true) != -wanted) {
        return kTooLong;
    }

    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = kContextTokens;
    cp.n_batch = kBatchTokens;
    cp.n_ubatch = kBatchTokens;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    cp.offload_kqv = false;
    cp.op_offload = false;
    cp.no_perf = true;
    cp.abort_callback = abortRun;
    cp.abort_callback_data = session;
    std::unique_ptr<llama_context, ContextDeleter> context(llama_init_from_model(model, cp));
    if (!context) return kContext;
    const size_t available = llama_n_ctx(context.get());
    if (tokens.size() >= available) return kTooLong;

    std::unique_ptr<llama_sampler, SamplerDeleter> sampler(
        llama_sampler_chain_init(llama_sampler_chain_default_params()));
    llama_sampler *greedy = sampler ? llama_sampler_init_greedy() : nullptr;
    if (greedy == nullptr) return kContext;
    llama_sampler_chain_add(sampler.get(), greedy);

    for (size_t offset = 0; offset < tokens.size(); offset += kBatchTokens) {
        if (session->stopped()) return kAborted;
        const auto count = static_cast<int32_t>(std::min<size_t>(kBatchTokens, tokens.size() - offset));
        if (llama_decode(context.get(), llama_batch_get_one(tokens.data() + offset, count)) != 0) return kDecode;
    }

    const size_t budget = std::min(static_cast<size_t>(std::max(maxTokens, 1)), available - tokens.size());
    std::vector<char> piece(256);
    for (size_t generated = 0; generated < budget; ++generated) {
        if (session->stopped()) return kAborted;
        llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
        if (llama_vocab_is_eog(vocab, token)) return kNone;
        int32_t count = llama_token_to_piece(vocab, token, piece.data(), static_cast<int32_t>(piece.size()), 0, false);
        if (count < 0 && count > -kMaxPieceBytes) {
            piece.resize(static_cast<size_t>(-count));
            count = llama_token_to_piece(vocab, token, piece.data(), static_cast<int32_t>(piece.size()), 0, false);
        }
        if (count < 0 || static_cast<size_t>(count) > piece.size()) return kInvalidOutput;
        if (std::memchr(piece.data(), 0, static_cast<size_t>(count)) != nullptr) return kInvalidOutput;
        output.append(piece.data(), static_cast<size_t>(count));
        if (output.size() > kMaxOutputBytes) return kNoEndOfTurn;
        if (llama_decode(context.get(), llama_batch_get_one(&token, 1)) != 0) return kDecode;
    }
    return kNoEndOfTurn;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_justspeaktoit_android_local_LlamaNative_nativeOpen(JNIEnv *env, jclass, jstring path) {
    llama_log_set(logToAndroid, nullptr);
    llama_backend_init();
    const std::string modelPath = utf8(env, path);
    if (modelPath.empty()) return 0;
    llama_model_params params = llama_model_default_params();
    params.n_gpu_layers = 0;
    params.load_mode = LLAMA_LOAD_MODE_MMAP;
    params.check_tensors = true;
    params.progress_callback = loadProgress;
    llama_model *model = llama_model_load_from_file(modelPath.c_str(), params);
    if (model == nullptr) return 0;
    if (llama_model_has_encoder(model) || !llama_model_has_decoder(model) ||
        llama_model_get_vocab(model) == nullptr) {
        llama_model_free(model);
        return 0;
    }
    auto *session = new Session();
    session->model = model;
    return reinterpret_cast<jlong>(session);
}

JNIEXPORT jbyteArray JNICALL
Java_com_justspeaktoit_android_local_LlamaNative_nativeComplete(
    JNIEnv *env, jclass, jlong handle, jbyteArray systemBytes, jbyteArray userBytes, jint maxTokens,
    jlong timeoutMs, jint threads) {
    Session *session = fromHandle(handle);
    if (session == nullptr) return nullptr;
    session->lastError.store(kNone);
    session->timedOut.store(false);
    std::string system;
    std::string user;
    if (!bytes(env, systemBytes, system) || !bytes(env, userBytes, user) || user.empty()) {
        failed(session, kInvalidOutput);
        return nullptr;
    }
    session->deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(std::clamp<jlong>(timeoutMs, 1, kMaxTimeoutMs));

    std::string output;
    const jint status = complete(session, system, user, maxTokens, threads > 0 ? threads : 1, output);
    if (status != kNone || session->stopped()) {
        failed(session, status == kNone ? kAborted : status);
        return nullptr;
    }
    jbyteArray result = env->NewByteArray(static_cast<jsize>(output.size()));
    if (result == nullptr) {
        failed(session, kInvalidOutput);
        return nullptr;
    }
    env->SetByteArrayRegion(result, 0, static_cast<jsize>(output.size()),
                            reinterpret_cast<const jbyte *>(output.data()));
    return result;
}

JNIEXPORT jint JNICALL
Java_com_justspeaktoit_android_local_LlamaNative_nativeLastError(JNIEnv *, jclass, jlong handle) {
    Session *session = fromHandle(handle);
    return session == nullptr ? kContext : session->lastError.load();
}

JNIEXPORT void JNICALL
Java_com_justspeaktoit_android_local_LlamaNative_nativeAbort(JNIEnv *, jclass, jlong handle) {
    Session *session = fromHandle(handle);
    if (session != nullptr) session->abort.store(true);
}

JNIEXPORT void JNICALL
Java_com_justspeaktoit_android_local_LlamaNative_nativeFree(JNIEnv *, jclass, jlong handle) {
    Session *session = fromHandle(handle);
    if (session == nullptr) return;
    llama_model_free(session->model);
    delete session;
}

}  // extern "C"
