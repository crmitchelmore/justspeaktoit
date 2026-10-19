#ifndef JSTI_VOICE_AUDIO_CODEC_H
#define JSTI_VOICE_AUDIO_CODEC_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Synchronous, in-process worker ABI; all pointers are borrowed until return.
 * output kind 0: complete encoded container; kind 1: decoded mono PCM16 chunks.
 * A nonzero output result refuses overflow. Cancel returns nonzero when stopped.
 * No native worker, file, callback or allocation outlives this call. */
typedef int32_t (*JSTIVoiceCodecOutput)(int32_t kind, const uint8_t *bytes, size_t count, void *context);
typedef int32_t (*JSTIVoiceCodecCancelled)(void *context);
typedef struct {
    const char *format;
    uint32_t sample_rate;
    const uint8_t *pcm;
    size_t pcm_bytes;
    JSTIVoiceCodecOutput output;
    JSTIVoiceCodecCancelled cancelled;
    void *context;
} JSTIVoiceCodecRequest;
/* 0 available/success, 1 cancelled, -1 unavailable/failure with explicit reason. */
int32_t jsti_voice_codec_available(const char *format, uint32_t sample_rate, char *error, size_t capacity);
int32_t jsti_voice_codec_encode(const JSTIVoiceCodecRequest *request, char *error, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
