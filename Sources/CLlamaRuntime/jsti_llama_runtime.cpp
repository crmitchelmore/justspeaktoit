// The generation loop follows the desktop adapter (Sources/CLlamaCpp/LlamaCpp.cpp) and the Android
// bridge (android/app/src/main/cpp/llama_jni.cpp): the model's own chat template with SYSTEM and USER
// roles, Qwen3's non-thinking prefill, greedy sampling, a bounded prompt and output, and no partial
// output when the budget runs out. jsti_llama_abort may run on another thread while a load or
// completion is running; jsti_llama_free runs only after both have returned.
#include "jsti_llama_runtime.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "llama.h"

namespace {

constexpr uint32_t kContextTokens = 4096;
constexpr uint32_t kBatchTokens = 256;
constexpr int32_t kMaxTemplateBytes = 512 * 1024;
constexpr size_t kMaxOutputBytes = 256 * 1024;
constexpr int32_t kMaxPieceBytes = 64 * 1024;
constexpr int64_t kMaxTimeoutMs = 10 * 60 * 1000;

void logErrors(ggml_log_level level, const char *text, void *) {
    if (level == GGML_LOG_LEVEL_ERROR && text != nullptr) std::fputs(text, stderr);
}

struct ContextDeleter {
    void operator()(llama_context *value) const { llama_free(value); }
};
struct SamplerDeleter {
    void operator()(llama_sampler *value) const { llama_sampler_free(value); }
};

}  // namespace

struct jsti_llama_session {
    llama_model *model = nullptr;
    std::atomic<bool> abort{false};
    std::atomic<int32_t> lastError{JSTI_LLAMA_OK};
    std::chrono::steady_clock::time_point deadline = std::chrono::steady_clock::time_point::max();
    std::atomic<bool> timedOut{false};

    bool stopped() {
        if (abort.load(std::memory_order_relaxed)) return true;
        if (std::chrono::steady_clock::now() >= deadline) {
            timedOut.store(true);
            return true;
        }
        return false;
    }

    int32_t failed(int32_t code) {
        if (timedOut.load()) code = JSTI_LLAMA_TIMED_OUT;
        else if (abort.load()) code = JSTI_LLAMA_ABORTED;
        lastError.store(code);
        return code;
    }
};

namespace {

bool abortRun(void *userData) { return static_cast<jsti_llama_session *>(userData)->stopped(); }

bool loadProgress(float, void *userData) { return !static_cast<jsti_llama_session *>(userData)->stopped(); }

int32_t complete(jsti_llama_session *session, const std::string &system, const std::string &user,
                 int32_t maxTokens, int32_t threads, std::string &output) {
    llama_model *model = session->model;
    const llama_vocab *vocab = llama_model_get_vocab(model);
    if (vocab == nullptr) return JSTI_LLAMA_CONTEXT;

    const char *tmpl = llama_model_chat_template(model, nullptr);
    if (tmpl == nullptr) return JSTI_LLAMA_NO_CHAT_TEMPLATE;
    const llama_chat_message messages[] = {{"system", system.c_str()}, {"user", user.c_str()}};
    const int32_t required = llama_chat_apply_template(tmpl, messages, 2, true, nullptr, 0);
    if (required <= 0 || required > kMaxTemplateBytes) return JSTI_LLAMA_NO_CHAT_TEMPLATE;
    std::vector<char> rendered(static_cast<size_t>(required) + 1);
    if (llama_chat_apply_template(tmpl, messages, 2, true, rendered.data(),
                                  static_cast<int32_t>(rendered.size())) != required) {
        return JSTI_LLAMA_NO_CHAT_TEMPLATE;
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
    if (wanted >= 0 || wanted <= -static_cast<int32_t>(kContextTokens)) return JSTI_LLAMA_TOO_LONG;
    std::vector<llama_token> tokens(static_cast<size_t>(-wanted));
    if (llama_tokenize(vocab, prompt.data(), static_cast<int32_t>(prompt.size()), tokens.data(),
                       static_cast<int32_t>(tokens.size()), true, true) != -wanted) {
        return JSTI_LLAMA_TOO_LONG;
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
    if (!context) return JSTI_LLAMA_CONTEXT;
    const size_t available = llama_n_ctx(context.get());
    if (tokens.size() >= available) return JSTI_LLAMA_TOO_LONG;

    std::unique_ptr<llama_sampler, SamplerDeleter> sampler(
        llama_sampler_chain_init(llama_sampler_chain_default_params()));
    llama_sampler *greedy = sampler ? llama_sampler_init_greedy() : nullptr;
    if (greedy == nullptr) return JSTI_LLAMA_CONTEXT;
    llama_sampler_chain_add(sampler.get(), greedy);

    for (size_t offset = 0; offset < tokens.size(); offset += kBatchTokens) {
        if (session->stopped()) return JSTI_LLAMA_ABORTED;
        const auto count = static_cast<int32_t>(std::min<size_t>(kBatchTokens, tokens.size() - offset));
        if (llama_decode(context.get(), llama_batch_get_one(tokens.data() + offset, count)) != 0) {
            return JSTI_LLAMA_DECODE;
        }
    }

    const size_t budget = std::min(static_cast<size_t>(std::max(maxTokens, 1)), available - tokens.size());
    std::vector<char> piece(256);
    for (size_t generated = 0; generated < budget; ++generated) {
        if (session->stopped()) return JSTI_LLAMA_ABORTED;
        llama_token token = llama_sampler_sample(sampler.get(), context.get(), -1);
        if (llama_vocab_is_eog(vocab, token)) return JSTI_LLAMA_OK;
        int32_t count = llama_token_to_piece(vocab, token, piece.data(), static_cast<int32_t>(piece.size()), 0, false);
        if (count < 0 && count > -kMaxPieceBytes) {
            piece.resize(static_cast<size_t>(-count));
            count = llama_token_to_piece(vocab, token, piece.data(), static_cast<int32_t>(piece.size()), 0, false);
        }
        if (count < 0 || static_cast<size_t>(count) > piece.size()) return JSTI_LLAMA_INVALID_OUTPUT;
        if (std::memchr(piece.data(), 0, static_cast<size_t>(count)) != nullptr) return JSTI_LLAMA_INVALID_OUTPUT;
        output.append(piece.data(), static_cast<size_t>(count));
        if (output.size() > kMaxOutputBytes) return JSTI_LLAMA_NO_END_OF_TURN;
        if (llama_decode(context.get(), llama_batch_get_one(&token, 1)) != 0) return JSTI_LLAMA_DECODE;
    }
    return JSTI_LLAMA_NO_END_OF_TURN;
}

}  // namespace

extern "C" {

jsti_llama_session *jsti_llama_create(int64_t timeout_ms) {
    auto *session = new jsti_llama_session();
    session->deadline = std::chrono::steady_clock::now() +
                        std::chrono::milliseconds(std::clamp<int64_t>(timeout_ms, 1, kMaxTimeoutMs));
    return session;
}

bool jsti_llama_load(jsti_llama_session *session, const char *path) {
    if (session == nullptr || session->model != nullptr) return false;
    if (path == nullptr || path[0] == '\0') {
        session->failed(JSTI_LLAMA_CONTEXT);
        return false;
    }
    llama_log_set(logErrors, nullptr);
    llama_backend_init();
    llama_model_params params = llama_model_default_params();
    params.n_gpu_layers = 0;
    params.load_mode = LLAMA_LOAD_MODE_MMAP;
    params.check_tensors = true;
    params.progress_callback = loadProgress;
    params.progress_callback_user_data = session;
    llama_model *model = llama_model_load_from_file(path, params);
    if (model == nullptr) {
        session->failed(JSTI_LLAMA_CONTEXT);
        return false;
    }
    if (session->stopped() || llama_model_has_encoder(model) || !llama_model_has_decoder(model) ||
        llama_model_get_vocab(model) == nullptr) {
        llama_model_free(model);
        session->failed(JSTI_LLAMA_CONTEXT);
        return false;
    }
    session->model = model;
    return true;
}

char *jsti_llama_complete(jsti_llama_session *session, const char *system_prompt, const char *user_message,
                          int32_t max_tokens, int32_t threads) {
    if (session == nullptr || session->model == nullptr) return nullptr;
    session->lastError.store(JSTI_LLAMA_OK);
    if (system_prompt == nullptr || user_message == nullptr || user_message[0] == '\0') {
        session->failed(JSTI_LLAMA_INVALID_OUTPUT);
        return nullptr;
    }
    std::string output;
    const int32_t status = complete(session, system_prompt, user_message, max_tokens, threads > 0 ? threads : 1,
                                    output);
    if (status != JSTI_LLAMA_OK || session->stopped()) {
        session->failed(status == JSTI_LLAMA_OK ? JSTI_LLAMA_ABORTED : status);
        return nullptr;
    }
    char *result = static_cast<char *>(std::malloc(output.size() + 1));
    if (result == nullptr) {
        session->failed(JSTI_LLAMA_INVALID_OUTPUT);
        return nullptr;
    }
    std::memcpy(result, output.data(), output.size());
    result[output.size()] = '\0';
    return result;
}

int32_t jsti_llama_last_error(const jsti_llama_session *session) {
    return session == nullptr ? JSTI_LLAMA_CONTEXT : session->lastError.load();
}

void jsti_llama_abort(jsti_llama_session *session) {
    if (session != nullptr) session->abort.store(true);
}

void jsti_llama_free(jsti_llama_session *session) {
    if (session == nullptr) return;
    if (session->model != nullptr) llama_model_free(session->model);
    delete session;
}

void jsti_llama_free_string(char *value) { std::free(value); }

}  // extern "C"
