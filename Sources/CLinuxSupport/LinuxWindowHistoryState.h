/* The History page's state. Private to its two owning units:
 * LinuxWindowHistory.c (rows, selection, management) and
 * LinuxWindowHistoryPage.c (widgets and actions); the window self-tests also
 * include it to inspect them. Every other unit uses the functions in
 * LinuxWindowHistoryPage.h. GTK main thread only. */
#ifndef JSTI_LINUX_WINDOW_HISTORY_STATE_H
#define JSTI_LINUX_WINDOW_HISTORY_STATE_H

#include "LinuxWindowHistoryPage.h"

typedef struct HistoryPage {
    GtkSearchEntry *search;
    GtkWidget *history_filters;
    GtkButton *history_delete;
    GtkButton *history_clear;
    gchar *all_history_ids;
    GtkListBox *history;
    GPtrArray *history_ids;
    gchar *selected_id;
    gchar *presented_id;
    gint32 presented_variant;
    gboolean presented_switchable;
    GtkButton *retry;
    GtkButton *correction_results;
    GtkButton *export_button;
    GtkButton *issue_button;
    GtkButton *open_audio;
    GtkButton *audio_cleanup;
    GtkButton *import_button;
    GtkButton *play;
    GtkButton *stop_play;
    GtkLabel *playback_label;
    gint32 playback_state;
    /* Export in progress: the text and version captured at the click. */
    gchar *export_text;
    GtkButton *history_import;
    GtkLabel *history_sessions, *history_errors, *history_average, *history_spend;
    /* The selected History card's transcript and actions, moved into that card. */
    GtkWidget *detail;
    GtkWidget *history_empty;
} HistoryPage;

#pragma GCC visibility push(hidden)
HistoryPage *history_page(void);
/* The transcript and actions live in the selected History card. */
void detach_detail(void);
void attach_detail(GtkListBoxRow *row);
#pragma GCC visibility pop

#endif
