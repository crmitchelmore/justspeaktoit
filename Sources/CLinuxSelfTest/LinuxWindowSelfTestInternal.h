#ifndef JSTI_LINUX_WINDOW_SELF_TEST_INTERNAL_H
#define JSTI_LINUX_WINDOW_SELF_TEST_INTERNAL_H
/* Shared between the window self-test translation units only. */
#include "../CLinuxSupport/LinuxWindowInternal.h"
#include "include/CLinuxSelfTest.h"

/* The last event a page check observed instead of reporting it. */
typedef struct ObservedEvent {
    gint32 event;
    gchar *text;
    gint32 index;
} ObservedEvent;

/* The two synthetic History records the History, presentation and Read aloud checks share. */
#define SELF_TEST_FIRST_RECORD "00000000-0000-0000-0000-000000000001"
#define SELF_TEST_SECOND_RECORD "00000000-0000-0000-0000-000000000002"

#pragma GCC visibility push(hidden)

extern ObservedEvent observed; /* LinuxWindowSelfTest.c */

void observe_event(gint32 event, const char *text, gint32 index, void *context);
gboolean configuration_reveal_self_test(void); /* LinuxWindowConfigurationSelfTest.c */
gboolean configuration_self_test(void);
gboolean sidebar_navigation_self_test(void); /* LinuxWindowCommandSelfTest.c */
gboolean action_execution_self_test(void);
gboolean command_forwarding_self_test(void);
gboolean status_notice_self_test(void);
gboolean command_process_self_test(char *error, size_t capacity);
gboolean post_processing_self_test(void); /* LinuxWindowCleanupSelfTest.c */
int32_t local_cleanup_sources_self_test(char *error, size_t capacity);
gboolean cleanup_preview_self_test(void);
gboolean migration_restore_self_test(void);
int32_t polish_prompt_self_test(char *error, size_t capacity);
gboolean page_functions_self_test(void); /* LinuxWindowPagesSelfTest.c */
gboolean cancel_key_self_test(void); /* LinuxWindowEscapeSelfTest.c */
int32_t model_picker_self_test(char *error, size_t capacity); /* LinuxWindowModelsSelfTest.c */
gboolean model_modes_self_test(void);
int32_t read_aloud_self_test(const char *record, char *error, size_t capacity); /* LinuxWindowReadAloudSelfTest.c */
int32_t voice_favorites_self_test(char *error, size_t capacity);
int32_t login_item_self_test(char *error, size_t capacity); /* LinuxWindowGeneralSelfTest.c */
int32_t automation_self_test(char *error, size_t capacity);
gboolean text_output_self_test(void); /* LinuxWindowOutputSelfTest.c */
int32_t storage_self_test(char *error, size_t capacity); /* LinuxWindowStorageSelfTest.c */
int32_t history_records_self_test(char *error, size_t capacity); /* LinuxWindowHistorySelfTest.c */
int32_t history_presentation_self_test(char *error, size_t capacity);
int32_t history_clear_self_test(char *error, size_t capacity);
int32_t jsti_voice_sources_self_test(GtkWindow *owner, char *error, size_t capacity); /* LinuxVoiceSourcesSelfTest.c */

#pragma GCC visibility pop

#endif
