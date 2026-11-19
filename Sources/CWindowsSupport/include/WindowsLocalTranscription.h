#ifndef JSTI_WINDOWS_LOCAL_TRANSCRIPTION_H
#define JSTI_WINDOWS_LOCAL_TRANSCRIPTION_H
/* Local models: SHA-256 verification and the whisper.cpp runtime. Part of CWindowsSupport.h. */
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Streaming SHA-256 through Windows CNG (BCrypt). One object per digest;
 * finish writes 64 lowercase hex characters plus a terminator and ends the
 * object's use. destroy is always required. Never logs input bytes. */
typedef struct JSTISHA256 JSTISHA256;
JSTISHA256 *jsti_sha256_create(char *error, size_t error_capacity);
int jsti_sha256_update(JSTISHA256 *hasher, const void *bytes, size_t count, char *error, size_t error_capacity);
int jsti_sha256_finish(JSTISHA256 *hasher, char *hex, size_t hex_capacity, char *error, size_t error_capacity);
void jsti_sha256_destroy(JSTISHA256 *hasher);

/* On-device transcription through whisper.cpp, loaded at run time.
 *
 * open loads whisper.dll (and the ggml DLLs beside it) from an absolute
 * directory with a restricted search path, checks the exact pinned
 * whisper.cpp version and registers ggml's dynamic backends from that
 * directory only: every CPU variant and, when allow_gpu is 1 and the system
 * Vulkan loader exists, Vulkan. A missing Vulkan loader is not an error; the
 * CPU runs instead. The runtime is process-wide and stays loaded once opened;
 * a second open must name the same directory. Implicit Vulkan layers (overlay
 * and capture hooks) are disabled for this process unless the user already
 * configured VK_LOADER_LAYERS_DISABLE. Returns NULL with an error when the
 * runtime is absent or does not match. */
typedef struct JSTIWhisperRuntime JSTIWhisperRuntime;
JSTIWhisperRuntime *jsti_whisper_runtime_open(const char *directory, int allow_gpu,
                                              char *error, size_t error_capacity);
/* Writes a short UTF-8 description such as "whisper.cpp 1.9.4; GPU: Vulkan0
 * (NVIDIA ...); CPU" listing the registered devices. */
int jsti_whisper_runtime_describe(JSTIWhisperRuntime *runtime, char *text, size_t capacity);
/* 1 when a GPU device is registered and would be used, otherwise 0. */
int jsti_whisper_runtime_uses_gpu(JSTIWhisperRuntime *runtime);

/* A cancellation token for one transcription. cancel is thread safe and may
 * be called before, during or after transcribe. */
typedef struct JSTIWhisperJob JSTIWhisperJob;
JSTIWhisperJob *jsti_whisper_job_create(void);
void jsti_whisper_job_cancel(JSTIWhisperJob *job);
void jsti_whisper_job_destroy(JSTIWhisperJob *job);

enum JSTIWhisperResult {
    JSTI_WHISPER_OK = 0,
    JSTI_WHISPER_FAILED = -1,
    JSTI_WHISPER_CANCELLED = 1,
    JSTI_WHISPER_MODEL_MISMATCH = 2
};
/* Transcribes 16 kHz mono float samples with the model at model_path (UTF-8,
 * absolute; read through a wide-character path), whose pinned SHA-256 is the
 * 64 hex digits model_sha256. Loading hashes every byte as it hands it to
 * whisper.cpp, through one open file, and a model whose bytes do not match is
 * freed unused with JSTI_WHISPER_MODEL_MISMATCH, so no byte that was not
 * verified is ever recognised with. The loaded model is cached for later calls
 * with the same path and digest and released when another model is used or
 * release_model is called. Calls are serialised. language is a Whisper code
 * such as "en", or NULL/empty to detect it; an unknown code detects it.
 * On success *text receives a heap UTF-8 string owned by the caller (free with
 * jsti_whisper_free_text). Returns a JSTIWhisperResult. */
int jsti_whisper_transcribe(JSTIWhisperRuntime *runtime, const char *model_path, const char *model_sha256,
                            const float *samples, size_t sample_count, const char *language, int threads,
                            JSTIWhisperJob *job, char **text, char *error, size_t error_capacity);
void jsti_whisper_free_text(char *text);
/* Frees the cached model, waiting for a running transcription to finish. */
void jsti_whisper_runtime_release_model(JSTIWhisperRuntime *runtime);
/* Frees the cached model only if it was loaded from model_path (the path given
 * to jsti_whisper_transcribe), waiting for a running transcription to finish.
 * The check and the release are atomic with loading, so a model loaded in its
 * place stays cached. The loaded model's file is closed once loaded, so it may
 * already be deleted. Returns 1 when that model was freed, 0 when another model
 * or none is cached, and -1 for an invalid argument. */
int jsti_whisper_runtime_release_model_at(JSTIWhisperRuntime *runtime, const char *model_path);

#ifdef __cplusplus
}
#endif
#endif
