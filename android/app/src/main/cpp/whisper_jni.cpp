// JNI bridge between WhisperNative.kt and whisper.cpp. A session owns one whisper_context; Kotlin
// opens it, transcribes one recording, then frees it. nativeAbort may run on another thread while
// nativeTranscribe is running; nativeFree runs only after nativeTranscribe has returned.
#include <android/log.h>
#include <jni.h>

#include <atomic>
#include <string>

#include "whisper.h"

namespace {

constexpr const char *kTag = "JstiWhisper";

struct Session {
    whisper_context *context = nullptr;
    std::atomic<bool> abort{false};
};

Session *fromHandle(jlong handle) { return reinterpret_cast<Session *>(handle); }

void logToAndroid(ggml_log_level level, const char *text, void *) {
    if (level == GGML_LOG_LEVEL_ERROR) {
        __android_log_write(ANDROID_LOG_ERROR, kTag, text);
    } else if (level == GGML_LOG_LEVEL_WARN) {
        __android_log_write(ANDROID_LOG_WARN, kTag, text);
    }
}

bool shouldAbort(void *userData) {
    return static_cast<Session *>(userData)->abort.load(std::memory_order_relaxed);
}

std::string utf8(JNIEnv *env, jstring value) {
    if (value == nullptr) return {};
    const char *chars = env->GetStringUTFChars(value, nullptr);
    if (chars == nullptr) return {};
    std::string result(chars);
    env->ReleaseStringUTFChars(value, chars);
    return result;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_com_justspeaktoit_android_local_WhisperNative_nativeOpen(JNIEnv *env, jclass, jstring path) {
    whisper_log_set(logToAndroid, nullptr);
    const std::string modelPath = utf8(env, path);
    if (modelPath.empty()) return 0;
    whisper_context_params params = whisper_context_default_params();
    params.use_gpu = false;
    whisper_context *context = whisper_init_from_file_with_params(modelPath.c_str(), params);
    if (context == nullptr) return 0;
    auto *session = new Session();
    session->context = context;
    return reinterpret_cast<jlong>(session);
}

// Returns the transcript as UTF-8 bytes (Kotlin decodes them): segments can end inside a multi-byte
// character, and NewStringUTF accepts only modified UTF-8. Null means failed or aborted.
JNIEXPORT jbyteArray JNICALL
Java_com_justspeaktoit_android_local_WhisperNative_nativeTranscribe(
    JNIEnv *env, jclass, jlong handle, jfloatArray samples, jstring language, jint threads) {
    Session *session = fromHandle(handle);
    if (session == nullptr || samples == nullptr) return nullptr;

    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = threads > 0 ? threads : 1;
    params.translate = false;
    params.no_timestamps = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    const std::string languageCode = utf8(env, language);
    // An unknown or missing code lets the model detect the language.
    params.language = (!languageCode.empty() && whisper_lang_id(languageCode.c_str()) >= 0)
                          ? languageCode.c_str()
                          : "auto";
    params.abort_callback = shouldAbort;
    params.abort_callback_user_data = session;

    const jsize count = env->GetArrayLength(samples);
    jfloat *pcm = env->GetFloatArrayElements(samples, nullptr);
    if (pcm == nullptr) return nullptr;
    const int status = whisper_full(session->context, params, pcm, count);
    env->ReleaseFloatArrayElements(samples, pcm, JNI_ABORT);
    if (status != 0 || session->abort.load()) return nullptr;

    std::string text;
    const int segments = whisper_full_n_segments(session->context);
    for (int index = 0; index < segments; ++index) {
        const char *segment = whisper_full_get_segment_text(session->context, index);
        if (segment != nullptr) text += segment;
    }
    jbyteArray bytes = env->NewByteArray(static_cast<jsize>(text.size()));
    if (bytes == nullptr) return nullptr;
    env->SetByteArrayRegion(bytes, 0, static_cast<jsize>(text.size()),
                            reinterpret_cast<const jbyte *>(text.data()));
    return bytes;
}

JNIEXPORT void JNICALL
Java_com_justspeaktoit_android_local_WhisperNative_nativeAbort(JNIEnv *, jclass, jlong handle) {
    Session *session = fromHandle(handle);
    if (session != nullptr) session->abort.store(true);
}

JNIEXPORT void JNICALL
Java_com_justspeaktoit_android_local_WhisperNative_nativeFree(JNIEnv *, jclass, jlong handle) {
    Session *session = fromHandle(handle);
    if (session == nullptr) return;
    whisper_free(session->context);
    delete session;
}

}  // extern "C"
