// Narrow C API over the llama.cpp runtime compiled into the iOS app for downloaded cleanup models.
// Only this header is public: llama.cpp and ggml headers stay private to the target, so they never
// clash with the declarations vendored in CLlamaCpp for the desktop's separately provisioned runtime.
#ifndef JSTI_LLAMA_RUNTIME_H
#define JSTI_LLAMA_RUNTIME_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Failure codes, kept in step with `IOSLocalCleanupNativeFailure` in SpeakiOSLib and with the
/// Android bridge (android/app/src/main/cpp/llama_jni.cpp).
enum {
    JSTI_LLAMA_OK = 0,
    JSTI_LLAMA_ABORTED = 1,
    JSTI_LLAMA_NO_CHAT_TEMPLATE = 2,
    JSTI_LLAMA_TOO_LONG = 3,
    JSTI_LLAMA_DECODE = 4,
    JSTI_LLAMA_NO_END_OF_TURN = 5,
    JSTI_LLAMA_INVALID_OUTPUT = 6,
    JSTI_LLAMA_CONTEXT = 7,
    JSTI_LLAMA_TIMED_OUT = 8,
};

typedef struct jsti_llama_session jsti_llama_session;

/// A session owns at most one model. The deadline starts now and covers load and generation.
jsti_llama_session *jsti_llama_create(int64_t timeout_ms);

/// Loads a GGUF file (CPU only, memory-mapped, tensors checked). Returns false on failure.
bool jsti_llama_load(jsti_llama_session *session, const char *path);

/// Runs one greedy completion using the model's chat template with SYSTEM and USER roles. Returns a
/// malloc'd NUL-terminated UTF-8 reply (release with jsti_llama_free_string), or NULL on failure.
char *jsti_llama_complete(jsti_llama_session *session, const char *system_prompt, const char *user_message,
                          int32_t max_tokens, int32_t threads);

/// The failure code of the last load or completion.
int32_t jsti_llama_last_error(const jsti_llama_session *session);

/// Thread-safe: stops a running load or completion at its next check.
void jsti_llama_abort(jsti_llama_session *session);

/// Frees the model and session. Call only after load and completion have returned.
void jsti_llama_free(jsti_llama_session *session);

void jsti_llama_free_string(char *value);

#ifdef __cplusplus
}
#endif

#endif
