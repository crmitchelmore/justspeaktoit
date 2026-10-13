#ifndef JSTI_VOICE_SOURCES_H
#define JSTI_VOICE_SOURCES_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
/* UI-thread callback; all strings are borrowed immutable snapshots.
 * action 110 read, 111 export, 112 stop. source: canonical VoiceOutputSource.
 * record is empty for non-History sources. path is present only for export. */
typedef void (*JSTIVoiceSourceCallback)(int32_t action, int32_t source, const char *text,
                                      const char *record, const char *path, void *context);
int32_t jsti_window_set_voice_sources(const char *const *names, size_t count,
                                      JSTIVoiceSourceCallback callback, void *context);
#ifdef __cplusplus
}
#endif
#endif
