#ifndef JSTI_LINUX_WINDOW_SELF_TEST_INTERNAL_H
#define JSTI_LINUX_WINDOW_SELF_TEST_INTERNAL_H
/* Shared between the window self-test translation units only. */
#include "../CLinuxSupport/LinuxWindowInternal.h"
#include "include/CLinuxSelfTest.h"

/* The last event the Read aloud check observed instead of reporting it. */
typedef struct ObservedEvent {
    gint32 event;
    gchar *text;
    gint32 index;
} ObservedEvent;

#pragma GCC visibility push(hidden)

extern ObservedEvent observed; /* LinuxWindowSelfTest.c */

void observe_event(gint32 event, const char *text, gint32 index, void *context);
gboolean configuration_reveal_self_test(void); /* LinuxWindowConfigurationSelfTest.c */
gboolean configuration_self_test(void);
gboolean sidebar_navigation_self_test(void); /* LinuxWindowCommandSelfTest.c */
gboolean action_execution_self_test(void);
gboolean command_forwarding_self_test(void);
gboolean command_process_self_test(char *error, size_t capacity);
gboolean post_processing_self_test(void); /* LinuxWindowCleanupSelfTest.c */
int32_t local_cleanup_sources_self_test(char *error, size_t capacity);
gboolean cleanup_preview_self_test(void);
gboolean migration_restore_self_test(void);
gboolean page_functions_self_test(void); /* LinuxWindowPagesSelfTest.c */
int32_t jsti_voice_sources_self_test(GtkWindow *owner, char *error, size_t capacity); /* LinuxVoiceSourcesSelfTest.c */

#pragma GCC visibility pop

#endif
