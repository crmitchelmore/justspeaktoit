#ifndef JSTI_LINUX_LOCAL_MODELS_H
#define JSTI_LINUX_LOCAL_MODELS_H
/* Local models: the whisper.cpp loader, downloads and checksums. Part of CLinuxSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The Local models group reports these with the row index. */
enum {
    JSTI_EVENT_LOCAL_MODEL_DOWNLOAD = 50, /* index: row; downloads or resumes */
    JSTI_EVENT_LOCAL_MODEL_CANCEL = 51,   /* index: row */
    JSTI_EVENT_LOCAL_MODEL_REMOVE = 52,   /* index: row */
    JSTI_EVENT_LOCAL_MODEL_GPU = 53,      /* index: 1 on, 0 off */
    JSTI_EVENT_LOCAL_MODEL_IMPORT = 54,   /* text: owner/repo newline GGML basename */
    JSTI_EVENT_LOCAL_MODEL_IMPORT_CANCEL = 55
};

enum {
    JSTI_LOCAL_MODEL_NOT_INSTALLED = 0,
    JSTI_LOCAL_MODEL_PARTIAL = 1,
    JSTI_LOCAL_MODEL_DOWNLOADING = 2,
    JSTI_LOCAL_MODEL_INSTALLED = 3,
    JSTI_LOCAL_MODEL_REMOVING = 4
};

typedef struct JSTILocalModelRow {
    const char *name;
    const char *detail;
    /* Licence and provenance, shown as the row's tooltip. */
    const char *about;
    int32_t state;
} JSTILocalModelRow;

/* Rows of the on-device models the host offers, in its order. `gpu` is -1 to
 * hide the GPU switch (the runtime has no GPU backend), otherwise 0 or 1.
 * Safe from any thread, like the other window setters. */
int32_t jsti_window_set_local_models(
    const JSTILocalModelRow *rows, size_t count, const char *runtime_status, int32_t gpu);

/* Streaming SHA-256 through GLib's GChecksum. One object per digest; finish
 * writes 64 lowercase hex characters plus a terminator and ends the object's
 * use. destroy is always required. */
typedef struct JSTISHA256 JSTISHA256;
JSTISHA256 *jsti_sha256_create(char *error, size_t error_capacity);
int32_t jsti_sha256_update(JSTISHA256 *hasher, const void *bytes, size_t count, char *error, size_t error_capacity);
int32_t jsti_sha256_finish(JSTISHA256 *hasher, char *hex, size_t hex_capacity, char *error, size_t error_capacity);
void jsti_sha256_destroy(JSTISHA256 *hasher);

/* On-device transcription through whisper.cpp, loaded at run time with the
 * same ABI as the Windows adapter.
 *
 * open loads libggml-base.so.0, libggml.so.0 and libwhisper.so.1 by absolute
 * path from `directory` (absolute; it and the libraries must not be writable
 * by other users), so their dependencies resolve to those copies and nothing
 * is searched for. It refuses any whisper_version() but the pinned one, then
 * registers the best-scoring libggml-cpu-*.so from that directory and, when
 * allow_gpu is 1 and libggml-vulkan.so is there, Vulkan. Process-wide: a
 * second open must name the same directory. NULL with an error otherwise. */
typedef struct JSTIWhisperRuntime JSTIWhisperRuntime;
JSTIWhisperRuntime *jsti_whisper_runtime_open(const char *directory, int32_t allow_gpu, char *error, size_t error_capacity);
/* A short description such as "whisper.cpp 1.9.4; CPU". */
int32_t jsti_whisper_runtime_describe(JSTIWhisperRuntime *runtime, char *text, size_t capacity);
/* 1 when a GPU device is registered and would be used, otherwise 0. */
int32_t jsti_whisper_runtime_uses_gpu(JSTIWhisperRuntime *runtime);

/* A cancellation token for one transcription; cancel is thread safe and may
 * come before, during or after transcribe. */
typedef struct JSTIWhisperJob JSTIWhisperJob;
JSTIWhisperJob *jsti_whisper_job_create(void);
void jsti_whisper_job_cancel(JSTIWhisperJob *job);
void jsti_whisper_job_destroy(JSTIWhisperJob *job);

enum {
    JSTI_WHISPER_OK = 0,
    JSTI_WHISPER_FAILED = -1,
    JSTI_WHISPER_CANCELLED = 1,
    JSTI_WHISPER_MODEL_MISMATCH = 2
};
/* Transcribes 16 kHz mono float samples with the model at the absolute
 * `model_path`, whose pinned SHA-256 is the 64 hex digits `model_sha256`.
 * Loading hashes every byte as it hands it to whisper.cpp, through one open
 * file, and a model whose bytes do not match is freed unused with
 * JSTI_WHISPER_MODEL_MISMATCH, so no byte that was not verified is ever
 * recognised with. The loaded model is cached for later calls with the same
 * path and digest and released when another model is used or release_model is
 * called; its file is closed once loaded. Calls are serialised. `language` is
 * a Whisper code such as "en"; NULL, empty or unknown detects it. On success
 * `*text` is a heap UTF-8 string for jsti_whisper_free_text. */
int32_t jsti_whisper_transcribe(
    JSTIWhisperRuntime *runtime, const char *model_path, const char *model_sha256, const float *samples,
    size_t sample_count, const char *language, int32_t threads, JSTIWhisperJob *job, char **text, char *error,
    size_t error_capacity);
void jsti_whisper_free_text(char *text);
/* Frees the cached model, waiting for a running transcription to finish. */
void jsti_whisper_runtime_release_model(JSTIWhisperRuntime *runtime);
/* Frees the cached model only if it was loaded from `model_path`, atomically
 * with loading, so a model loaded in its place stays cached. 1 when freed, 0
 * when another model or none is cached, -1 for an invalid argument. */
int32_t jsti_whisper_runtime_release_model_at(JSTIWhisperRuntime *runtime, const char *model_path);

#ifdef __cplusplus
}
#endif
#endif
