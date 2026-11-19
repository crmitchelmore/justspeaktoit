/* The Compare Models window's state, private to its units: LinuxComparison.c
 * (the window, model list, handlers and the host's presentation, which own it),
 * LinuxComparisonPickers.c (sample, export and deletion pickers) and
 * LinuxComparisonFixture.c (the self-test, screenshot tour and event recorder).
 * GTK main thread only. */
#ifndef JSTI_LINUX_COMPARISON_STATE_H
#define JSTI_LINUX_COMPARISON_STATE_H

#include "LinuxSupportInternal.h"
#include <adwaita.h>

typedef struct {
    GtkWindow *window;
    GtkDropDown *mode;
    GtkEntry *language, *ranks;
    GtkListBox *models;
    GtkDropDown *rounds;
    GtkDropDown *reference;
    GtkDropDown *export_scope;
    GtkTextView *detail;
    GtkWidget *column;
    GtkButton *run, *stop, *cancel, *judge, *json, *markdown, *play, *stop_audio, *delete_round;
    GtkCheckButton *sync;
    GtkButton *sync_now;
    GtkCheckButton *save_history;
    GtkButton *select_all, *select_none;
    GtkButton *copy_json, *copy_markdown;
    GtkButton *next_file;
    GPtrArray *model_ids, *round_ids, *reference_ids;
    gchar *selected, *model_rows, *round_rows, *reference_rows;
    gchar *batch_round;
    gboolean suppress;
} Comparison;

typedef struct { GtkWindow *window; GString *payload; gboolean markdown; } PickerRequest;

typedef struct {
    gchar *models, *rounds, *detail, *selected;
    gboolean busy, recording, judgeable, sync_enabled, sync_available;
    gchar *references, *reference;
    gchar *batch_round;
    gint32 batch_remaining;
    gboolean can_next;
} Presentation;

#pragma GCC visibility push(hidden)
/* LinuxComparison.c */
Comparison *comparison_ui(void);
void comparison_error(const char *message);
void comparison_present(gpointer value);
void comparison_present_save_history(gpointer value);
/* LinuxComparisonPickers.c */
PickerRequest *comparison_picker_request(GString *payload, gboolean markdown);
void comparison_free_request(PickerRequest *request);
void comparison_choose_samples(GString *payload);
void comparison_save_export(PickerRequest *request, const char *path);
void comparison_confirm_deletion(PickerRequest *request, const char *response);
void comparison_delete_clicked(GtkButton *button, gpointer data);
void comparison_export_clicked(GtkButton *button, gpointer data);
void comparison_copy_export(GtkButton *button, gpointer data);
/* LinuxComparisonFixture.c: reports to the host, or to the self-test's recorder. */
void comparison_emit(gint32 event, const char *text, gint32 index);
#pragma GCC visibility pop

#endif
