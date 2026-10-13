#ifndef JSTI_VOICE_SOURCES_H
#define JSTI_VOICE_SOURCES_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* UI-thread callback; all strings are borrowed immutable snapshots.
 * action 110 read, 111 export, 112 stop, 113 import, 114 cancel import.
 * source: canonical VoiceOutputSource. record is History ownership for read/
 * export, empty for other sources; for import/cancel it is an opaque request
 * token, NEVER History ownership. path is the chosen export/import path. */
typedef void (*JSTIVoiceSourceCallback)(int32_t action, int32_t source, const char *text,
                                      const char *record, const char *path, void *context);
int32_t jsti_window_set_voice_sources(const char *const *names, size_t count,
                                      JSTIVoiceSourceCallback callback, void *context);
/* Thread safe, borrowed strings copied. Empty error means success. Stale
 * request tokens cannot replace text or revive a closed editor. */
int32_t jsti_window_set_voice_text_import(const char *token, const char *text, const char *error);
/* 115 Generate: path is snapshotted flags (bit 0 auto-play, bit 1 save).
 * 116 Play result / 117 Export result: record is an opaque result ID, not a
 * History owner. 118 saves both preference flags atomically via source.
 * Setters copy borrowed strings and dispatch to the native editor. */
int32_t jsti_window_set_voice_generation_options(int32_t flags);
int32_t jsti_window_set_voice_generated_result(const char *result_id, int32_t working, const char *message);
#ifdef __cplusplus
}
#endif
#endif
