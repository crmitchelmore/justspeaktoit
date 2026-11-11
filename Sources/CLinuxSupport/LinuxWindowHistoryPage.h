/* The History page: its state, owned by LinuxWindowHistory.c. GTK main thread only.
 * Only translation units that include this header can reach it. */
#ifndef JSTI_LINUX_WINDOW_HISTORY_PAGE_H
#define JSTI_LINUX_WINDOW_HISTORY_PAGE_H

#include "LinuxWindowInternal.h"

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
#pragma GCC visibility pop

#endif
