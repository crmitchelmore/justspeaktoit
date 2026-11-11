/* The History page, as the rest of the window sees it: functions only. Its
 * state is private to LinuxWindowHistory.c and LinuxWindowHistoryPage.c
 * (LinuxWindowHistoryState.h). GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_HISTORY_PAGE_H
#define JSTI_LINUX_WINDOW_HISTORY_PAGE_H

#include "LinuxWindowInternal.h"

#pragma GCC visibility push(hidden)
GtkWidget *build_history(GtkTextBuffer *buffer);
GtkWidget *history_delete_dialog(const char *identifiers, gboolean clear);
/* Run start and window close. */
void history_page_start(void);
void history_page_close(void);
/* The header bar's Import button, which follows the History actions' idle state. */
void history_set_import_button(GtkButton *button);
/* General > Saved recordings' Delete audio button, created and kept here. */
GtkWidget *history_audio_cleanup_button(void);
GtkWidget *history_filters_button(void);
/* Enables the History actions for the window state. */
void refresh_history_actions(gboolean idle, gboolean has_text);
void history_show_insights(const char *sessions, const char *errors, const char *average, const char *spend);

/* The selected record, or NULL. */
const char *history_selected_id(void);
gboolean history_is_selected(const char *id);
/* Whether the transcript shown is the selected record's. */
gboolean history_selection_presented(void);
gint32 history_presented_variant(void);
gboolean history_presented_switchable(void);
/* The selected record's content is now shown. */
void history_mark_presented(const char *id, gint32 variant, gboolean switchable);
/* The transcript shown is no longer bound to a record. */
void history_forget_presentation(void);
/* Playback progress for `id`; ignored unless it is the selected record. */
void history_show_playback(const char *id, gint32 state, const char *text);
/* The text an export in progress captured at the click, or NULL. */
const char *history_export_text(void);
#pragma GCC visibility pop

#endif
